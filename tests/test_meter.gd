extends RefCounted
## The frame metre's arithmetic — Track B2 of [[SpaceSim/Lighting Plan]] §7.
##
## **Three behaviours, none of which needs a GPU**, which is the only part of Track B that can be proved
## headlessly: the weighting is selective, the cap bounds one pixel's influence, and the window bounds
## the result.
##
## **The first two are the requirement itself** (Evert, 2026-10-15: *"a full screen meter, centre
## weighted... if that same object is only a small part of the perimeter, it should only contribute a
## little"*), so they are asserted as a **comparison between frames that differ only in where the bright
## thing is**. A metre that passed without that comparison would pass with no weighting at all — which is
## exactly the metre Godot ships and the reason metered exposure failed here once already.

const Meter := preload("res://addons/spacesim/lighting/exposure_meter.gd")

const GRID := 64
const FLOOR_LEVEL := 0.02 ## What an "empty" frame is made of, in the scene's absolute currency
const BRIGHT := 1.0
const BLOCK := 8 ## An 8x8 block is 1.6% of a 64x64 frame — "a small part of the frame"


func run(h, root: Node) -> void:
	print("  meter")
	_test_weight_profile(h)
	_test_luminance(h)
	_test_centre_beats_perimeter(h)
	_test_cap(h)
	_test_window(h)
	_test_degenerate(h)


## The metre's luminance. **This is the source of truth for an expression that also appears in
## `SpacesimExposurePass`'s sampling shader** (a compute shader cannot call GDScript), so the coefficients
## are pinned here and any change has to be mirrored there deliberately rather than by accident.
func _test_luminance(h) -> void:
	h.check_near(Meter.luminance(Color.WHITE), 1.0, "white is luminance 1", 1e-12)
	h.check_near(Meter.luminance(Color(0.5, 0.5, 0.5)), 0.5, "and it is linear in a grey", 1e-12)
	# Rec.709's ordering, which is the reason to prefer it over a plain channel mean: the eye is mostly
	# green, and a blue sky that measures as bright as a white one is what Godot's max() gets wrong.
	h.check(
		Meter.luminance(Color(0.0, 1.0, 0.0)) > Meter.luminance(Color(1.0, 0.0, 0.0))
			and Meter.luminance(Color(1.0, 0.0, 0.0)) > Meter.luminance(Color(0.0, 0.0, 1.0)),
		"green outweighs red outweighs blue at equal strength"
	)
	h.check(
		Meter.luminance(Color(1.0, 0.0, 0.0)) < 0.25,
		"and a saturated red is a fifth of a white one, not equal to it (%s)"
			% Meter.luminance(Color(1.0, 0.0, 0.0))
	)


## The profile on its own: monotonic in the radius, 1 at the centre, and the documented value at 0.4.
func _test_weight_profile(h) -> void:
	h.check_near(Meter.weight(Vector2.ZERO), 1.0, "the centre carries full weight", 1e-12)
	h.check_near(
		Meter.weight(Vector2(0.4, 0.0)), exp(-1.0), "at 0.4 of the half-diagonal, 1/e", 1e-12
	)
	h.check_near(
		Meter.weight(Vector2(1.0, 0.0)), exp(-1.0 / (Meter.SIGMA * Meter.SIGMA)),
		"a corner carries exp(-1/SIGMA^2)", 1e-12
	)
	var last := 2.0
	var monotonic := true
	for step in 20:
		var r := float(step) / 19.0
		var w: float = Meter.weight(Vector2(r, 0.0))
		if w > last:
			monotonic = false
		last = w
	h.check(monotonic, "and it never rises with radius, so nothing outside the centre can win")
	h.check(
		Meter.weight(Vector2(0.4, 0.0)) > Meter.weight(Vector2(0.8, 0.0)) * 20.0,
		"the fall is steep enough to be selective: 0.4 outweighs 0.8 by more than 20x"
	)


## **The requirement, as a comparison.** Two frames identical except for where the bright block sits.
func _test_centre_beats_perimeter(h) -> void:
	var empty := _frame(0, 99) ## nothing bright anywhere
	var centred := _frame(GRID / 2 - BLOCK / 2, GRID / 2 - BLOCK / 2)
	var corner := _frame(0, 0)

	var mean_empty: float = Meter.weighted_mean(empty, GRID, GRID)
	var mean_centred: float = Meter.weighted_mean(centred, GRID, GRID)
	var mean_corner: float = Meter.weighted_mean(corner, GRID, GRID)

	h.check(
		mean_centred > mean_empty * 3.0,
		"a bright block at the CENTRE lifts the metre's mean well above an empty frame (%.4f vs %.4f)"
		% [mean_centred, mean_empty]
	)
	h.check(
		mean_corner < mean_empty * 1.2,
		"the same block in the CORNER barely moves it (%.4f vs %.4f)" % [mean_corner, mean_empty]
	)
	h.check(
		mean_centred > mean_corner * 3.0,
		"so the centre outweighs the perimeter by a wide margin (%.4f vs %.4f)"
		% [mean_centred, mean_corner]
	)

	# ... and the consequence, which is the thing Evert described: pointing at the bright thing DIMS.
	var m_empty := Meter.target_multiplier(mean_empty)
	var m_centred := Meter.target_multiplier(mean_centred)
	var m_corner := Meter.target_multiplier(mean_corner)
	h.check(
		m_centred < m_empty,
		"pointing at the bright block stops the exposure down (x%.3f against x%.3f)"
		% [m_centred, m_empty]
	)
	h.check(
		m_corner > m_centred * 3.0,
		"and the same block at the periphery leaves the exposure nearly alone (x%.3f)" % m_corner
	)


## **The cap**, which is what stops one source from owning the average.
func _test_cap(h) -> void:
	var star := _frame(GRID / 2 - BLOCK / 2, GRID / 2 - BLOCK / 2, 1.0e6)
	var white := _frame(GRID / 2 - BLOCK / 2, GRID / 2 - BLOCK / 2, Meter.CAP)
	h.check_near(
		Meter.weighted_mean(star, GRID, GRID), Meter.weighted_mean(white, GRID, GRID),
		"a 1e6 source counts exactly as one at the cap, so it cannot own the average", 1e-9
	)
	var all_bright := PackedFloat32Array()
	all_bright.resize(GRID * GRID)
	all_bright.fill(1.0e6)
	h.check_near(
		Meter.weighted_mean(all_bright, GRID, GRID), Meter.CAP,
		"and a frame of nothing but sources reads as the cap, not as 1e6", 1e-9
	)
	# A negative sample cannot drag the mean down — a NaN or a negative light exists in this engine.
	var negative := PackedFloat32Array([-5.0])
	h.check_near(
		Meter.weighted_mean(negative, 1, 1), 0.0, "a negative sample clamps to zero", 1e-12
	)


## **The window.** The bounds are `SpacesimExposure`'s, and they are the reason nothing can run away.
func _test_window(h) -> void:
	h.check_near(
		Meter.target_multiplier(Meter.TARGET_AVERAGE), 1.0,
		"a frame already at middle grey wants no correction", 1e-9
	)
	h.check_near(
		Meter.target_multiplier(0.0), SpacesimExposure.MAX_MULTIPLIER,
		"an empty frame pins at the boost ceiling rather than dividing by zero", 1e-9
	)
	h.check_near(
		Meter.target_multiplier(1.0e-30), SpacesimExposure.MAX_MULTIPLIER,
		"and so does one that is merely almost empty", 1e-9
	)
	h.check_near(
		Meter.target_multiplier(1.0e9), SpacesimExposure.MIN_MULTIPLIER,
		"a blinding frame pins at the light-adapted floor", 1e-9
	)
	var window := SpacesimExposure.MAX_MULTIPLIER / SpacesimExposure.MIN_MULTIPLIER
	h.check_near(
		log(window) / log(2.0), 32.0, "and the window between them is the 32 stops Evert asked for", 1e-6
	)
	var monotonic := true
	var last := 1.0e30
	for step in 40:
		# Four decades of mean, which is most of a solar system.
		var mean := pow(10.0, -6.0 + 6.0 * float(step) / 39.0)
		# A mean of exactly 0 is the pinned case; this sweep is above it.
		var m: float = Meter.target_multiplier(maxf(mean, 1e-30))
		if m > last:
			monotonic = false
		last = m
	h.check(monotonic, "a brighter frame never brightens the exposure, across six decades")


## Nothing here may crash or divide by zero: the caller may hand over anything.
func _test_degenerate(h) -> void:
	var missing := PackedFloat32Array()
	h.check_near(
		Meter.weighted_mean(missing, 0, 0), 0.0, "an empty grid is a mean of zero, not an error", 1e-12
	)
	h.check_near(
		Meter.weighted_mean(missing, 4, 4), 0.0, "a declared size with no samples is zero too", 1e-12
	)
	# A 1x1 grid has no half-diagonal: its single sample IS the centre, and must carry full weight.
	var single := PackedFloat32Array([1.0])
	h.check_near(
		Meter.weighted_mean(single, 1, 1), 1.0, "a 1x1 grid is all centre", 1e-12
	)
	# Fewer samples than the declared size: read what is there rather than running off the end.
	var short := PackedFloat32Array([1.0, 1.0])
	var partial: float = Meter.weighted_mean(short, 8, 8)
	h.check(partial >= 0.0 and is_finite(partial), "a short grid returns a finite number (%.4f)" % partial)


## A `GRID x GRID` frame at `FLOOR_LEVEL`, with a `BLOCK x BLOCK` square of `level` at `(bx, by)`.
func _frame(bx: int, by: int, level: float = BRIGHT) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(GRID * GRID)
	out.fill(FLOOR_LEVEL)
	for y in BLOCK:
		for x in BLOCK:
			var px := bx + x
			var py := by + y
			if px >= 0 and px < GRID and py >= 0 and py < GRID:
				out[py * GRID + px] = level
	return out
