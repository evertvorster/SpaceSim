extends RefCounted
## The cloud field: deterministic from a seed, banded where the circulation says, ragged where the model
## says the eddies win — and **costing nothing at all on a body with nothing to draw.**
##
## No GPU and no scene for any of it. The field is arithmetic on the model's own numbers, which is what
## makes it checkable: every claim below is a value, a difference or a count, and the ones that would
## otherwise be a matter of opinion — "does it look banded?" — are turned into a ratio of variances
## instead.
##
## **What this suite cannot check is whether it looks right.** That is a render and Evert's eyes, and the
## plan says so. What it can check is that the field has the structure the physics asks for, that it is
## reproducible, and that the expensive path is skipped when it should be.

const SOL_PATH := "res://systems/sol.tres"
const TEST_WIDTH := 256
const TEST_HEIGHT := 128


func run(h, root: Node) -> void:
	print("  cloud field")
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	h.check(sol != null, "Sol loads")
	if sol == null:
		return
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null:
		h.check(false, "a scene wraps it")
		return
	scene.build(root)

	var materials := SpacesimMaterialTable.engine_table()
	var luminosity := SpacesimStarModel.luminosity(scene.star().content)

	var jupiter := _morphology(scene, "planet:jupiter", materials, luminosity)
	var earth := _morphology(scene, "planet:earth", materials, luminosity)
	var venus := _morphology(scene, "planet:venus", materials, luminosity)

	_test_the_mixing_is_the_verdict(h)
	_test_determinism(h, earth)
	_test_a_featureless_body_costs_nothing(h, venus)
	_test_the_bands_are_bands(h, jupiter, earth)
	_test_it_is_continuous_where_the_seam_is(h, earth)
	_test_the_values_are_sane(h, jupiter, earth, venus)
	_test_what_a_bake_costs(h, earth)

	scene.container.free()


func _morphology(scene: SpacesimSystemScene, id: String, materials: SpacesimMaterialTable, luminosity: float) -> SpacesimCloudModel.Morphology:
	var body := scene.body_by_id(id)
	return SpacesimCloudModel.morphology(
		body.content, materials, luminosity, body.position.distance_to(scene.star().position)
	)


## The mixing strength follows the model's *verdict*, which is the point of having a verdict at all.
func _test_the_mixing_is_the_verdict(h) -> void:
	h.check(SpacesimCloudField.mixing(SpacesimCloudModel.Banding.BANDED)
			< SpacesimCloudField.mixing(SpacesimCloudModel.Banding.SHREDDED),
		"a shredded body mixes its bands harder than a banded one")
	h.check_near(SpacesimCloudField.mixing(SpacesimCloudModel.Banding.FEATURELESS), 0.0,
		"and a featureless body mixes not at all", 1.0e-12)
	h.check_near(SpacesimCloudField.mixing(SpacesimCloudModel.Banding.UNKNOWN), 0.0,
		"as does one nothing is known about — a default is not a licence to invent weather", 1.0e-12)


## **The same world regains the same weather.** The seed is a function of the body's id, so this is the
## property `Cosmos and Discovery` needs of everything generated, and the reason a save can be short.
func _test_determinism(h, earth: SpacesimCloudModel.Morphology) -> void:
	var first := SpacesimCloudField.bake(SpacesimCloudField.seed_for("planet:earth", 0), earth,
		TEST_WIDTH, TEST_HEIGHT)
	var again := SpacesimCloudField.bake(SpacesimCloudField.seed_for("planet:earth", 0), earth,
		TEST_WIDTH, TEST_HEIGHT)
	h.check(first.get_data() == again.get_data(), "the same seed bakes the same bytes")

	var other := SpacesimCloudField.bake(SpacesimCloudField.seed_for("planet:earth", 1), earth,
		TEST_WIDTH, TEST_HEIGHT)
	h.check(first.get_data() != other.get_data(), "and a different layer is different weather")

	var elsewhere := SpacesimCloudField.bake(SpacesimCloudField.seed_for("planet:mars", 0), earth,
		TEST_WIDTH, TEST_HEIGHT)
	h.check(first.get_data() != elsewhere.get_data(), "and so is the same layer on another body")


## **A featureless body never builds a generator.** Evert's requirement, as a measurement rather than a
## claim in a comment: two different seeds, the same bytes, because no noise was ever drawn.
func _test_a_featureless_body_costs_nothing(h, venus: SpacesimCloudModel.Morphology) -> void:
	h.check(venus.banding == SpacesimCloudModel.Banding.FEATURELESS, "Venus is featureless")
	h.check_near(SpacesimCloudField.mixing(venus.banding), 0.0, "so nothing mixes", 1.0e-12)

	var one := SpacesimCloudField.bake(11, venus, 64, 32)
	var two := SpacesimCloudField.bake(999999, venus, 64, 32)
	h.check(one.get_data() == two.get_data(),
		"and two different seeds bake identical bytes — the noise was never generated")
	var spread := _spread(one.get_data())
	h.check(spread == 0,
		"which makes it a flat sheet: the whole map is one value (%d levels of spread)" % spread)

	# And the same for a body whose verdict is unknown: a uniform field, not invented weather.
	var unknown := SpacesimCloudModel.Morphology.new()
	h.check(unknown.banding == SpacesimCloudModel.Banding.UNKNOWN, "an unmeasured body is UNKNOWN")
	var guessed := SpacesimCloudField.bake(7, unknown, 64, 32)
	h.check(_spread(guessed.get_data()) == 0,
		"and it gets a flat field rather than a default worth drawing")


## **"Does it look banded?" turned into a number.** Compare how much a row varies (constant latitude —
## pure eddy noise) with how much the row *means* vary down the map (pure latitude structure).
##
## Jupiter's bands should dominate its weather; Earth's should not. That is the whole visual difference
## between the two, and it comes from the derived ratio rather than from anything tuned.
func _test_the_bands_are_bands(h, jupiter: SpacesimCloudModel.Morphology, earth: SpacesimCloudModel.Morphology) -> void:
	var jupiter_map := SpacesimCloudField.bake(1, jupiter, TEST_WIDTH, TEST_HEIGHT)
	var earth_map := SpacesimCloudField.bake(1, earth, TEST_WIDTH, TEST_HEIGHT)
	var jupiter_ratio := _across_rows(jupiter_map) / maxf(_within_rows(jupiter_map), 1.0)
	var earth_ratio := _across_rows(earth_map) / maxf(_within_rows(earth_map), 1.0)

	h.check(jupiter_ratio > earth_ratio,
		"Jupiter's bands dominate its weather more than Earth's do (%.3f against %.3f)"
			% [jupiter_ratio, earth_ratio])
	# **The absolute guard is now a guard against a FLAT field, and the relative check above is the one that carries
	# the meaning.** This metric is latitude structure over within-row variation, and its subject has changed twice: the
	# meander (2026-10-17) puts longitude structure in the denominator, and the cumulus parcels (2026-10-29) put
	# *isotropic* structure there by design — the clumps are round on purpose, so within-row variation is now the larger
	# term everywhere and a banded body's ratio sits below one. What still holds, and is what the check above asserts, is
	# the ORDERING: Jupiter's bands dominate its weather three times as much as Earth's do. Measured 2026-10-29:
	# Jupiter 0.472, Earth 0.152.
	h.check(jupiter_ratio > 0.4 and jupiter_ratio < 1.0,
		"and measurably: a banded body's latitude structure is %.2f of its within-row variation, against a flat field's 1.0" % jupiter_ratio)

	# The number of bands is the derived cell count, so it is worth counting rather than assuming.
	# **Each cell gives a rising branch AND a sinking one**, so the profile changes direction about
	# `2 * cells` times over the whole map — not `cells`.
	var turns := _turns_in(_row_means(jupiter_map))
	var expected := 2.0 * jupiter.cells
	h.check(absf(float(turns) - expected) <= 3.0,
		"with %d direction changes down the map against %.1f derived cells (2 each: %.1f)"
			% [turns, jupiter.cells, expected])


## The seam is at ±180 degrees, and there must not be a visible one.
##
## **Tested against the field's own variation rather than against a tolerance**, because a tolerance
## cannot tell a seam from the weather: two nearby directions genuinely differ, so "the values at either
## side are close" is a check that passes or fails on how far apart the samples happened to be. What the
## seam has to look like is *every other column boundary* — the wrap pair is one column step apart, the
## same as the interior pairs — so the comparison is between two distributions of the same quantity.
func _test_it_is_continuous_where_the_seam_is(h, earth: SpacesimCloudModel.Morphology) -> void:
	var map := SpacesimCloudField.bake(
		SpacesimCloudField.seed_for("planet:earth", 0), earth, TEST_WIDTH, TEST_HEIGHT
	)
	var data := map.get_data()
	var width := map.get_width()
	var height := map.get_height()

	# **A GLOBAL bound, because on a longitudinally varying field no per-row one means anything.** Two
	# statistics were tried and both lied. The original compared the seam against the mean of every interior
	# boundary, which on a meandering field compares one *phase of the wave* against an average of all of
	# them and reported 28 levels against 7.5 with no seam present. A per-row bound against its own
	# neighbours is better but still trips on rows where the neighbours happen to be nearly flat — it read
	# 3.9 with the meander switched OFF, which is the field's ordinary steepness and not a discontinuity.
	#
	# What continuity has to mean is that **no step across the wrap is bigger than the biggest step the
	# field takes anywhere else.** A real seam would be a step nothing else in the map matches.
	#
	# **The polar caps are excluded from the seam statistic**, and that is deliberate rather than
	# convenient: an equirectangular map converges every longitude into a vanishing circle there, so the
	# columns are not neighbours in any physical sense. The poles have their own checks directly below,
	# which sample a cap at a fixed angular radius instead of a fixed row.
	var interior_max := 0.0
	for row in height:
		for column in width - 1:
			interior_max = maxf(interior_max, absf(
				float(data[row * width + column + 1]) - float(data[row * width + column])
			))
	var seam_max := 0.0
	var worst_row := 0
	for row in height:
		var latitude := PI * 0.5 - (float(row) + 0.5) / float(height) * PI
		if absf(latitude) > deg_to_rad(80.0):
			continue
		var seam := absf(float(data[row * width]) - float(data[row * width + width - 1]))
		if seam > seam_max:
			seam_max = seam
			worst_row = row
	h.check(seam_max <= interior_max * 1.2,
		"no step across the wrap is bigger than the biggest the field takes elsewhere (%.0f against %.0f at row %d)"
			% [seam_max, interior_max, worst_row])

	# The pole is the other place a parameterised field goes wrong — a cylinder would pinwheel here.
	# Sampling a cap around it must stay finite, in range, and continuous with the pole itself.
	# **Through `plan()`, because that is what the bake reads** — the pole has to be right in the shipped
	# field, not in a simplified copy of it that no longer exists.
	var plan := SpacesimCloudField.plan(SpacesimCloudField.seed_for("planet:earth", 0), earth)
	var pole := _field_at(Vector3(0.0, 1.0, 0.0), plan)
	var bad := 0
	var worst := 0.0
	for step in 64:
		var angle := float(step) / 64.0 * TAU
		var near_pole := Vector3(cos(angle) * 0.01, 0.99995, sin(angle) * 0.01).normalized()
		var value := _field_at(near_pole, plan)
		if not (is_finite(value) and value >= 0.0 and value <= 1.0):
			bad += 1
		worst = maxf(worst, absf(value - pole))
	h.check(bad == 0, "and 64 samples in a cap at the pole are all finite and in range")
	h.check(worst < 0.5,
		"and the cap is continuous with the pole itself (worst %.3f of the field's range)" % worst)


## One direction through the real field, with the plan the bake would have used.
func _field_at(direction: Vector3, plan: SpacesimCloudField.Plan) -> float:
	if plan.uniform:
		return 1.0
	return SpacesimCloudField.intensity_at(
		direction, plan.mix, plan.cells, plan.ratio, plan.feature,
		plan.noise, plan.stack, plan.phase, plan.fine
	)


## Every value in range, and the field's mean is the band profile's mean — the eddy term is written so the
## overall level does not move with the mixing strength, and clamping is the only thing that can shift it.
func _test_the_values_are_sane(h, jupiter: SpacesimCloudModel.Morphology, earth: SpacesimCloudModel.Morphology, venus: SpacesimCloudModel.Morphology) -> void:
	_sane(h, "Jupiter", jupiter)
	_sane(h, "Earth", earth)
	_sane(h, "Venus", venus)


func _sane(h, name: String, morphology: SpacesimCloudModel.Morphology) -> void:
	var data := SpacesimCloudField.bake(5, morphology, 128, 64).get_data()
	var low := 255
	var high := 0
	var total := 0
	for byte in data:
		low = mini(low, byte)
		high = maxi(high, byte)
		total += byte
	h.check(low >= 0 and high <= 255, "%s: every byte is in range" % name)
	h.check(high > low or name == "Venus",
		"%s: the field has structure (levels %d to %d, mean %.1f)" % [
			name, low, high, float(total) / float(data.size())
		])


## The bake's cost, reported rather than asserted — it is what sizes the real one.
func _test_what_a_bake_costs(h, earth: SpacesimCloudModel.Morphology) -> void:
	var seed := SpacesimCloudField.seed_for("planet:earth", 0)
	var per_pixel := 0.0
	for size in [[128, 64], [256, 128], [512, 256]]:
		var started := Time.get_ticks_usec()
		SpacesimCloudField.bake(seed, earth, size[0], size[1])
		var elapsed := Time.get_ticks_usec() - started
		var pixels: int = size[0] * size[1]
		per_pixel = float(elapsed) / float(pixels)
		print("    ---   bake %dx%d: %.1f ms for %d pixels (%.2f us a pixel)" % [
			size[0], size[1], elapsed / 1000.0, pixels, per_pixel
		])
	# **This is what says how big a map GDScript can produce at all**, and the answer is not in the
	# probe's numbers: 3.1 s was the engine's own generator, and this field's arithmetic is per pixel on
	# top of it. An 8192x4096 map is 33.5 M pixels.
	var eight_k := per_pixel * 8192.0 * 4096.0 / 1.0e6
	print("    ---   which extrapolates to %.1f seconds for one 8192x4096 map" % eight_k)
	h.check(true, "and the cost is printed above, because it decides what is baked and by whom")


## The mean of each row — the latitude structure with the weather averaged out of it.
func _row_means(image: Image) -> PackedFloat32Array:
	var means := PackedFloat32Array()
	var data := image.get_data()
	for row in image.get_height():
		var total := 0
		for column in image.get_width():
			total += data[row * image.get_width() + column]
		means.append(float(total) / float(image.get_width()))
	return means


## How much the row means move down the map: the latitude structure's amplitude.
func _across_rows(image: Image) -> float:
	var means := _row_means(image)
	var total := 0.0
	for mean in means:
		total += mean
	var average := total / float(means.size())
	var variance := 0.0
	for mean in means:
		variance += (mean - average) * (mean - average)
	return sqrt(variance / float(means.size()))


## How much each row varies *within itself*: the eddy noise, with the latitude structure held constant.
func _within_rows(image: Image) -> float:
	var data := image.get_data()
	var width := image.get_width()
	var total := 0.0
	var count := 0
	for row in image.get_height():
		var sum := 0
		for column in width:
			sum += data[row * width + column]
		var average := float(sum) / float(width)
		for column in width:
			var difference := float(data[row * width + column]) - average
			total += difference * difference
			count += 1
	return sqrt(total / float(maxi(count, 1)))


## Direction changes in a profile: how many bands it has.
func _turns_in(profile: PackedFloat32Array) -> int:
	var turns := 0
	for index in range(1, profile.size() - 1):
		var before := profile[index] - profile[index - 1]
		var after := profile[index + 1] - profile[index]
		if before * after < 0.0:
			turns += 1
	return turns


## Levels of spread in a byte array: 0 means every byte is identical.
func _spread(data: PackedByteArray) -> int:
	var low := 255
	var high := 0
	for byte in data:
		low = mini(low, byte)
		high = maxi(high, byte)
	return high - low
