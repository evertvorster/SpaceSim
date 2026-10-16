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

## The noise generator's character, and it is a detail setting rather than a look one: smooth simplex
## because the field is a cloud and not a heightmap, and four octaves because that is where a render
## stops being able to tell.
const NOISE_TYPE := FastNoiseLite.TYPE_SIMPLEX_SMOOTH
const NOISE_OCTAVES := 4


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
	noise.fractal_octaves = NOISE_OCTAVES
	noise.fractal_gain = 0.5
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
	var stretched := Vector3(unit.x, unit.y / EDDY_STRETCH, unit.z).normalized()
	# `get_noise_3d` returns -1 to 1; the field wants 0 to 1 with its mean at a half.
	return (noise.get_noise_3d(
		stretched.x / feature_angle, stretched.y / feature_angle, stretched.z / feature_angle
	) + 1.0) * 0.5


## **The field, written down once.** Everything else here is a wrapper around this.
##
## `bands`, `mix` and `feature` are the row-invariant parts — a band value depends only on latitude, and
## the other two not even on that — so a bake hoists them and an individual query computes them here.
## **That hoisting is the whole reason this exists as a separate function**: without it a per-pixel bake
## pays for a `cos` and a `sqrt` that one row of pixels shares.
static func intensity_unit(
	unit: Vector3, bands: float, mix: float, feature: float, noise: FastNoiseLite
) -> float:
	if mix <= 0.0 or noise == null:
		return bands
	# The bands are the ENVELOPE and the eddies modulate them, so the structure the circulation imposes
	# survives at every mixing strength — see the class comment.
	return clampf(bands * (1.0 - mix + mix * eddy_at(unit, feature, noise) * 2.0), 0.0, 1.0)


## **The field at a direction**: 0 is clear, 1 is full cloud.
##
## `morphology` may be a plain object with `banding`, `cells` and `eddy_angular_scale` — the shape is what
## matters, so a shader twin can be checked against this one.
static func intensity(
	direction: Vector3, morphology: SpacesimCloudModel.Morphology, noise: FastNoiseLite
) -> float:
	if morphology == null:
		return 1.0
	if morphology.banding == SpacesimCloudModel.Banding.FEATURELESS:
		# **The noise is skipped, not merely quiet.** A uniform field needs no generator, and the caller
		# is not asked to build one.
		return 1.0
	var unit := direction.normalized()
	var latitude := asin(clampf(unit.y, -1.0, 1.0))
	return intensity_unit(
		unit,
		SpacesimCloudModel.condensation_favouring(latitude, morphology.cells),
		mixing(morphology.banding),
		feature_angle(morphology),
		noise
	)


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
## generator alone, before this field's own arithmetic; **0.80 µs a pixel** measured end to end.
##
## `bail` is optional and is what lets a bake be abandoned mid-flight — see [Bail].
static func bake(
	seed: int, morphology: SpacesimCloudModel.Morphology, width: int, height: int, bail: Bail = null
) -> Image:
	var w := maxi(width, 1)
	var h := maxi(height, 1)
	var bytes := PackedByteArray()
	bytes.resize(w * h)
	# **The generator is only built when the field will use it.** A featureless body would otherwise pay to
	# generate noise for a flat sheet — the waste Evert's "skip the noise generation" is about.
	var mix := 0.0
	var cells := 0.0
	var feature := FALLBACK_FEATURE_ANGLE
	var uniform := true
	if morphology != null:
		mix = mixing(morphology.banding)
		cells = morphology.cells
		feature = feature_angle(morphology)
		uniform = morphology.banding == SpacesimCloudModel.Banding.FEATURELESS \
			or morphology.banding == SpacesimCloudModel.Banding.UNKNOWN
	var noise: FastNoiseLite = null
	if not uniform and mix > 0.0:
		noise = noise_for(seed)

	for row in h:
		# The checkpoint, once a row: a bake that is no longer wanted returns nothing rather than a
		# map nobody would see.
		if bail != null and bail.asked:
			return null
		var latitude := PI * 0.5 - (float(row) + 0.5) / float(h) * PI
		var cos_latitude := cos(latitude)
		var sin_latitude := sin(latitude)
		# **Hoisted out of the column loop**: the bands depend on latitude alone, so a row of pixels
		# shares one value of them.
		var bands := SpacesimCloudModel.condensation_favouring(latitude, cells)
		for column in w:
			var longitude := (float(column) + 0.5) / float(w) * TAU - PI
			# Unit by construction: `cos^2(lat)cos^2(lon) + sin^2(lat) + cos^2(lat)sin^2(lon) = 1`.
			var direction := Vector3(
				cos_latitude * cos(longitude), sin_latitude, cos_latitude * sin(longitude)
			)
			var value := 1.0 if uniform else intensity_unit(direction, bands, mix, feature, noise)
			bytes[row * w + column] = int(clampf(value, 0.0, 1.0) * 255.0)
	return Image.create_from_data(w, h, false, Image.FORMAT_L8, bytes)
