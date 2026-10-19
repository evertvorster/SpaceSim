extends RefCounted
## The baked surface maps' arithmetic: the size law, the percentile table, and the colour ramp built from it.
##
## **Nothing here bakes.** A bake needs a rendering device, and the GLSL is the only implementation of the
## field, so what this file can check headlessly is what a map is *for*: the width the distance law asks for,
## the quantiles measured off a map's own distribution, and the ramp that turns a band's area fraction into a
## colour at a height. Those three are where a derivation and a picture meet, and they are all pure.


func run(h, _root: Node) -> void:
	print("  surface maps")
	_test_width_law(h)
	_test_quantiles(h)
	_test_the_ramp(h)


## **The width worth baking at a distance**, from the law the cloud maps measured and this class clamps.
func _test_width_law(h) -> void:
	var radius := 6.371e6
	var pixel := 1.297e-3
	# Far away, the floor: a map that is 1,024 wide is what a body needs to show continents at all.
	h.check(SpacesimSurfaceMaps.required_width(radius, 1.0e12, pixel) == SpacesimSurfaceMaps.FLOOR_WIDTH,
		"a distant body asks for the floor width")
	# Close in, the ceiling — 4,096 rather than the cloud field's 8,192, because the surface bake is a
	# one-off on the frame's thread and the detail below it is the ladder's job.
	var close := SpacesimSurfaceMaps.required_width(radius, radius + 1.0e5, pixel)
	h.check(close == SpacesimSurfaceMaps.MAX_WIDTH,
		"a close body asks for the ceiling and no more (%d)" % close)
	# Monotone in distance: closing in never asks for less.
	var previous := 0
	var monotone := true
	for exponent in [10, 9, 8, 7, 6]:
		var width := SpacesimSurfaceMaps.required_width(radius, radius * pow(10.0, exponent - 6), pixel)
		if width < previous:
			monotone = false
		previous = width
	h.check(monotone, "and closing in never asks for a coarser map")
	# Degenerate inputs are the floor rather than a division by zero.
	h.check(SpacesimSurfaceMaps.required_width(0.0, 1.0e8, pixel) >= SpacesimSurfaceMaps.FLOOR_WIDTH,
		"a body with no radius still gets a map")


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
