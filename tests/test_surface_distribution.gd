extends RefCounted
## **The field's measured DISTRIBUTION** — the one thing about the ground that is still a sample rather than a formula.
##
## The ground draws `surface_height` at every pixel, so there is no map, no ladder and no tile to test. What survives
## is the *measurement*: a body's percentile table, which turns an authored **area fraction** ("oceans are 70.8 % of
## it") into the **height** a shader needs, and which is the only way to know a formula's own distribution.
##
## **Nothing here bakes.** A bake needs a rendering device and the GLSL is the only implementation of the field, so
## what can be checked headlessly is the arithmetic the measurement is reduced to — the histogram, the quantile walk
## and the interpolator every band edge goes through. Those are pure, and they are where a derivation and a picture
## meet.


func run(h, _root: Node) -> void:
	print("  surface distribution")
	_test_the_quantile_table(h)
	_test_the_histogram(h)
	_test_the_ramp(h)


## **The table is the interface, and it is 65 numbers.** A band edge between two of them is a lerp rather than an
## assumption, and the count is also what the host publishes as a `PackedFloat32Array`.
func _test_the_quantile_table(h) -> void:
	h.check(SpacesimSurfaceDistribution.QUANTILES == 65, "the table has 65 entries")
	var linear := SpacesimSurfaceDistribution.linear_quantiles()
	h.check(linear.size() == SpacesimSurfaceDistribution.QUANTILES, "and `linear_quantiles` fills them")
	h.check_near(linear[0], -1.0, "a linear placeholder starts at -1", 1.0e-6)
	h.check_near(linear[linear.size() - 1], 1.0, "and ends at 1", 1.0e-6)
	# **A placeholder, not a measurement** — it is what a material is built with before the bake lands, so a monotone
	# replacement is all it must be.
	var monotone := true
	for index in range(1, linear.size()):
		if linear[index] < linear[index - 1]:
			monotone = false
	h.check(monotone, "and never goes backwards")


func _test_the_histogram(h) -> void:
	var image := Image.create_empty(256, 1, false, Image.FORMAT_RH)
	for column in 256:
		var value := lerpf(-1.0, 1.0, float(column) / 255.0)
		image.set_pixel(column, 0, Color(value, 0.0, 0.0, 1.0))
	var table := SpacesimSurfaceDistribution.quantiles_of(image)
	h.check(table.size() == SpacesimSurfaceDistribution.QUANTILES,
		"the table has %d entries" % SpacesimSurfaceDistribution.QUANTILES)

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
	h.check_near(SpacesimSurfaceDistribution.value_at(table, 0.708), 0.416,
		"70.8 %% of a uniform field lies below %.3f" % SpacesimSurfaceDistribution.value_at(table, 0.708), 0.02)
	# Clamped at both ends rather than extrapolated.
	h.check_near(SpacesimSurfaceDistribution.value_at(table, -1.0), table[0], "a share below zero clamps", 1.0e-9)
	h.check_near(SpacesimSurfaceDistribution.value_at(table, 2.0), table[table.size() - 1],
		"and one above one clamps", 1.0e-9)
	h.check_near(SpacesimSurfaceDistribution.value_at(PackedFloat32Array(), 0.5), 0.0,
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
	var skewed_table := SpacesimSurfaceDistribution.quantiles_of(skewed)
	h.check_near(skewed_table[0], -0.6, "an asymmetric field's lowest quantile is its own minimum", 0.01)
	h.check_near(skewed_table[skewed_table.size() - 1], 1.0,
		"and its highest is its own maximum", 0.01)
	h.check_near(SpacesimSurfaceDistribution.value_at(skewed_table, 0.5), 0.2,
		"a distribution from -0.6 to 1.0 has its median at 0.2", 0.02)
	# **The invariant the picture rests on**: the value at an ocean fraction puts that fraction below it.
	var fractions := [0.25, 0.5, 0.708, 0.9]
	for share in fractions:
		var level := SpacesimSurfaceDistribution.value_at(skewed_table, share)
		var below := 0
		for column in 256:
			if skewed.get_pixel(column, 0).r < level:
				below += 1
		h.check_near(float(below) / 256.0, share,
			"%.1f %% of the field lies below value_at(%.3f)" % [share * 100.0, share], 0.02)

	# The placeholder a material is built with, before any map exists.
	var linear := SpacesimSurfaceDistribution.linear_quantiles()
	h.check_near(linear[0], -1.0, "the linear placeholder starts at the field's floor", 1.0e-6)
	h.check_near(linear[linear.size() - 1], 1.0, "and ends at its ceiling", 1.0e-6)


## **The colour ramp**: bands in area fractions, texels in field values.
func _test_the_ramp(h) -> void:
	var bands := [
		{"material": "ocean", "from": 0.0, "to": 0.708, "color": Color(0.02, 0.06, 0.15, 1.0)},
		{"material": "regolith", "from": 0.708, "to": 1.0, "color": Color(0.4, 0.36, 0.3, 1.0)},
	]
	var quantiles := SpacesimSurfaceDistribution.linear_quantiles()
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
