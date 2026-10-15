class_name SpacesimExposureMeter
extends RefCounted
## The **frame metre**: one exposure number, read from the rendered pixels.
##
## ## Why this exists
##
## Godot bakes the exposure into each *path* — `light_data.energy *= exposure_normalization_factor`,
## `light_storage.cpp:765` — so the ambient receives none at all (measured 2026-10-15: exposure ×1,
## ×1000 and ×80000 give byte-identical pixels), `_place_point` has to hand-multiply the splat, and the
## star's disc is a documented exception. The lighting plan's §6a replaces all of that with one
## frame-wide multiply, and **this is the part that decides what that multiply is.**
##
## Evert, 2026-10-15: *"a full screen meter, centre weighted. So, if I point my camera at a bright
## object, the entire frame dims, but if that same object is only a small part of the perimeter, it
## should only contribute a little to the dimming effect."* And: *"The EV compensation should not be
## location aware at all, only adjust to what is on the screen."*
##
## ## Everything here is arithmetic
##
## The caller supplies luminances and gets a multiplier back: no nodes, no `Image`, no GPU. That is the
## shape `SpacesimLod` and `SpacesimLuminance` established — arithmetic out, policy in — and it is what
## makes the metre's *behaviour* checkable headlessly. The only part of Track B that can be.
##
## **The metre's own policy is the three constants below**, and each says what it is for. What is *not*
## here is the smoothing (it stays in `SpacesimExposure`, where the existing lerp already lives) and the
## frame-wide multiply (Track B3).

## The weight's scale, in units of the frame's **half-diagonal**: the centre is `(0,0)` and a corner is
## at distance 1.
##
## `w(r) = exp(-(r / SIGMA)^2)`, so at 0.4 of the half-diagonal a sample carries 37% of the centre's
## weight, at 0.7 it carries 5%, and in the corners 0.2%. That is deliberately **selective**: it is what
## makes a bright thing at the periphery contribute "only a little", which is the requirement.
##
## **This is a look value, not a physical one** — the one number here that could be tuned without
## anything becoming wrong. It is also scale-free in the sense that matters: the weights are normalised,
## so a *uniformly* lit frame gives back its own brightness whatever `SIGMA` is. Only the selectivity
## moves.
const SIGMA := 0.4

## The **reference white**, in the scene's own absolute currency: 1.0 is the value a white Lambertian
## under `REFERENCE_LUX` produces (measured 2026-10-15, `tests/probe_range.gd`).
##
## A sample brighter than this counts as white and no more, which is what stops one source from owning
## the average. **It is frame control, not protection for the star's brightness** — a disc authored at
## 24× white survives any realistic dim, because 4.5 stops brings 24 down to 1.0 and it is still
## clipping, so the glare takes care of itself.
const CAP := 1.0

## Where the metre drives the frame: **middle grey**, linear.
##
## Derived rather than chosen, as far as it can be. The project's own convention is that the light at
## which no correction is applied is `REFERENCE_LUX`, and a scene of 18%-grey surfaces lit at that level
## sits at about 0.24 in this currency — measured, `probe_range.gd`: a white face-on Lambertian reads
## `lux / ~95,700`, so 1 au gives 1.28 and an 18% grey card 0.23. Middle grey is 0.18, half a stop under
## that, which makes the metre **neutral on an ordinarily-lit scene** and willing to move only when the
## light or the composition is unusual. The window does the bounding, not this constant.
const TARGET_AVERAGE := 0.18


## The **luminance** of a linear colour: **Rec.709 in linear light**, and the one expression the metre
## uses.
##
## `SpacesimExposurePass` carries the same coefficients in its sampling shader, because a compute shader
## cannot call GDScript. **This is the source of truth** and `tests/test_meter.gd` pins the numbers, so a
## change here that is not mirrored in the shader is a failing test rather than a quiet disagreement.
##
## **Godot's own reduction uses `max(r, g, b)` instead** (`luminance_reduce.glsl`), which over-weights a
## saturated colour: to it a deep blue sky and a bright white one read the same. That crudeness is part
## of why its metre was not usable here, alongside the missing weighting and cap.
static func luminance(colour: Color) -> float:
	return 0.2126 * colour.r + 0.7152 * colour.g + 0.0722 * colour.b


## The weight of a sample, given its offset from the frame centre **in half-diagonal units**.
##
## Monotonic in the radius, 1.0 at the centre and `exp(-1/SIGMA^2)` at a corner — 0.0019 at the default.
static func weight(offset: Vector2) -> float:
	return exp(-(offset.length_squared()) / (SIGMA * SIGMA))


## The capped, weighted mean luminance of a grid of samples, row-major.
##
## `width` and `height` describe `samples`; the centre is the grid's own centre, so the caller can hand
## in whatever resolution it reduced the frame to and the weighting is the same shape either way.
##
## Returns 0.0 for an empty or weightless grid, which the target turns into the window's ceiling rather
## than a division by zero.
static func weighted_mean(samples: PackedFloat32Array, width: int, height: int) -> float:
	if width <= 0 or height <= 0 or samples.is_empty():
		return 0.0
	var centre := Vector2((float(width) - 1.0) * 0.5, (float(height) - 1.0) * 0.5)
	# The distance from the centre to a corner, in samples — which is 1.0 in the units `weight` takes.
	# A 1x1 grid has none, and its single sample *is* the centre.
	var half_diagonal := centre.length()

	var total := 0.0
	var weight_sum := 0.0
	for y in height:
		for x in width:
			var index := y * width + x
			if index >= samples.size():
				break
			var offset := Vector2(float(x), float(y)) - centre
			if half_diagonal > 0.0:
				offset /= half_diagonal
			var w := weight(offset)
			total += w * minf(maxf(samples[index], 0.0), CAP)
			weight_sum += w
	if weight_sum <= 0.0:
		return 0.0
	return total / weight_sum


## The multiplier that would put `mean_luminance` at `TARGET_AVERAGE`, bounded by the exposure's own
## window.
##
## **A frame with nothing in it pins at the ceiling rather than running away**, which is the lower bound
## Evert asked for — it must not try to boost zero into grey. That is the same answer
## `SpacesimExposure.target_multiplier` gives for no light, and the window is what makes it safe: past
## `MAX_MULTIPLIER` the eye has given up, and `MIN_MULTIPLIER` is the fully light-adapted end.
static func target_multiplier(mean_luminance: float) -> float:
	if mean_luminance <= 0.0:
		return SpacesimExposure.MAX_MULTIPLIER
	return clampf(
		TARGET_AVERAGE / mean_luminance, SpacesimExposure.MIN_MULTIPLIER,
		SpacesimExposure.MAX_MULTIPLIER
	)


## The whole metre in one call, for the caller that has a grid and wants a number.
static func target_multiplier_for_grid(
	samples: PackedFloat32Array, width: int, height: int
) -> float:
	return target_multiplier(weighted_mean(samples, width, height))
