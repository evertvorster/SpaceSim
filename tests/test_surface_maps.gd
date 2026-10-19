extends RefCounted
## The baked surface maps' arithmetic: the size law, the percentile table, and the colour ramp built from it.
##
## **Nothing here bakes.** A bake needs a rendering device, and the GLSL is the only implementation of the
## field, so what this file can check headlessly is what a map is *for*: the width the distance law asks for,
## the quantiles measured off a map's own distribution, and the ramp that turns a band's area fraction into a
## colour at a height. Those three are where a derivation and a picture meet, and they are all pure.


func run(h, _root: Node) -> void:
	print("  surface maps")
	_test_no_bake_on_lookup(h)
	_test_the_ladder(h)
	_test_quantiles(h)
	_test_the_ramp(h)


## **The ladder: a floor, a ceiling derived from the display, and one rung at a time.**
##
## Everything here is arithmetic, which is the point — the ceiling and the ascent are what decide the cost of a
## planet at close range, and neither needs a rendering device to be checked. The numbers are Evert's: **the
## ceiling is half the resolution the scene is being rendered at**, rounded to a power of two, and it is a
## tunable so the cost can be watched while it moves.
func _test_the_ladder(h) -> void:
	h.check(SpacesimSurfaceMaps.BUILD_WIDTH == 256,
		"a body is baked at 256 when the scene is built, not at its ceiling")

	# **Half the render width, and always derived**: 0.5 of 1,280 is 640, of 1,920 is 960, of 3,840 is 1,920.
	h.check(SpacesimSurfaceMaps.base_max_width(Vector2i(1280, 720)) == 640,
		"the 720p default ceiling is 640 — half of 1,280")
	h.check(SpacesimSurfaceMaps.base_max_width(Vector2i(1920, 1080)) == 960,
		"1080p gives 960 — half the render width, not the window's")
	h.check(SpacesimSurfaceMaps.base_max_width(Vector2i(3840, 2160)) == 1920, "4K gives 1,920")
	h.check(SpacesimSurfaceMaps.base_max_width(Vector2i(0, 0)) == SpacesimSurfaceMaps.MIN_WIDTH,
		"no render size falls back to the narrowest map rather than to zero")

	# The knob is a fraction of the render resolution, so moving it moves the ceiling in proportion — and it is
	# clamped at both ends, because a number moved while flying must not be able to ask for nonsense.
	h.check(SpacesimSurfaceMaps.base_max_width(Vector2i(1920, 1080), 1.0) == 1920,
		"surface.max_base_fraction 1.0 is the render width itself")
	h.check(SpacesimSurfaceMaps.base_max_width(Vector2i(1920, 1080), 0.25) == 480,
		"and 0.25 is a quarter of it")
	h.check(SpacesimSurfaceMaps.base_max_width(Vector2i(1920, 1080), 2.0) == 3840,
		"above 1.0 is allowed, because it is how the headroom gets measured")
	h.check(SpacesimSurfaceMaps.base_max_width(Vector2i(1920, 1080), 99.0) == SpacesimSurfaceMaps.MAX_WIDTH,
		"an absurd fraction is clamped to the hard ceiling")
	h.check(SpacesimSurfaceMaps.base_max_width(Vector2i(1920, 1080), 0.0) == SpacesimSurfaceMaps.MIN_WIDTH,
		"and a zero fraction to the narrowest map rather than to nothing")

	# The distance law, against the ceiling: far away it asks for the floor it already has, close in for the
	# ceiling, and never for less than a map exists.
	var earth := 6.371e6
	var pixel := 1.2966806e-3
	var far := SpacesimSurfaceMaps.required_width(earth, 1.0e11, pixel, 1024)
	var near := SpacesimSurfaceMaps.required_width(earth, earth + 1000.0, pixel, 1024)
	h.check(far == SpacesimSurfaceMaps.BUILD_WIDTH,
		"a body at 1e11 m asks for the floor (%d)" % far)
	h.check(near == 1024, "and a body a kilometre up asks for the ceiling (%d)" % near)
	h.check(SpacesimSurfaceMaps.required_width(earth, earth + 1000.0, pixel, 256) == 256,
		"a ceiling below the floor is the floor")
	h.check(far <= near, "closing never asks for a coarser map")

	# The ascent: double, and never past what the law wants.
	h.check(SpacesimSurfaceMaps.next_bake_width(256, 1024) == 512,
		"one rung up from 256 is 512, not 1,024 — the ladder is climbed, not jumped")
	h.check(SpacesimSurfaceMaps.next_bake_width(512, 1024) == 1024, "and from 512 it is 1,024")
	h.check(SpacesimSurfaceMaps.next_bake_width(1024, 1024) == 1024,
		"a map that is already fine enough is asked for nothing")
	h.check(SpacesimSurfaceMaps.next_bake_width(256, 384) == 384,
		"and a request never overshoots what the law wants")
	h.check(SpacesimSurfaceMaps.next_bake_width(0, 512) == 512,
		"a body with no map yet starts at the floor")


## **A body that was never prepared has no map, and says so** — and nothing bakes inside a frame. A cache that
## bakes on lookup is what exhausted the engine's RID pools in flight; here that is not a policy, it is the
## shape of the API: `map()` is a lookup and `prepare()` is called once, from the scene's build.
func _test_no_bake_on_lookup(h) -> void:
	var maps := SpacesimSurfaceMaps.new()
	var entry := maps.map("planet:earth")
	h.check(entry == null, "looking a body up does not bake it one")
	h.check(maps.bakes() == 0, "and no bake has run")
	h.check(not SpacesimSurfaceMaps.linear_quantiles().is_empty(),
		"the linear placeholder a material starts with is there when a bake cannot run")


## **The percentile table**, measured off the map's own distribution.
##
## The synthetic map is a linear ramp across its width, so the table's entries are known exactly: the value at
## the Nth percentile of a uniform ramp is `-1 + 2*share`. What this catches is the counting — an off-by-one
## bin, a table that is not monotone, or a resolution too coarse to place a sea level.
func _test_quantiles(h) -> void:
	var image := Image.create_empty(256, 1, false, Image.FORMAT_RH)
	for column in 256:
		var value := lerpf(-1.0, 1.0, float(column) / 255.0)
		image.set_pixel(column, 0, Color(value, 0.0, 0.0, 1.0))
	var table := SpacesimSurfaceMaps.quantiles_of(image)
	h.check(table.size() == SpacesimSurfaceMaps.QUANTILES,
		"the table has %d entries" % SpacesimSurfaceMaps.QUANTILES)

	var worst := 0.0
	var monotone := true
	for index in table.size():
		var expected := lerpf(-1.0, 1.0, float(index) / float(table.size() - 1))
		worst = maxf(worst, absf(table[index] - expected))
		if index > 0 and table[index] < table[index - 1]:
			monotone = false
	h.check(monotone, "and it ascends, so a percentile is a value and not a guess")
	# The tolerance is the histogram's own resolution: a 0.1 % bin over the ±1 range, plus the read back
	# through a half float.
	h.check(worst < 0.01, "a linear field's quantiles are the ramp itself (worst %.4f off)" % worst)

	# **The sea level for an ocean fraction**, which is what a coastline is made of: 70.8 % under water on a
	# uniform field is the 70.8th percentile, i.e. a value near 0.416.
	h.check_near(SpacesimSurfaceMaps.value_at(table, 0.708), 0.416,
		"70.8 %% of a uniform field lies below %.3f" % SpacesimSurfaceMaps.value_at(table, 0.708), 0.02)
	# Clamped at both ends rather than extrapolated.
	h.check_near(SpacesimSurfaceMaps.value_at(table, -1.0), table[0], "a share below zero clamps", 1.0e-9)
	h.check_near(SpacesimSurfaceMaps.value_at(table, 2.0), table[table.size() - 1],
		"and one above one clamps", 1.0e-9)
	h.check_near(SpacesimSurfaceMaps.value_at(PackedFloat32Array(), 0.5), 0.0,
		"an empty table answers the datum rather than a NaN", 1.0e-9)

	# **The trap this test was written into, and out of.** A linear ramp over exactly `-1 .. 1` cannot tell
	# the binning's convention from the reconstruction's, because there the fixed range and the observed range
	# coincide — and the version that reconstructed from the *observed* min and max was wrong for two days,
	# putting Earth's sea level at the 95th percentile and drawing a featureless blue ball. So: an
	# **asymmetric** field, and the invariant stated as behaviour rather than as arithmetic.
	var skewed := Image.create_empty(256, 1, false, Image.FORMAT_RH)
	for column in 256:
		var value := lerpf(-0.6, 1.0, float(column) / 255.0)
		skewed.set_pixel(column, 0, Color(value, 0.0, 0.0, 1.0))
	var skewed_table := SpacesimSurfaceMaps.quantiles_of(skewed)
	h.check_near(skewed_table[0], -0.6, "an asymmetric field's lowest quantile is its own minimum", 0.01)
	h.check_near(skewed_table[skewed_table.size() - 1], 1.0,
		"and its highest is its own maximum", 0.01)
	h.check_near(SpacesimSurfaceMaps.value_at(skewed_table, 0.5), 0.2,
		"a distribution from -0.6 to 1.0 has its median at 0.2", 0.02)
	# **The invariant the picture rests on**: the value at an ocean fraction puts that fraction below it.
	var fractions := [0.25, 0.5, 0.708, 0.9]
	for share in fractions:
		var level := SpacesimSurfaceMaps.value_at(skewed_table, share)
		var below := 0
		for column in 256:
			if skewed.get_pixel(column, 0).r < level:
				below += 1
		h.check_near(float(below) / 256.0, share,
			"%.1f %% of the field lies below value_at(%.3f)" % [share * 100.0, share], 0.02)

	# The placeholder a material is built with, before any map exists.
	var linear := SpacesimSurfaceMaps.linear_quantiles()
	h.check_near(linear[0], -1.0, "the linear placeholder starts at the field's floor", 1.0e-6)
	h.check_near(linear[linear.size() - 1], 1.0, "and ends at its ceiling", 1.0e-6)


## **The colour ramp**: bands in area fractions, texels in field values.
func _test_the_ramp(h) -> void:
	var bands := [
		{"material": "ocean", "from": 0.0, "to": 0.708, "color": Color(0.02, 0.06, 0.15, 1.0)},
		{"material": "regolith", "from": 0.708, "to": 1.0, "color": Color(0.4, 0.36, 0.3, 1.0)},
	]
	var quantiles := SpacesimSurfaceMaps.linear_quantiles()
	var image := SpacesimBodyRenderer.ramp_image(bands, quantiles, Color.BLACK)
	var width := SpacesimBodyRenderer.RAMP_WIDTH
	h.check(image.get_width() == width and image.get_height() == 1,
		"the ramp is one row of %d texels" % width)

	# **The sea band ends where its area fraction says**, through the measured distribution: 0.708 of a linear
	# field is the value 0.416, which is (0.416 + 1) / 2 of the way along the ramp.
	var sea_edge := int(round((0.416 + 1.0) * 0.5 * float(width - 1)))
	h.check(image.get_pixel(sea_edge - 20, 0).is_equal_approx(Color(0.02, 0.06, 0.15, 1.0))
			or image.get_pixel(sea_edge - 20, 0).b > image.get_pixel(sea_edge - 20, 0).r,
		"below the sea edge the ramp is the ocean band's colour")
	h.check(image.get_pixel(sea_edge + 20, 0).r > image.get_pixel(sea_edge + 20, 0).b,
		"and above it the land band's — brown rather than blue")
	# The ends, which a clamped sampler relies on being flat.
	h.check(image.get_pixel(0, 0).b > image.get_pixel(0, 0).r, "the very bottom of the ramp is ocean")
	h.check(image.get_pixel(width - 1, 0).r > image.get_pixel(width - 1, 0).b,
		"and the very top is land")

	# **A body with no bands keeps its own colour**, which is a gas giant whose visible surface is its deck.
	# **`RGBA8` is 8 bits**, so a colour round-trips to within a level rather than exactly.
	var flat := SpacesimBodyRenderer.ramp_image([], quantiles, Color(0.5, 0.4, 0.3, 1.0))
	var tolerance := 2.0 / 255.0
	var bottom := flat.get_pixel(0, 0)
	var top := flat.get_pixel(width - 1, 0)
	h.check(absf(bottom.r - 0.5) < tolerance and absf(bottom.b - 0.3) < tolerance
			and absf(top.r - 0.5) < tolerance and absf(top.b - 0.3) < tolerance,
		"a body with no bands is filled with the colour it was drawn in before (%.3f, %.3f)"
			% [bottom.r, bottom.b])
