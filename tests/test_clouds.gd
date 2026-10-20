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
	_test_the_deck_thickness(h, scene, materials, luminosity)
	_test_a_cloud_stack_composites(h, scene, materials)
	_test_a_product_needs_its_reactants(h)

	scene.container.free()


## **A stack composites from the bottom up, and the ORDER is what is checked.**
##
## Not a tautology: the expected value is built here by nesting the formula explicitly, so a composite that
## applied the layers top-down instead — letting a deeper deck overwrite the one above it — fails. That is
## the whole failure mode, and with one layer it is invisible, which is why the flat shorthand cannot
## catch it.
func _test_a_cloud_stack_composites(h, scene: SpacesimSystemScene, materials: SpacesimMaterialTable) -> void:
	var earth := scene.body_by_id("planet:earth")
	var body := SpacesimSystemBody.new()
	# Read-only borrow of a real atmosphere, so the clear column is a real number rather than zero.
	body.atmosphere = earth.content.atmosphere
	var clouds := SpacesimClouds.new()
	var top := SpacesimCloudLayer.new()
	top.species = "water_vapour"
	top.coverage = 0.5
	top.albedo = 0.8
	var deep := SpacesimCloudLayer.new()
	deep.species = "water_vapour"
	deep.coverage = 0.5
	deep.albedo = 0.2
	clouds.layers = [top, deep]
	body.clouds = clouds

	var terms := SpacesimSurfaceModel.reflectance_terms(body, materials)
	var clear: float = terms["surface_albedo"] + terms["air_albedo"]
	var expected := 0.5 * 0.8 + 0.5 * (0.5 * 0.2 + 0.5 * clear)
	h.check_near(SpacesimSurfaceModel.bond_albedo(body, materials), expected,
		"a two-layer stack composites deepest-first, so the top deck hides what is under it", 1.0e-9)

	# **The cloud-free fraction is the product of the gaps**, not the top layer's own.
	h.check_near(float(terms["cloud_fraction"]), 0.75,
		"and a disc is cloud-free only where no deck covers it (1 - 0.5*0.5)", 1.0e-9)

	# **The stack's light budget, on a real body.** Jupiter's authored two layers — ammonia at 0.95/0.52
	# and water at 0.75/0.30 — composite to its measured 0.503 Bond albedo, which is the check that the
	# two reflectances were fitted to the composite and not to the top deck alone.
	var jupiter_body := scene.body_by_id("planet:jupiter")
	h.check_near(SpacesimSurfaceModel.bond_albedo(jupiter_body.content, materials), 0.503,
		"and Jupiter's two layers composite to its measured 0.503 Bond albedo", 0.01)

	# The flat shorthand is one layer, and must give exactly the old formula.
	var flat := SpacesimClouds.new()
	flat.fraction = 0.6
	flat.albedo = 0.419
	body.clouds = flat
	var flat_terms := SpacesimSurfaceModel.reflectance_terms(body, materials)
	var flat_clear: float = flat_terms["surface_albedo"] + flat_terms["air_albedo"]
	h.check_near(SpacesimSurfaceModel.bond_albedo(body, materials),
		0.6 * 0.419 + 0.4 * flat_clear,
		"while one flat deck is exactly the one-layer formula, which is what keeps Earth's fit", 1.0e-9)


## **A species that forms in situ needs its reactants present, and no others.** Built from a synthetic
## table on purpose: the real one has no product species yet (that is content, `Cloud Layers` §9), and a
## mechanism that cannot be exercised is a mechanism nobody knows works.
func _test_a_product_needs_its_reactants(h) -> void:
	var table := SpacesimMaterialTable.new()
	for name in ["first", "second"]:
		var gas := SpacesimSpecies.new()
		gas.species_name = name
		gas.molar_mass = 30.0
		gas.heat_capacity = 1000.0
		gas.condensation_temperature = 1.0 # never condenses: it is only a reactant here
		table.species.append(gas)
	var product := SpacesimSpecies.new()
	product.species_name = "product"
	product.molar_mass = 51.0
	product.heat_capacity = 1000.0
	product.condensation_temperature = 250.0
	product.formed_from = PackedStringArray(["first", "second"])
	table.species.append(product)

	var gravity := 9.81
	var atmosphere := SpacesimAtmosphere.new()
	atmosphere.surface_pressure = 101325.0
	atmosphere.species = {"first": 0.8, "second": 0.2}
	var both := SpacesimAtmosphereModel.condensation_levels(atmosphere, table, gravity, 255.0)
	var found := _formation_of(both, "product")
	h.check(found == SpacesimAtmosphereModel.Condensation.Formation.REACTION,
		"a product with both reactants present gives a REACTION level")

	# **One reactant missing and there is no product at all** — the check that it is not simply reading
	# the table.
	atmosphere.species = {"first": 1.0}
	var one := SpacesimAtmosphereModel.condensation_levels(atmosphere, table, gravity, 255.0)
	h.check(_formation_of(one, "product") == -1,
		"and no level at all when one of them is missing")

	# An input is still a CONDENSATION level, not a product: the two paths must not be confused.
	var plain := SpacesimSpecies.new()
	plain.species_name = "plain"
	plain.molar_mass = 30.0
	plain.heat_capacity = 1000.0
	plain.condensation_temperature = 250.0
	table.species.append(plain)
	atmosphere.species = {"plain": 1.0}
	var only_plain := SpacesimAtmosphereModel.condensation_levels(atmosphere, table, gravity, 255.0)
	h.check(_formation_of(only_plain, "plain") == SpacesimAtmosphereModel.Condensation.Formation.CONDENSATION,
		"while a gas in the mix is CONDENSATION")


## The formation of the level for a species, or -1 where there is no level.
func _formation_of(levels: Array, species_name: String) -> int:
	for level in levels:
		var condensation: SpacesimAtmosphereModel.Condensation = level
		if condensation.species == species_name:
			return condensation.formation
	return -1


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
	# **A body with no wind speed, built here rather than borrowed.** This used to point at Titan, which
	# had no `wind_speed`; on 2026-10-17 every atmosphere got one, so the check lost its subject and went
	# red with the *right* numbers in the message (a ratio of 0.206 where it expected zero). A rule about a
	# missing input must be tested with a missing input, not with whichever body happens to lack one today.
	var bare := SpacesimCloudModel.Morphology.new()
	var stripped := SpacesimSystemBody.new()
	stripped.radius = 6.371e6
	stripped.mass = 5.972e24
	stripped.rotation_period = 86400.0
	var air := SpacesimAtmosphere.new()
	air.surface_pressure = 101325.0
	air.species = {"nitrogen": 1.0}
	stripped.atmosphere = air
	var verdict := SpacesimCloudModel.morphology(stripped, materials, luminosity, 1.496e11)
	h.check(verdict.banding == SpacesimCloudModel.Banding.UNKNOWN,
		"a body with no wind speed gets UNKNOWN rather than a verdict")
	h.check_near(verdict.ratio, 0.0, "and no ratio", 1.0e-12)
	h.check_near(verdict.band_scale, 0.0, "and no band scale", 1.0e-12)
	h.check_near(verdict.cells, 0.0, "and no cell count", 1.0e-12)
	# And the real bodies now all have one, which is the content state this test should also state.
	var titan := _of(scene, "moon:titan", materials, luminosity)
	h.check(titan.banding != SpacesimCloudModel.Banding.UNKNOWN,
		"while every body in Sol now carries a wind speed and so gets a verdict")
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
	# **Uranus DOES contribute a layer now**, and the reason is the same one that fixed the giants: its
	# methane condenses at 77.3 K against a 76 K reference, so the level is just below the datum at about
	# 1.2 bar — the real methane deck. The old model called that a fog because its profile stopped at its
	# own reference and could not say where the level was.
	h.check(uranus_levels.size() == 1,
		"while Uranus's methane is a layer now, a little below the reference (%d)" % uranus_levels.size())

	# Nothing in the module may hand a shader a NaN or an infinity, whatever it is fed.
	var jupiter_morphology: SpacesimCloudModel.Morphology = _of(scene, "planet:jupiter", materials, luminosity)
	h.check(is_finite(jupiter_morphology.ratio) and is_finite(jupiter_morphology.band_scale)
		and is_finite(jupiter_morphology.eddy_scale) and is_finite(jupiter_morphology.cells),
		"and every number the model produces is finite")


## **A deck's top, and the one derivation that answers "how thick is a cloud?"**
##
## The thickness is the condensate scale height — where the saturation mixing ratio has fallen by e —
## capped by the tropopause. What the suite can honestly check is what it checked for the base: that the
## number lands where the real decks are, and that the two bodies where it *cannot* are named rather than
## tuned. See `SpacesimAtmosphereModel.Condensation.thickness`.
func _test_the_deck_thickness(
	h, scene: SpacesimSystemScene, materials: SpacesimMaterialTable, luminosity: float
) -> void:
	var earth_deck := _level_of(scene, "planet:earth", "water_vapour", materials, luminosity)
	h.check(earth_deck != null and earth_deck.regime == SpacesimAtmosphereModel.Condensation.Regime.LEVEL,
		"Earth's water has a level to put a deck on")
	if earth_deck == null:
		return
	h.check(earth_deck.thickness > 1000.0 and earth_deck.thickness < 2000.0,
		"and it is 1-2 km deep (%.0f m), against cumulus bases at 1-2 km and tops at 2-3" % earth_deck.thickness)

	# **The two bodies where it is honestly wrong, asserted as order with the reason in the message** —
	# Venus's deck is photochemical H2SO4 while this model condenses CO2 (the same cause as its base being
	# right for the wrong molecule), and Jupiter's is organised convection against a condensation scale.
	var venus_deck := _level_of(scene, "planet:venus", "carbon_dioxide", materials, luminosity)
	if venus_deck != null:
		h.check(venus_deck.thickness > 0.0 and venus_deck.thickness < 5000.0,
			"Venus's deck comes out %.0f m against a real 20 km one - a different molecule, and its base sits on the tropopause so the cap binds" % venus_deck.thickness)
	var jupiter_deck := _level_of(scene, "planet:jupiter", "ammonia", materials, luminosity)
	if jupiter_deck != null:
		h.check(jupiter_deck.thickness > 0.0 and jupiter_deck.thickness < 10000.0,
			"and Jupiter's ammonia scale is a few km (%.0f m) against a convective deck" % jupiter_deck.thickness)

	# **Every layer the model calls a LEVEL states a thickness**, which is the invariant D1 reads: a deck node
	# is `radius + height + thickness`, so a zero here would collapse the slab onto its own base.
	var earth := scene.body_by_id("planet:earth")
	var levelled := true
	var count := 0
	for level in SpacesimCloudModel.layers(
		earth.content.atmosphere, materials,
		SpacesimAtmosphereModel.surface_gravity(earth.content),
		SpacesimAtmosphereModel.equilibrium_temperature(earth.content, materials, luminosity,
			earth.position.distance_to(scene.star().position))
	):
		count += 1
		if level.thickness <= 0.0:
			levelled = false
	h.check(count > 0 and levelled, "and every LEVEL layer states one, not just the top (%d)" % count)

	# **The phase is a named ceiling, not a lookup** - the table states one latent heat per species and its
	# ice entries cannot be reached by name (`water_vapour`'s sibling is `water_ice`, so a suffix rule would
	# be a guess). What is checkable is that the ice entry exists and is the larger number, which is what
	# makes the ceiling's 25 % claim true rather than assumed.
	var vapour := materials.by_name("water_vapour")
	var ice := materials.by_name("water_ice")
	h.check(ice != null and ice.latent_heat > vapour.latent_heat,
		"and the ice entry exists and takes more heat to sublime than the liquid takes to evaporate")


## One species' level on a body, or null when the model places none.
func _level_of(
	scene: SpacesimSystemScene, body_id: String, species_name: String,
	materials: SpacesimMaterialTable, luminosity: float
) -> SpacesimAtmosphereModel.Condensation:
	var body := scene.body_by_id(body_id)
	if body == null or body.content == null or body.content.atmosphere == null:
		return null
	var levels := SpacesimCloudModel.layers(
		body.content.atmosphere, materials,
		SpacesimAtmosphereModel.surface_gravity(body.content),
		SpacesimAtmosphereModel.equilibrium_temperature(body.content, materials, luminosity,
			body.position.distance_to(scene.star().position))
	)
	for level in levels:
		if level.species == species_name:
			return level
	return null
