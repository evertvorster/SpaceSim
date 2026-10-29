class_name SpacesimCloudField
extends RefCounted
## **The cloud field itself**: from a seed and a body's derived morphology, how much cloud is in a given
## direction.
##
## `SpacesimCloudModel` says how a body's clouds are *organised*; this turns that into a number per
## direction, deterministically, from a seed. Both regimes the plan describes read the same function —
## the far one bakes it into a map, the near one will march it — which is the point of having it in one
## place rather than in a shader and a baker separately.
##
## ## The three ingredients, and where each comes from
##
##     bands   = SpacesimCloudModel.condensation_favouring(latitude, cells)
##     eddies  = seeded noise, sized by the deformation radius, zonally elongated
##     mixing  = a constant per regime, from the model's verdict
##     intensity = bands * (1 - mixing + mixing * 2 * eddies)
##
## **The bands are the envelope, and the eddies modulate them rather than being added on.** That is a
## deliberate choice: adding them would let an eddy put cloud over a desert, which is exactly the
## structure the circulation is supposed to impose. Written as an envelope, the bands survive at every
## mixing strength and the eddies decide how ragged they are — clean belts at one end, weather at the
## other, from one expression.
##
## **`FEATURELESS` skips the noise entirely.** Evert, 2026-10-16: *"if we can predict that the cloud
## coverage would be effectively noise free, we can skip the noise generation."* A body the model calls
## featureless returns a uniform field and never builds a generator — so Venus costs nothing, and a test
## proves it by baking the same map from two different seeds and getting the same bytes.
##
## ## What is an intensity, and what it is not
##
## This returns a **relative** 0-1 field, not a reflectance and not a coverage fraction. The *layer's*
## coverage turns it into one, by thresholding at a percentile of the whole map — the rule
## [[SpaceSim/Atmospheres|Atmospheres]] §11 carries, and the reason the returned distribution matters more
## than any single value. A uniform field means "no structure to threshold", which is the correct
## description of a featureless body.

## How much the eddies break the bands, per regime. **A look judgement, not a derivation** — the same
## kind of constant as `SpacesimLod`'s triangle-per-screen-radius, and the number a render settles.
##
## Bands stay dominant but are not stencils at 0.25; at 0.85 the weather is what you see. The gap between
## them is the whole visual difference between a gas giant and a wet world, and it comes from the model's
## verdict rather than from a threshold here.
const MIXING_BANDED := 0.25
const MIXING_SHREDDED := 0.85
const MIXING_NONE := 0.0 ## both `FEATURELESS` and `UNKNOWN`: a uniform field

## How much longer an eddy is in longitude than in latitude. Also a look judgement.
##
## **Applied to the direction rather than to a (longitude, latitude) pair**, and that is deliberate: a
## cylinder parameterisation — `(cos lon, sin lon, latitude)` — pinwheels at the poles, because the
## longitude circulates through a full turn over a vanishing distance. Squeezing latitude in the
## *direction* instead keeps the sampling continuous everywhere, since the direction is.
const EDDY_STRETCH := 3.0

## The feature size used when the body has no eddy scale to give — no `N`, no `f`, or no air. One
## circulation cell, since without a deformation radius the finest structure the flow offers is a band.
const FALLBACK_FEATURE_ANGLE := PI / 8.0

## The noise generator's character.
##
## **Eight octaves at gain 0.8, not four at 0.5, and the numbers come from a measurement rather than a
## preference.** Against a real Earth cloud map, four octaves at gain 0.5 put **62 % of the field's power
## in a single coarse octave and 0.1 % below 8 px** (spectral slope −4.08 against the reference's −2.38) —
## over half the energy in one band, and nothing at the fine end at all. Real cloud has structure at every
## scale, which is most of why it reads as cloud at a glance.
##
## Raising the gain to 0.8 and the octaves to 8 took that field to **3.1 % below 8 px and a slope of
## −2.77**, in one change and with no cost that matters: a map is baked once and does not animate.
## Vault `Cloud Layers` §2 has the table. **The gain is what flattens the distribution**, not the octave
## count — at 0.5 each octave has a quarter of the power of the one above it, so no number of them
## reaches the fine end.
const NOISE_TYPE := FastNoiseLite.TYPE_SIMPLEX_SMOOTH
const NOISE_GAIN := 0.8

## **The spectrum is split in half, and only the coarse half is warped by the eddies.**
##
## A full-turn vortex is a large shear, so it folds whatever is sampled through it. On the coarse half that
## fold *is* the spiral — the feature is the size of the curl and there is one of it. On the fine half it
## was tens of tight coils, which is why the first vortex render looked like baroque filigree rather than
## weather: `Cloud Layers` §10 called this before it was seen — *"the vortices advect the coarse field and
## the fine octaves are sampled unwarped"* — and it is the only way to have a vortex that closes its arm
## and detail down to the texel at the same time.
const COARSE_OCTAVES := 4
## Where the fine half starts, as a frequency multiple of the coarse half — `2^COARSE_OCTAVES`, because
## lacunarity is 2 and octave `n` sits at `2^n`.
const FINE_FREQUENCY := 16.0
## How much of the fine half survives on top of the coarse, as a fraction of its own deviation. The two
## halves carry comparable amplitude in the 8-octave spectrum, so this is close to one half of it.
const FINE_SHARE := 0.55


## **How far a band's edge wanders, as a fraction of a band's own width.**
##
## A look constant, of the same kind as [constant EDDY_STRETCH] — but its *shape* is derived, see
## [method bands_at]. Zero gives straight circles, which is what the field drew until 2026-10-17.
const MEANDER := 0.18

## **A second, incommensurate component of the meander**, as a fraction of the first.
##
## One sine is perfectly periodic, so a band meanders identically all the way round and reads as a
## decorative valance rather than as weather. Two harmonics whose wavenumbers are in the golden ratio never
## repeat, so the lobes vary in size the way a real wave train does — at the cost of one `sin`. **The
## fraction is a calibration**; the *first* wavenumber is the derived one and stays the primary.
const MEANDER_SECOND := 0.618
const MEANDER_SECOND_SHARE := 0.6


## **Where the bands are, allowing for the meander.** This is the function the field reads instead of
## `condensation_favouring` directly.
##
## ## Why the bands were straight, and what bends them
##
## `condensation_favouring(latitude, cells)` has no longitude in it, so its contours are circles by
## construction. Evert, 2026-10-17: *"the banding... is a bit regular straight lines. They need some large
## scale perturbation that would make the bands thicker in some places and thinner in others... we need some
## sort of driver for it from the data that we can derive."*
##
## **The driver is the stationary Rossby wavenumber, and it needs nothing new.** A Rossby wave holds
## station against the mean flow at
##
##     m(lat) = a * cos(lat) / L_Rh  =  cos(lat) / ratio
##
## because `Morphology.ratio` IS `L_Rh / a`. Earth's 0.104 gives m ≈ 9.6 at the equator and Jupiter's
## 0.045 gives ≈ 22 — planetary wave trains of the right order, from numbers the model already computes.
##
## A sinusoidal offset of the latitude at which the bands are read makes a band **wide where the sine's
## slope is shallow and narrow where it is steep**, which is exactly "thicker in some places and thinner
## in others". And because it acts on the same quantity the eddy field will act on — the latitude the bands
## are read at — the vortex spectrum will compose with it rather than fight it.
##
## **A body with no `ratio` gets straight bands**, not a guessed wavenumber: no `L_Rh` means no derived
## driver, and a fabricated one would be worse than none.
static func bands_at(
	direction: Vector3, cells: float, ratio: float, phase: float = 0.0,
	meander: float = MEANDER
) -> float:
	var latitude := asin(clampf(direction.y, -1.0, 1.0))
	if cells <= 0.0:
		return 1.0
	if ratio <= 0.0 or meander <= 0.0:
		return SpacesimCloudModel.condensation_favouring(latitude, cells)
	var longitude := atan2(direction.z, direction.x)
	var band_width := (PI * 0.5) / cells
	# **An INTEGER wave number, because a wave has to close.** `cos(lat)/ratio` is the derived stationary
	# wavenumber but it is not a whole number, and `sin(m*lon)` only meets itself at the seam when `m` is an
	# integer — with 9.6 the discontinuity was 32.5 levels at the wrap against 7.5 at every other column
	# boundary, which is the seam test catching exactly what it exists for. Only whole waves fit round a
	# planet, so the derived number is rounded; **that is a physical constraint rather than a tidy-up.**
	var wavenumber := maxf(1.0, roundf(maxf(cos(latitude), 0.0) / ratio))
	var first := sin(wavenumber * longitude + phase)
	var second := sin(wavenumber * MEANDER_SECOND * longitude + phase * 1.7)
	var offset := meander * band_width * (first + MEANDER_SECOND_SHARE * second) \
		/ (1.0 + MEANDER_SECOND_SHARE)
	return SpacesimCloudModel.condensation_favouring(latitude + offset, cells)


## **How many vortices one map carries.** A budget, because every centre costs a dot product per pixel —
## and it is the only number here that is not a derivation. The *sizes* and the *count distribution* are.
const VORTEX_BUDGET := 96

## **The exponent of the size distribution**: `N(s) ∝ s^-p`.
##
## Evert, 2026-10-17: *"usually the eddies are small, but sometimes they can be much bigger, again based on
## the science."* A power law is what makes "usually small, occasionally big" true without choosing the
## counts by hand — and `p` is a calibration, named as one. It is the same kind of constant as
## `CELLS_PER_RHINES_BAND`: the shape is physics, the number in front of it is a fit.
const VORTEX_EXPONENT := 2.0

## How many distinct sizes the spectrum is sampled at, log-spaced between the two derived scales.
const VORTEX_GENERATIONS := 6

## **How much less each smaller generation winds**, per generation.
##
## One turn for every size made a wallpaper of tight curls — 96 of them, identical, reading as baroque
## ornament rather than weather. Evert's own description is the fix: *"the larger spirals can stretch over
## multiple bands, and the smaller ones just perturb the boundaries between the layers."* So the largest
## generation turns once and each smaller one turns `VORTEX_WINDING_DECAY` of the one above it, which makes
## the big spirals the structure and the small ones the roughness on it.
const VORTEX_WINDING_DECAY := 0.55

## **The differential rotation across a vortex, in RADIANS — and this corrects an error.**
##
## The derivation above gives `ω·τ ≈ 1`, and that is **one radian, not one revolution**. Reading it as a turn
## and setting the twist to `TAU` made the edge displacement `2π·reach` = **1.57 band widths**, so a vortex
## dragged material from more than a whole band away — which is why the first renders coiled like baroque
## filigree. It is also why the two bodies looked alike in this respect: the quantity is scale-invariant,
## because `span = 4·L_Rh/a` exactly, so the displacement in *bands* is the same everywhere.
##
## **A static warp cannot carry material round once in any case.** Circulation is a *time* effect; a still
## map can only show the instantaneous differential, and what reads as a spiral arm is that differential
## sweeping the texture through a radian or two. So the honest quantity is the differential, and its
## derived size is ~1 rad, with the sweep below to see what an arm actually needs.
const VORTEX_TWIST := 2.0


## **A stack of vortices.** Centres, and per centre how far it reaches and how far it turns the field.
class Vortices:
	extends RefCounted

	var centres := PackedVector3Array()
	## `1 - cos(reach)`, so the per-pixel range test is a dot product and no trigonometry.
	var reaches := PackedFloat32Array()
	## Radians of twist at the centre, decaying to nothing at the edge.
	var twists := PackedFloat32Array()

	func is_empty() -> bool:
		return centres.is_empty()


## **The eddy spectrum, from the two scales the model already derives.**
##
## | | | |
## |---|---|---|
## | the smallest eddy | `L_D`, the Rossby deformation radius | `Morphology.eddy_angular_scale` |
## | the largest | `L_Rh`, the Rhines scale | `Morphology.ratio` |
## | how many of each | `N(s) ∝ s^-p` | [constant VORTEX_EXPONENT] |
## | how far each turns the field | **one turn** | see below |
##
## **The winding needs no constant, and that is the nicest thing here.** A vortex of size `s` in a flow of
## speed `U` turns at `ω ~ U/s` and lives for its own turnover time `τ ~ s/U`, so it turns
## `ω·τ ~ 1` — **once**, for every size. That is also exactly what Evert asked for: *"a vortex, by
## definition carries things around at least once"*, and it is why the old parameterisation (a
## displacement, which capped at a quarter turn) could never have looked like one.
##
## Placement follows §5: **the largest generation freely, the smaller ones on the band edges**, because a
## vortex that spans several bands is not anchored to one of their boundaries and one whose job is to
## perturb a boundary belongs on it.
static func vortices(
	morphology: SpacesimCloudModel.Morphology, seed_value: int, budget: int = VORTEX_BUDGET
) -> Vortices:
	var stack := Vortices.new()
	if morphology == null or budget <= 0:
		return stack
	var smallest := morphology.eddy_angular_scale
	var largest := morphology.ratio
	if smallest <= 0.0 or largest <= 0.0:
		# **No `L_D` or no `L_Rh` means no derived spectrum**, so no vortices are invented — the same rule
		# as the meander's wavenumber. A body without a wind scale gets a field with no eddies in it.
		return stack
	if smallest > largest:
		var swap := smallest
		smallest = largest
		largest = swap
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var edges := PackedFloat32Array()
	for index in int(ceil(morphology.cells * 0.5)):
		var latitude := (PI * 0.5) / maxf(morphology.cells, 1.0e-6) * (float(index) + 0.5)
		if latitude < PI * 0.5:
			edges.append(latitude)

	# The weights first, so the budget can be shared out in proportion to `s^-p`.
	var sizes := PackedFloat32Array()
	var weights := PackedFloat32Array()
	var total := 0.0
	for generation in VORTEX_GENERATIONS:
		var span := log(largest / smallest)
		var size := smallest * exp(span * float(generation) / float(maxi(VORTEX_GENERATIONS - 1, 1)))
		sizes.append(size)
		var weight := pow(size, -VORTEX_EXPONENT)
		weights.append(weight)
		total += weight
	var placed := 0
	for generation in VORTEX_GENERATIONS:
		var count := maxi(int(round(float(budget) * weights[generation] / total)), 1)
		var reach := minf(sizes[generation], PI)
		for index in count:
			if placed >= budget:
				return stack
			var longitude := rng.randf() * TAU
			var direction := Vector3.ZERO
			if generation == 0 or edges.is_empty():
				var sin_latitude := rng.randf_range(-1.0, 1.0)
				var cos_latitude := sqrt(maxf(1.0 - sin_latitude * sin_latitude, 0.0))
				direction = Vector3(
					cos_latitude * cos(longitude), sin_latitude, cos_latitude * sin(longitude)
				)
			else:
				var latitude := edges[rng.randi_range(0, edges.size() - 1)]
				var side := 1.0 if rng.randf() < 0.5 else -1.0
				direction = Vector3(
					cos(latitude) * cos(longitude), side * sin(latitude),
					cos(latitude) * sin(longitude)
				)
			stack.centres.append(direction)
			stack.reaches.append(1.0 - cos(reach))
			# One turn for the largest generation, decaying per generation below it, and falling from the
			# centre to nothing at the reach.
			stack.twists.append(VORTEX_TWIST * pow(VORTEX_WINDING_DECAY, float(generation)))
			placed += 1
	return stack


## **The sample after the eddies have carried it.** Tangential, decaying outward, summed over the stack —
## so a large vortex moves whole bands while the small ones rough up their edges on top of it.
##
## `centre.cross(unit)` is the tangential direction and also the first-order rotation of the sample about
## `centre`, so this is a real turn rather than a push: **a translation can only wave a field, never spiral
## it.**
static func advect(unit: Vector3, stack: Vortices) -> Vector3:
	if stack == null or stack.is_empty():
		return unit
	var twist := Vector3.ZERO
	var centres := stack.centres
	var reaches := stack.reaches
	var twists := stack.twists
	for index in centres.size():
		var centre := centres[index]
		var falloff := 1.0 - (1.0 - unit.dot(centre)) / reaches[index]
		if falloff <= 0.0:
			continue
		twist += centre.cross(unit) * (twists[index] * falloff * falloff)
	return (unit + twist).normalized()


## **One pixel's value, with everything applied in the order the physics puts it.**
##
## 1. the sample is carried by the eddies ([method advect]);
## 2. the bands are read at the **carried** position — which is what lets an arm drag cloud across a lane
##    rather than hitting the envelope's veto;
## 3. the eddies are read at the carried position too, so the texture inside the arm is the arm's own.
##
## **The bake comes through here and its GLSL twin is a transcription of it**, so the two cannot describe
## different fields.
##
## **It takes plain numbers, not a `Morphology`, and that is the port surface.** A shader cannot be handed
## a Resource, so the four derived values it needs arrive as scalars: `mix` is
## [method mixing], and `cells`, `ratio` and `feature` are the `Morphology`'s own fields (the last from
## [method feature_angle]). Everything here is then either a scalar or a packed array, which is what makes
## the GLSL twin a port rather than a rewrite — see vault `GPU Texture Generation Plan`.
static func intensity_at(
	direction: Vector3,
	mix: float, cells: float, ratio: float, feature: float,
	noise: FastNoiseLite, stack: Vortices, phase: float,
	fine: FastNoiseLite = null
) -> float:
	var unit := direction.normalized()
	var sample := advect(unit, stack)
	# **The floor: the bands are cloud-POOR, never cloud-free**, and `mix` is the number that lifts them — the
	# same derived quantity the verdict already produces. `Cloud Layers` §"The floor's driver" has the table.
	var envelope := mix + (1.0 - mix) * bands_at(sample, cells, ratio, phase)
	# **The eddies read the carried sample; the detail reads the still one.** `fine` may be null, in which
	# case there is no high half to add — which is what a caller that only has one generator gets.
	var coarse := eddy_at(sample, feature, noise)
	var eddy := coarse
	if fine != null:
		eddy = clampf(coarse + (eddy_at(unit, feature, fine) - 0.5) * FINE_SHARE, 0.0, 1.0)
	if mix <= 0.0 or noise == null:
		return envelope
	# **Normalising this by `1 + mix` was tried and reverted: it broke the light budget.** Bounding the
	# modulation keeps the field out of the top byte and fixes the percentile ties, but it also compresses
	# the field toward its threshold — Earth's mean exceedance fell from ~0.7 to **0.177**, and since the
	# ramp's gain is `(albedo/palette)/mean` it then needed a gain of 2.75, clamped to 1, leaving the deck's
	# drawn average at **0.152 against its calibrated 0.419**. A field whose mean exceedance is that low
	# cannot reach its albedo without exceeding white somewhere, which is exactly what the clamp forbids.
	# So the mean has to stay where the calibration expects it, and the *clamp* is the honest behaviour.
	return _soft_ceiling(envelope * (1.0 - mix + mix * eddy * 2.0))


## **A soft ceiling instead of a hard clamp.**
##
## `envelope * modulation` can reach `1 + mix`, and with the floor holding the envelope at `>= mix` a
## SHREDDED body pushes **30 % of its texels past 1.0**. A hard clamp piles every one of them on the top
## byte, and a percentile threshold cannot separate a bin from its contents — which is how the coverage
## check found this: asking for 25 % returned 29.5 % with the threshold stuck at 1.000.
##
## Normalising the whole modulation by `1 + mix` fixes the pile but compresses the field toward its
## threshold, and that broke the light budget (mean exceedance 0.7 -> 0.177, so the ramp needed a gain of
## 2.75, clamped to 1, and the deck drew 0.152 against its calibrated 0.419).
##
## This does neither: below the knee nothing changes, and above it the excess is mapped *asymptotically*
## into the remaining range, so the top stays ordered and spread instead of collapsed onto one value.
const SOFT_KNEE := 0.85

static func _soft_ceiling(value: float) -> float:
	if value <= SOFT_KNEE:
		return maxf(value, 0.0)
	return SOFT_KNEE + (1.0 - SOFT_KNEE) * (
		1.0 - exp(-(value - SOFT_KNEE) / (1.0 - SOFT_KNEE))
	)


## The phase a seed gives the meander, so two bodies — and two layers of one body — wander differently.
static func meander_phase(seed: int) -> float:
	return float(absi(seed) % 6283) / 6283.0 * TAU


## A stable seed for one layer of one body. **Deterministic from the body's id**, so the same world
## regenerates the same weather — which is what `Cosmos and Discovery` needs of everything generated, and
## the reason a save can be a short string rather than a picture.
static func seed_for(body_id: String, layer: int) -> int:
	return hash(body_id) + layer * 7919


## The generator for a seed. **Built on demand and never shared**: it is the one piece of state here, and
## a map bake runs on a worker thread.
static func noise_for(seed: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = NOISE_TYPE
	noise.seed = seed
	# One unit of noise space is one eddy; the *caller* decides how much of it a direction spans, so the
	# frequency stays at 1 and the size lives in `eddy_at`. Two places to set the same scale is one too
	# many.
	noise.frequency = 1.0
	noise.fractal_octaves = COARSE_OCTAVES
	noise.fractal_gain = NOISE_GAIN
	noise.fractal_lacunarity = 2.0
	return noise


## How much this body's eddies break its bands.
static func mixing(banding: int) -> float:
	match banding:
		SpacesimCloudModel.Banding.BANDED:
			return MIXING_BANDED
		SpacesimCloudModel.Banding.SHREDDED:
			return MIXING_SHREDDED
		_:
			return MIXING_NONE


## The angular size of one eddy, in radians — the body's if it has one, a band's width if it does not.
static func feature_angle(morphology: SpacesimCloudModel.Morphology) -> float:
	if morphology.eddy_angular_scale > 0.0:
		return morphology.eddy_angular_scale
	if morphology.cells > 0.0:
		return (PI * 0.5) / morphology.cells
	return FALLBACK_FEATURE_ANGLE


## The eddy field at a **UNIT** direction, 0 to 1, its mean at 0.5.
##
## `unit` must already be unit length — this is the inner loop's entry point, and normalising a vector
## that is unit by construction is a square root a pixel that buys nothing.
##
## The direction is **squeezed in latitude and renormalised**, which stretches the features zonally by
## [constant EDDY_STRETCH] — and it does that without a pole singularity, because a direction has none.
static func eddy_at(unit: Vector3, feature_angle: float, noise: FastNoiseLite) -> float:
	if noise == null or feature_angle <= 0.0:
		return 0.5
	# **Longitude, not latitude, and this was the wrong way round until 2026-10-16.** The noise varies
	# *slowly* along whichever axis is divided, so features are elongated along it. Dividing `y` made the
	# eddies long in **latitude** — vertical fibre on a map, the opposite of the documented intent and the
	# opposite of what zonal jets do, where eddies are stretched **east-west**. Dividing the equatorial
	# components instead is what the constant says it means.
	var stretched := Vector3(
		unit.x / EDDY_STRETCH, unit.y, unit.z / EDDY_STRETCH
	).normalized()
	# `get_noise_3d` returns -1 to 1; the field wants 0 to 1 with its mean at a half.
	return (noise.get_noise_3d(
		stretched.x / feature_angle, stretched.y / feature_angle, stretched.z / feature_angle
	) + 1.0) * 0.5


## **The fine half of the spectrum**, which the eddies do NOT carry.
##
## Same seed and gain, starting four octaves up. Sampled at the *physical* direction rather than the
## advected one, so detail sits still while the shapes swirl around it.
static func fine_for(seed: int) -> FastNoiseLite:
	var noise := noise_for(seed)
	noise.frequency = FINE_FREQUENCY
	return noise


## How much of the field is generated before the engine goes away
##
## **A question a long bake asks once a row: should it still bother?** A bake is up to 27 seconds of work,
## and the pool requires every task to be awaited before the engine goes away — so a run that quits with
## one still going takes the process down with it, which is exactly what the headless smoke load did
## (exit 139, no output). Waiting for it whole is not an option either: quitting would hang for the
## length of the bake.
##
## Rows are the natural checkpoint. A bake that stops at one loses at most a row of work, the caller
## sees `null` rather than a map, and the exit waits milliseconds.
class Bail:
	extends RefCounted
	var asked := false


## **Everything a bake derives from a seed and a morphology, in one place.**
##
## Two consumers ask for the same field by different routes — [method bake] on the CPU and
## `SpacesimCloudGpu.bake()` on the GPU — and the derivation below is the part that must not be written
## twice: a second copy of "which bands, how much mixing, which vortices" is how two paths come to bake
## two different worlds from one seed.
##
## **The generators stay objects on this side.** A shader cannot hold a `FastNoiseLite`, so the GPU path
## reads the parameters off these and builds its own; what it must not do is derive them again.
class Plan:
	extends RefCounted

	var mix := 0.0
	var cells := 0.0
	var ratio := 0.0
	var feature := FALLBACK_FEATURE_ANGLE
	## A featureless or unmeasured body: a flat field, no generator, nothing to threshold.
	var uniform := true
	var phase := 0.0
	var stack: Vortices = null
	## The low half of the spectrum. Null whenever the field will not be read.
	var noise: FastNoiseLite = null
	## The high half, sampled unwarped. Null exactly when `noise` is.
	var fine: FastNoiseLite = null


## The plan for one bake: the four derived numbers, the meander phase, the eddy spectrum and the two
## generators.
static func plan(seed: int, morphology: SpacesimCloudModel.Morphology) -> Plan:
	var result := Plan.new()
	if morphology != null:
		result.mix = mixing(morphology.banding)
		result.cells = morphology.cells
		result.ratio = morphology.ratio
		result.feature = feature_angle(morphology)
		result.uniform = morphology.banding == SpacesimCloudModel.Banding.FEATURELESS \
			or morphology.banding == SpacesimCloudModel.Banding.UNKNOWN
	# **The generator is only built when the field will use it.** A featureless body would otherwise pay to
	# generate noise for a flat sheet — the waste Evert's "skip the noise generation" is about.
	if not result.uniform and result.mix > 0.0:
		result.noise = noise_for(seed)
		result.fine = fine_for(seed)
	# The meander's phase comes from the seed, so two bodies — and two layers of one body — wander
	# differently while each stays reproducible.
	result.phase = meander_phase(seed)
	# **The eddy spectrum, built once for the whole map** — built in the loop it would be 8 million
	# spectra. Its own seed is offset so its pattern is not the noise's.
	result.stack = vortices(morphology, seed + 1049)
	return result


## **The FBM normaliser FastNoiseLite computes** — `1 / (1 + g + g² + …)` over the octaves.
##
## Here rather than in the shader because it is derived from two constants that live on this side, and a
## number typed into GLSL is a number that drifts from the generator it was supposed to match.
static func fractal_bounding(octaves: int, gain: float) -> float:
	var amp := gain
	var total := 1.0
	for index in range(1, maxi(octaves, 1)):
		total += amp
		amp *= gain
	return 1.0 / total


## **One layer's coverage map for a body**: equirectangular, `width` x `height`, one channel.
##
## `FORMAT_L8` because coverage is a scalar — colour is a derived constant, not something a map has to
## carry — and one channel is a quarter of the memory and a quarter of the bake for the same picture.
##
## **The parameterisation is a direction, so latitude is `asin(y)` and the rotation axis is `+Y`.** The
## map's top row is the north pole; the seam at ±180 degrees is continuous, because the field is a
## function of direction and `cos`/`sin` meet there.
##
## **Pure, and safe to run on a worker thread** — it allocates an `Image` and touches nothing else.
## Measured costs to size a bake against: 2048x1024 in 192 ms and 8192x4096 in 3.1 s for the noise
## generator alone, before this field's own arithmetic; **7 µs a pixel** measured end to end (2026-10-25) —
## so 1,024x512 takes 3.7 s and an 8192x4096 map takes about 230 s. The end-to-end figure read 0.80 µs
## until it was re-measured, which is the noise generator's own cost and not the field's.
##
## `bail` is optional and is what lets a bake be abandoned mid-flight — see [Bail].
static func bake(
	seed: int, morphology: SpacesimCloudModel.Morphology, width: int, height: int, bail: Bail = null,
	uv_origin: Vector2 = Vector2(0.0, 0.0), uv_size: Vector2 = Vector2(1.0, 1.0)
) -> Image:
	var w := maxi(width, 1)
	var h := maxi(height, 1)
	var bytes := PackedByteArray()
	bytes.resize(w * h)
	var baked := plan(seed, morphology)
	var mix := baked.mix
	var cells := baked.cells
	var ratio := baked.ratio
	var feature := baked.feature
	var uniform := baked.uniform
	var phase := baked.phase
	var stack := baked.stack
	var noise := baked.noise
	var fine := baked.fine

	for row in h:
		# The checkpoint, once a row: a bake that is no longer wanted returns nothing rather than a
		# map nobody would see.
		if bail != null and bail.asked:
			return null
		# **A window is a rectangle in the map's own `(u, v)`** — the whole body when `uv_size` is one, which
		# is what every bake did before the address existed. The mapping out is still `u` around the equator
		# and `v` from pole to pole, so a window is an offset and a scale and nothing else changes.
		var v := uv_origin.y + (float(row) + 0.5) / float(h) * uv_size.y
		var latitude := PI * 0.5 - v * PI
		var cos_latitude := cos(latitude)
		var sin_latitude := sin(latitude)
		# **No longer hoisted, and that is the meander's price.** The bands used to depend on latitude
		# alone, so a row shared one value; with a longitude-dependent wavenumber they do not, and the
		# `sin` and the `condensation_favouring` move into the column loop. A bake is a one-off, so this
		# is the right trade.
		for column in w:
			var longitude := (
				uv_origin.x + (float(column) + 0.5) / float(w) * uv_size.x - 0.5
			) * TAU
			# Unit by construction: `cos^2(lat)cos^2(lon) + sin^2(lat) + cos^2(lat)sin^2(lon) = 1`.
			var direction := Vector3(
				cos_latitude * cos(longitude), sin_latitude, cos_latitude * sin(longitude)
			)
			var value := 1.0 if uniform else intensity_at(
				direction, mix, cells, ratio, feature, noise, stack, phase, fine
			)
			bytes[row * w + column] = int(clampf(value, 0.0, 1.0) * 255.0)
	return Image.create_from_data(w, h, false, Image.FORMAT_L8, bytes)
