class_name SpacesimCloudBand
extends RefCounted
## **A deck as a slab on a ray: how deep a column is, how far through it the eye looks, and how many
## samples that chord deserves.** Arithmetic only — no node, no shader, no GPU.
##
## This is the near regime's specification, and it exists because of how the three previous attempts on
## the cloud *failed*: not from a wrong picture, but from an unobservable one. The deck was opaque within
## its first sample at the limb — a 654 km chord through a band whose extinction is 0.238 per kilometre is
## 156 optical depths, and `1 - exp(-39)` is 1 to seventeen digits — so every step after the first
## contributed `transmittance = 0`, and three rewrites rearranged samples behind an opaque lid. **Nothing
## in the shader could report that.** Here it is four functions and a test.
##
## ## The two laws, and why the step is not a choice
##
## A ray's chord through a band is geometry; how finely that chord must be marched is optics. They are
## separate, and the second is the one that gets fudged:
##
##     samples = ceil(chord * extinction * SAMPLES_PER_OPTICAL_DEPTH)
##
## because **a sample may not advance more than a sixth of an e-fold of optical depth** — past that it
## integrates through a quantity it cannot represent, which is what a lid is. The sample count therefore
## *follows* from the geometry instead of being chosen, and it is why one step budget can never serve both
## a view straight down and the limb: on Earth the same deck is 1.6 km deep looking down and ~286 km of
## chord seen edge-on.
##
## The opaqueness bound is what makes the limb affordable rather than accurséd: a march stops at
## `T < OPACITY_BOUND`, so at a sixth of an e-fold **`stop_steps()` samples is the ceiling whatever the
## chord**. A 286 km chord deserves ~409 samples and takes 28, and the march reports the transmittance of
## 28 steps rather than the `1e-30` the uncapped exponential would give. That difference is the whole of
## "the deck is a lid", and it is asserted.
##
## ## Units
##
## Metres, and extinction per metre. A layer's `optical_depth` is stated along the **local vertical**, so
## the nominal column that turns it into a per-metre coefficient is **half a scale height of the air it
## sits in** — `extinction = tau / (scale_height * 0.5)`, which is why a full-depth column comes to `2·tau`.
## The factor of two is stated here rather than discovered in a shader.
##
## ## What is deliberately not here
##
## Per-channel extinction. `Cloud Volumes` §4.3 says a tinted deck must tint both what it reflects and what
## it lets through, so the real quantity is a `vec3`. Nothing downstream can use that yet — every layer in
## Sol leaves `optical_depth` unstated and takes the scalar fallback — so this is scalar and the change to
## per-channel is one signature, not a rewrite. Naming the gap is the point.

## **A sample may not advance more than this fraction of an e-fold.** Six is the number
## `Cloud Volumes` §4.3a derives its sample counts from, and it is the reason `stop_steps()` is 28 rather
## than "a few dozen".
const SAMPLES_PER_OPTICAL_DEPTH := 6.0

## Where a march stops: below this transmittance the remaining samples contribute nothing a frame can show,
## and paying for them is what made the limb unaffordable.
const OPACITY_BOUND := 0.01

## The optical depth one sample is allowed to carry, derived from the budget above rather than restated.
const TAU_PER_STEP := 1.0 / SAMPLES_PER_OPTICAL_DEPTH


## **How tall this column's cloud is, in metres** — the map's value read as a height, not as an alpha.
##
## A flat base and a varying top is cumulus: the base is a plane, and only the top follows the field. So a
## lateral edge is a **taper rather than a cut** — as `value` falls to `threshold` the column's height falls
## to zero, its chord falls to zero, and its optical depth is zero *by arithmetic* rather than by a softness
## constant. That is the difference between a cloud edge and cut paper, and it also makes the "no cloud here"
## case a gap rather than a special case.
##
## `value` is the map's own field value in the direction of the sample — `0..1` as baked — and `threshold`
## is the percentile that turns the layer's authored coverage into a field value
## (`SpacesimCloudMaps.threshold_for`), so the fraction of the area above it is the coverage that was asked
## for. `full_height` is the deepest the column ever gets: the condensate scale height the model already
## derives (`SpacesimAtmosphereModel.Condensation.thickness`), so a body's deck depth moves with its air and
## not with a number somebody typed here.
static func column_top(value: float, threshold: float, full_height: float) -> float:
	if full_height <= 0.0 or threshold >= 1.0 or value <= threshold:
		return 0.0
	return full_height * (value - threshold) / (1.0 - threshold)


## **Extinction per metre, from a layer's optical depth down the local vertical.**
##
## `optical_depth > 0` is the authored case: the layer states how much light it stops, and the nominal
## column that turns it per-metre is half a scale height of the air — so the full column is `2·tau`, which is
## stated rather than discovered.
##
## `optical_depth == 0` means **not stated**, which is the convention every other model in this engine uses
## for a zero, and every layer but the two giants takes it. The fallback is `1 / (scale_height * 0.5)` — one
## e-fold per half scale height — which is an authored-looking number with a physical reading: it draws a
## deck that is convincingly opaque over its own depth and no further. **It is also what made the deck an
## opaque lid**, and the arithmetic that follows from it is why: on Earth that is 0.238 per kilometre, so a
## limb chord of 286 km is 68 optical depths. The fallback is not wrong; a *step budget that ignores it* is.
##
## A body with no scale height (`scale_height <= 0`) has no air to put a deck in, and comes back `0` — a
## clear column, not an infinite coefficient.
static func extinction(optical_depth: float, scale_height: float) -> float:
	var nominal := scale_height * 0.5
	if nominal <= 0.0:
		return 0.0
	if optical_depth > 0.0:
		return optical_depth / nominal
	return 1.0 / nominal


## **The length of the ray's path inside the band**, in metres, given the band's two radii and the ray's
## closest approach to the body's centre (`impact`).
##
## Three cases, and they are what make one step budget impossible:
##
## | `impact` | the view | chord |
## |---|---|---|
## | `>= outer` | the ray misses the band | `0` |
## | `>= base` | grazing: the deck seen edge-on | `2·sqrt(outer² − impact²)` |
## | `< base` | down through it at the body | `sqrt(outer² − impact²) − sqrt(base² − impact²)` |
##
## **`impact = 0` returns exactly the slab's thickness**, which is the anchor: straight down through a band
## is the depth of the band and nothing else. Every other value is longer, and the growth is not gentle —
## on Earth a 1.6 km condensate deck has a ~286 km chord at the limb, a factor of ~178. **A quadrature that
## suits one view is therefore certain to be wrong for the other**, and the ratio is what the test pins.
##
## A ray that passes inside the body's own radius still has a real chord — the band above the ground — so
## `impact < base` is a normal case and not an error. Only the degenerate band (`outer <= base`) returns
## zero.
static func chord(outer: float, base: float, impact: float) -> float:
	if outer <= base or outer <= 0.0:
		return 0.0
	var closest := absf(impact)
	if closest >= outer:
		return 0.0
	var through_outer := sqrt(outer * outer - closest * closest)
	if closest >= base:
		return 2.0 * through_outer
	return through_outer - sqrt(maxf(base * base - closest * closest, 0.0))


## **The spans of the band along a ray**, as distances from the eye — `[lo0, hi0, lo1, hi1]` in metres, an
## empty pair given as `lo == hi`.
##
## One span normally, **two when the ray dips below the base** (the band either side of its closest approach),
## and none when the ray misses the outer sphere altogether. `along` is the cosine between the eye's own
## position vector and the ray: `-1` looks straight at the centre and `+1` straight away from it, and
## `impact = eye_radius · sqrt(1 - along²)` follows from it.
##
## **This exists because its absence cost a flight.** The first version of the shader took the outer sphere's
## span and clamped it at the base only when the base's *near root was ahead* — which is false for an eye below
## the base, where the clamp then silently did nothing and the march ran the whole column down to the ground.
## Evert, 2026-10-20: *"below the ground textures are invisible, just a grey haze. Then, it's a grey haze all
## the way down to the surface."* The law is here so that its consequence can be asserted without a GPU;
## `SpacesimAtmospherePass`'s `deck_span()` is its transcription into GLSL.
static func spans(eye_radius: float, along: float, top_radius: float, base_radius: float) -> PackedFloat32Array:
	var empty := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	if top_radius <= base_radius or eye_radius <= 0.0:
		return empty
	var impact_squared := eye_radius * eye_radius * maxf(1.0 - along * along, 0.0)
	var outer_half := top_radius * top_radius - impact_squared
	if outer_half <= 0.0:
		return empty
	outer_half = sqrt(outer_half)
	# The ray's closest point, as a distance from the eye: positive when it is ahead, which is what decides
	# whether a span lands in front of the observer at all.
	var closest := -eye_radius * along
	var base_half := base_radius * base_radius - impact_squared
	if base_half <= 0.0:
		return PackedFloat32Array([closest - outer_half, closest + outer_half, 0.0, 0.0])
	base_half = sqrt(base_half)
	return PackedFloat32Array([
		closest - outer_half, closest - base_half, closest + base_half, closest + outer_half,
	])


## **The samples a chord deserves** — `ceil(chord · extinction · SAMPLES_PER_OPTICAL_DEPTH)`.
##
## Floored at one: every ray that is in a band costs a sample, because that sample is what carries the
## band's own transmittance. A clear column (`extinction <= 0`), or a ray that misses (`chord <= 0`), also
## answers one — a march is never asked to run zero times, which keeps callers from having to special-case
## the empty one.
static func samples(chord_length: float, extinction_per_metre: float) -> int:
	if chord_length <= 0.0 or extinction_per_metre <= 0.0:
		return 1
	return maxi(1, ceili(chord_length * extinction_per_metre * SAMPLES_PER_OPTICAL_DEPTH))


## **The sample count a march can never exceed, whatever the chord**: `ceil(ln(1/T_stop) / τ_step)`.
##
## Derived from `OPACITY_BOUND` and `TAU_PER_STEP` rather than written down as 28 — the number is a
## consequence, and a consequence that gets typed in is a consequence that drifts when either end moves.
static func stop_steps() -> int:
	return ceili(log(1.0 / OPACITY_BOUND) / TAU_PER_STEP)


## **What a correctly stepped march actually reports** for this chord — which is *not* `exp(−τ)` for a thick
## band, and the difference is the point of the whole file.
##
## The march walks in steps of `TAU_PER_STEP` until either the chord is used up or `T < OPACITY_BOUND`. So the
## optical depth it can actually integrate is **`min(chord·extinction, stop_steps()·τ_step)`** — the chord's
## own τ for anything thin enough to finish, and a ceiling of `≈4.605` for anything that is not. For Earth's
## limb that is **`exp(−28/6) ≈ 0.0094`**: finite, and just under the bound it stopped at. `exp(−68) ≈ 3e-30`
## is what the naive exponential gives, and a value that small silences everything the march would have added.
##
## **A thin band is unaffected** — below the ceiling this is exactly `exp(−τ)`, which matters because most
## decks on most rays are thin and the discretisation must not become the answer there.
static func marched_transmittance(chord_length: float, extinction_per_metre: float) -> float:
	if chord_length <= 0.0 or extinction_per_metre <= 0.0:
		return 1.0
	var reachable := float(stop_steps()) * TAU_PER_STEP
	return exp(-minf(chord_length * extinction_per_metre, reachable))
