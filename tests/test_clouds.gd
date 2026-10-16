extends RefCounted
## The cloud scaffold: the constants that are derived at load, and the verdict that decides whether a
## body is worth generating a field for at all.
##
## **All arithmetic, no GPU, and no shader.** What is checked is that the derivation lands where the
## real planets are: Jupiter banded, Earth banded-and-shredded, Venus featureless, and a body whose
## wind speed nobody has looked up coming back `UNKNOWN` rather than being given a plausible answer.
##
## That last one is a check rather than politeness. `SpacesimAtmosphere.wind_speed` is the one input the
## model cannot derive, and the whole point of returning `UNKNOWN` is that a guessed wind would produce
## a *confident* verdict for a body nobody has measured — which is exactly the failure the material
## table's "keep a zero" rule exists to prevent. So it gets an assertion.
##
## The verdicts are order-of-magnitude estimates from published winds and rotations, not measurements of
## our own. What the suite can honestly check is that they land in the right *regime* and that the
## numbers behind them are in the observed order — which is the same form the condensation-level check
## takes, and the same reason it was worth having.

const SOL_PATH := "res://systems/sol.tres"


func run(h, root: Node) -> void:
	print("  clouds")
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	h.check(sol != null, "Sol loads")
	if sol == null:
		return

	var scene := SpacesimSystemScene.from_content(sol)
	h.check(scene != null, "a scene wraps it")
	if scene == null:
		return
	scene.build(root)

	var materials := SpacesimMaterialTable.engine_table()
	var luminosity := SpacesimStarModel.luminosity(scene.star().content)

	_test_the_verdicts(h, scene, materials, luminosity)
	_test_the_rotation_is_the_airs(h, scene)
	_test_the_two_scales(h, scene, materials, luminosity)
	_test_the_favouring_profile(h)
	_test_the_layer_stack(h, scene, materials, luminosity)

	scene.container.free()


## A body's morphology, as the real caller would ask for it.
##
## **Annotated rather than inferred.** An untyped return makes this a `Variant`, and `:=` on a Variant
## is a hard parse error — the same trap that has caught this project five times.
func _of(
	scene: SpacesimSystemScene, id: String, materials: SpacesimMaterialTable, luminosity: float
) -> SpacesimCloudModel.Morphology:
	var body := scene.body_by_id(id)
	var star := scene.star()
	return SpacesimCloudModel.morphology(
		body.content, materials, luminosity, body.position.distance_to(star.position)
	)


## **Three planets, three morphologies, one dimensionless number.**
##
## This is the check the whole scaffold exists for, and it is the same shape as the condensation-level
## result: Earth and Venus land where they do *for reasons the model can be asked about*, not because
## anybody tuned them. Jupiter's 50 m/s mean zonal wind, Earth's 10 m/s eddy velocity and Venus's 100 m/s
## superrotation are the published velocity scales; the rotations are content.
func _test_the_verdicts(h, scene: SpacesimSystemScene, materials: SpacesimMaterialTable, luminosity: float) -> void:
	var jupiter := _of(scene, "planet:jupiter", materials, luminosity)
	var earth := _of(scene, "planet:earth", materials, luminosity)
	var venus := _of(scene, "planet:venus", materials, luminosity)

	h.check(jupiter.banding == SpacesimCloudModel.Banding.BANDED,
		"Jupiter is BANDED — belts and zones, at L_Rh/a = %.3f" % jupiter.ratio)
	h.check(earth.banding == SpacesimCloudModel.Banding.SHREDDED,
		"Earth is SHREDDED — bands the eddies cross and break up, at %.3f" % earth.ratio)
	h.check(venus.banding == SpacesimCloudModel.Banding.FEATURELESS,
		"Venus is FEATURELESS, at %.3f — one cell, nothing to generate" % venus.ratio)

	# The ordering is the claim; the thresholds are a calibration. If the ordering inverted, the
	# calibration would be hiding a wrong derivation.
	h.check(jupiter.ratio < earth.ratio and earth.ratio < venus.ratio,
		"and the three order correctly: %.3f < %.3f < %.3f" % [jupiter.ratio, earth.ratio, venus.ratio])

	# **The check that justifies skipping the work.** A renderer reads the verdict, so FEATURELESS has to
	# mean "do not generate", not "generate something bland".
	h.check(venus.cells < 1.5,
		"and its band scale has reached the planet: %.2f cells per hemisphere" % venus.cells)

	# Jupiter's band scale against the real jet spacing — the order of magnitude, which is all that is
	# being claimed. Observed spacings are in the 3,000-8,000 km range.
	h.check(jupiter.band_scale > 2.0e6 and jupiter.band_scale < 9.0e6,
		"Jupiter's bands come to %.0f km, in the observed order of its jet spacing"
			% (jupiter.band_scale / 1000.0))
	# Earth's cells against the observed three pairs of cells per hemisphere (Hadley, Ferrel, polar).
	h.check(earth.cells > 3.0 and earth.cells < 5.0,
		"and Earth's %0.2f cells per hemisphere against an observed 3-4" % earth.cells)


## **The Venus trap, asserted.** A superrotating atmosphere's rate is not the body's, and the model has
## to say which one it used rather than quietly returning a number.
##
## The rate is out by a factor of 61 — 243 days against a 4-day superrotation — **and the obvious guess
## about the consequence is wrong.** With the body's own rotation Venus's band scale comes to ~31,800 km
## against the ~4,080 the air gives, and its cells to 0.07 against 0.58 — and the verdict is
## `FEATURELESS` either way, because a slowly rotating body has a huge band scale too. So Venus is
## **robust** to this particular error.
##
## It is recorded because it is the opposite of what was expected, and because a check that cannot tell
## two cases apart is not a check: the two verdicts and the two band scales are both asserted below, so
## the difference between them is a measurement rather than an assumption.
func _test_the_rotation_is_the_airs(h, scene: SpacesimSystemScene) -> void:
	var venus_body := scene.body_by_id("planet:venus")
	var venus := SpacesimCloudModel.rotation_of(venus_body.content)
	h.check(venus.source == SpacesimCloudModel.Rotation.Source.AUTHORED,
		"Venus's air is known to superrotate, so content's rate is used")
	h.check(venus.ratio > 55.0 and venus.ratio < 70.0,
		"at %.1f times the planet's own rotation" % venus.ratio)

	var earth := SpacesimCloudModel.rotation_of(scene.body_by_id("planet:earth").content)
	h.check(earth.source == SpacesimCloudModel.Rotation.Source.BODY,
		"Earth's air turns with the body, and that is reported rather than assumed")
	h.check_near(earth.ratio, 1.0, "so its ratio is 1.0 exactly", 1.0e-9)

	# --- what the wrong answer would have been, computed rather than argued ----------------------
	var radius := venus_body.content.radius
	var from_air := SpacesimCloudModel.band_scale(venus.omega, radius, 100.0)
	var from_body := SpacesimCloudModel.band_scale(
		TAU / venus_body.content.rotation_period, radius, 100.0
	)
	h.check(from_body > 0.0 and from_air > 0.0, "both scales are computable")
	h.check(
		SpacesimCloudModel.banding(from_air / radius) == SpacesimCloudModel.Banding.FEATURELESS
			and SpacesimCloudModel.banding(from_body / radius) == SpacesimCloudModel.Banding.FEATURELESS,
		"and the body's own rotation gives FEATURELESS too (%.2f against %.2f) — the verdict is robust "
			% [from_body / radius, from_air / radius]
			+ "to the error, which is not what was expected"
	)
	h.check(from_body > from_air * 4.0,
		"while the band scale is not: %.0f km from the body against %.0f km from the air"
			% [from_body / 1000.0, from_air / 1000.0])
	h.check(SpacesimCloudModel.cell_count(from_body / radius) < SpacesimCloudModel.cell_count(from_air / radius),
		"and a smaller cell count follows — so the field matters for what is drawn even here")


## **A body nobody has a wind speed for gets no verdict.** Not a default, not a plausible guess.
func _test_the_two_scales(h, scene: SpacesimSystemScene, materials: SpacesimMaterialTable, luminosity: float) -> void:
	# Titan has an atmosphere block and no wind speed. Mars likewise.
	var titan := _of(scene, "moon:titan", materials, luminosity)
	h.check(titan.banding == SpacesimCloudModel.Banding.UNKNOWN,
		"a body with no wind speed gets UNKNOWN rather than a verdict")
	h.check_near(titan.ratio, 0.0, "and no ratio", 1.0e-12)
	h.check_near(titan.band_scale, 0.0, "and no band scale", 1.0e-12)
	h.check_near(titan.cells, 0.0, "and no cell count", 1.0e-12)
	h.check_near(SpacesimCloudModel.banding(0.0), SpacesimCloudModel.Banding.UNKNOWN,
		"which is what a zero ratio means, and not BANDED", 1.0e-12)

	# --- the eddy scale, which is the other half and a weaker one --------------------------------
	# `buoyancy_frequency` is the isothermal value standing in for a gap: the profile's lapse IS the dry
	# adiabat, so the model's own N is zero by construction. The check is that it is the right order
	# against Earth's real tropospheric ~0.01, not that it is right.
	var earth := scene.body_by_id("planet:earth")
	var gravity := SpacesimAtmosphereModel.surface_gravity(earth.content)
	var equilibrium := SpacesimAtmosphereModel.equilibrium_temperature(
		earth.content, materials, luminosity, earth.position.distance_to(scene.star().position)
	)
	var temperature := SpacesimAtmosphereModel.reference_temperature(
		earth.content, materials, luminosity, earth.position.distance_to(scene.star().position)
	)
	var air_height := SpacesimAtmosphereModel.scale_height(
		earth.content.atmosphere, materials, temperature, gravity
	)
	var buoyancy := SpacesimCloudModel.buoyancy_frequency(
		earth.content.atmosphere, materials, gravity, temperature
	)
	h.check(buoyancy > 0.010 and buoyancy < 0.030,
		"Earth's N comes to %.4f 1/s against a real tropospheric ~0.01 (the isothermal value, ~2x high)"
			% buoyancy)

	var morphology: SpacesimCloudModel.Morphology = _of(scene, "planet:earth", materials, luminosity)
	h.check(morphology.eddy_scale > 5.0e5 and morphology.eddy_scale < 3.0e6,
		"so its eddies come to %.0f km, against a real deformation radius near 1,000 km"
			% (morphology.eddy_scale / 1000.0))
	# The deformation radius has no meaning at the equator; the function must not divide by zero there.
	h.check_near(SpacesimCloudModel.eddy_scale(air_height, buoyancy, morphology.rotation.omega, 0.0),
		0.0, "and it is zero at the equator rather than infinite", 1.0e-12)


## **Where condensation is favoured, from the circulation cells alone.**
##
## Earth's three cells put rising air at 0 and 60 degrees and sinking air at 30 and 90 — which is the
## ITCZ, the subtropical deserts, the storm track and the polar high, in that order. That is a real
## prediction made by a cosine, and it is why this is worth deriving rather than authoring.
func _test_the_favouring_profile(h) -> void:
	var deg := PI / 180.0
	h.check_near(SpacesimCloudModel.condensation_favouring(0.0, 3.0), 1.0,
		"the equator is the ITCZ: fully favoured", 1.0e-9)
	h.check_near(SpacesimCloudModel.condensation_favouring(30.0 * deg, 3.0), 0.0,
		"30 degrees is the subtropical high: deserts", 1.0e-9)
	h.check_near(SpacesimCloudModel.condensation_favouring(60.0 * deg, 3.0), 1.0,
		"60 degrees is the storm track: favoured again", 1.0e-9)
	h.check_near(SpacesimCloudModel.condensation_favouring(90.0 * deg, 3.0), 0.0,
		"and the pole sinks", 1.0e-9)

	# One cell — a slowly rotating body — has no alternation to offer, so it is uniformly favoured
	# rather than divided into a band that does not exist.
	h.check_near(SpacesimCloudModel.condensation_favouring(45.0 * deg, 0.0), 1.0,
		"a body with no cells has nothing to alternate", 1.0e-9)
	# Bands only get narrower with more cells, never wider: the profile's first minimum moves up.
	var early := SpacesimCloudModel.condensation_favouring(20.0 * deg, 3.0)
	var late := SpacesimCloudModel.condensation_favouring(20.0 * deg, 9.0)
	h.check(late > early,
		"and more cells means a wider rising branch at a given latitude (%.3f against %.3f)"
			% [late, early])


## The deck stack, which is a **selection** from the condensation derivation rather than a second one.
func _test_the_layer_stack(h, scene: SpacesimSystemScene, materials: SpacesimMaterialTable, luminosity: float) -> void:
	var starred := scene.star()
	var earth := scene.body_by_id("planet:earth")
	var gravity := SpacesimAtmosphereModel.surface_gravity(earth.content)
	var equilibrium := SpacesimAtmosphereModel.equilibrium_temperature(
		earth.content, materials, luminosity, earth.position.distance_to(starred.position)
	)
	var levels := SpacesimCloudModel.layers(earth.content.atmosphere, materials, gravity, equilibrium)
	var found := ""
	for level in levels:
		found += String(level.species) + " "
	h.check(found.contains("water_vapour"),
		"Earth's deck stack is its water vapour, at %.0f m (%s)" % [levels[0].height if not levels.is_empty() else 0.0, found.strip_edges()])
	h.check(levels.size() >= 1, "and it is a stack of one or more condensables, not one deck")

	# **An ice giant's honest answer is an empty stack.** Uranus's methane is below its condensation
	# point everywhere (49-57 K against methane's 90.7), so a well-mixed model has no level to put a
	# deck on — its real 1.2 bar methane deck exists because methane is *undersaturated* there, and
	# saturation is not modelled. An empty stack says so; a zero-height deck would pretend.
	var uranus := scene.body_by_id("planet:uranus")
	var uranus_levels := SpacesimCloudModel.layers(
		uranus.content.atmosphere, materials,
		SpacesimAtmosphereModel.surface_gravity(uranus.content),
		SpacesimAtmosphereModel.equilibrium_temperature(
			uranus.content, materials, luminosity, uranus.position.distance_to(starred.position)
		)
	)
	h.check(uranus_levels.is_empty(),
		"while Uranus's methane comes out as a fog and contributes no layer at all")

	# Nothing in the module may hand a shader a NaN or an infinity, whatever it is fed.
	var jupiter_morphology: SpacesimCloudModel.Morphology = _of(scene, "planet:jupiter", materials, luminosity)
	h.check(is_finite(jupiter_morphology.ratio) and is_finite(jupiter_morphology.band_scale)
		and is_finite(jupiter_morphology.eddy_scale) and is_finite(jupiter_morphology.cells),
		"and every number the model produces is finite")
