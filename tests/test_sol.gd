extends RefCounted
## Sol: the authored calibration system, and the material table its compositions name.
##
## A **data** test, not a physics test. It proves the dataset is well formed and that its numbers
## are the real ones — so the derivation built on top starts from reality rather than from something
## plausible. The values are NASA/NSSDC fact-sheet and JPL J2000 figures; see the header of
## systems/sol.tres for the provenance.

const SOL_PATH := "res://systems/sol.tres"
const MATERIALS_PATH := "res://addons/spacesim/system/content/materials.tres"

const AU := 1.495978707e11


func run(h, root: Node) -> void:
	print("  Sol")
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	h.check(sol != null, "the Sol system file loads")
	if sol == null:
		return

	_test_shape(h, sol)
	_test_calibration_values(h, sol)
	_test_framing_spans_the_system(h, sol)
	_test_species_are_known(h, sol)
	_test_orbits_from_real_data(h, sol)
	_test_the_scene_places_them(h, sol, root)


func _test_shape(h, sol: SpacesimSolarSystem) -> void:
	h.check(sol.system_name() == "Sol", "named after its star: '%s'" % sol.system_name())
	h.check(sol.epoch == "2000-01-01T12:00:00", "at the J2000 epoch")
	h.check(sol.bodies.size() == 9, "nine bodies: the Sun and eight planets (%d)" % sol.bodies.size())

	var star := sol.star()
	h.check(star != null and star.id == "star:sol", "the primary is Sol")
	h.check(star != null and star.kind == SpacesimSystemBody.Kind.STAR, "and it is a star")
	h.check(star != null and not star.orbits(), "and does not orbit anything")

	# The dataset at whole: fractions sum, layer boundaries ascend, every body that is not the
	# primary orbits something, and every parent chain reaches the star.
	var problems := sol.validate()
	var detail := "" if problems.is_empty() else ": " + ", ".join(problems)
	h.check(problems.is_empty(), "structurally sound%s" % detail)

	var landable := 0
	for body in sol.bodies:
		if body.landable:
			landable += 1
	h.check(landable == 4, "four landable bodies: Mercury, Venus, Earth, Mars (%d)" % landable)


func _test_calibration_values(h, sol: SpacesimSolarSystem) -> void:
	var star := sol.star()
	h.check_near(star.radius, 6.957e8, "Sol's radius is 695,700 km", 1.0e3)
	h.check_near(star.mass, 1.9884e30, "its authored mass is 1.9884e30 kg", 1.0e25)
	h.check_near(star.axial_tilt, 7.25, "tilted 7.25 degrees to the ecliptic", 0.01)

	var earth := sol.body_by_id("planet:earth")
	h.check(earth != null, "Earth is present")
	h.check_near(earth.radius, 6.371e6, "Earth's radius is 6,371 km", 1.0e3)
	h.check_near(earth.orbit.semi_major_axis, AU, "at one astronomical unit", 1.0e6)
	h.check_near(earth.axial_tilt, 23.44, "tilted 23.44 degrees", 0.01)
	h.check(earth.orbits(), "Earth orbits")
	h.check_near(earth.atmosphere.surface_pressure, 101325.0, "with 101,325 Pa of air", 1.0)
	h.check_near(
		float(earth.atmosphere.species.get("nitrogen", 0.0)),
		0.78084,
		"78.084% nitrogen by mole fraction",
		1.0e-5
	)
	# The target the temperature derivation must hit: greenhouse warming takes the 255 K blackbody
	# equilibrium to 288 K.
	h.check_near(sol.body_by_id("planet:venus").atmosphere.surface_pressure, 9.2e6,
		"Venus has 92 bar of CO2 to test the greenhouse against", 1.0e5)

	var venus := sol.body_by_id("planet:venus")
	h.check_near(venus.axial_tilt, 177.4,
		"Venus is retrograde written as axial_tilt > 90, not a negative period", 0.01)
	h.check(venus.rotation_period > 0.0, "so its rotation period stays positive")

	var uranus := sol.body_by_id("planet:uranus")
	h.check_near(uranus.axial_tilt, 97.77, "Uranus is tipped 97.77 degrees", 0.01)

	var mars := sol.body_by_id("planet:mars")
	h.check_near(mars.atmosphere.surface_pressure, 610.0, "Mars has 610 Pa", 1.0)

	# Gas giants carry an authored mass, and the dataset says so: a constant-density layer model
	# cannot represent a compressed envelope.
	for id in ["planet:jupiter", "planet:saturn", "planet:uranus", "planet:neptune"]:
		var giant := sol.body_by_id(id)
		h.check(giant.mass > 0.0, "%s authors its mass" % giant.display_name)
		h.check(not giant.landable, "and %s is not landable" % giant.display_name)


func _test_framing_spans_the_system(h, sol: SpacesimSolarSystem) -> void:
	# Bands and thresholds must agree, and the band has to reach the furthest thing in the system:
	# the playground's 1e11 m cap would not have reached Saturn, let alone Neptune.
	var neptune := sol.body_by_id("planet:neptune")
	var furthest := neptune.orbit.semi_major_axis + neptune.radius
	h.check(sol.framing.system_band.y >= furthest,
		"the system band reaches past Neptune (%s m vs %s m)"
			% [String.num(sol.framing.system_band.y), String.num(furthest)])
	h.check(sol.framing.atmosphere_band.y < sol.framing.system_band.y,
		"and the atmosphere band sits inside it")
	h.check(sol.framing.surface_band.y < sol.framing.atmosphere_band.y,
		"and the surface band inside that")


## Every species a composition names must exist in the table, or the derivation will silently
## treat a body as made of nothing.
func _test_species_are_known(h, sol: SpacesimSolarSystem) -> void:
	var materials: SpacesimMaterialTable = load(MATERIALS_PATH)
	h.check(materials != null, "the engine material table loads")
	if materials == null:
		return

	var names := materials.names()
	h.check(names.size() >= 20, "with the species Sol names (%d)" % names.size())

	var unknown := PackedStringArray()
	for body in sol.bodies:
		for layer in body.layers:
			_collect(names, layer.composition, body.id, unknown)
		if body.surface != null:
			_collect(names, body.surface.coverage, body.id, unknown)
		if body.atmosphere != null:
			_collect(names, body.atmosphere.species, body.id, unknown)

	var detail := "" if unknown.is_empty() else ": " + ", ".join(unknown)
	h.check(unknown.is_empty(), "and every species Sol names is in it%s" % detail)


func _collect(names: PackedStringArray, fractions: Dictionary, body_id: String, out: PackedStringArray) -> void:
	for key in fractions:
		var name := String(key)
		if not names.has(name) and not out.has(name):
			out.append(name)


## The formulas against the real data. This is what having an authored Sol buys: a period and a
## distance that come from physics can be checked against a number that came from a measurement.
func _test_orbits_from_real_data(h, sol: SpacesimSolarSystem) -> void:
	var star := sol.star()
	var mu := SpacesimKepler.mu_of(star.mass)
	var epoch := SpacesimSystemScene.clock_at_epoch(sol.epoch)
	h.check_near(epoch, 63113947200.0, "J2000 is 63,113,947,200 seconds after year zero", 1.0)

	# The period is an independent check: it comes from the star's authored mass and the planet's
	# semi-major axis, not from any of the orbit's angles.
	var earth := sol.body_by_id("planet:earth")
	var year_days := SpacesimKepler.period(earth.orbit, mu) / 86400.0
	h.check_near(year_days, 365.256, "the solved year is 365.256 days (%.4f)" % year_days, 0.02)

	# Where a body's own mass is known it belongs in the parameter — Jupiter moves itself.
	var jupiter := sol.body_by_id("planet:jupiter")
	var jupiter_mu := SpacesimKepler.mu_of(star.mass + jupiter.mass)
	var jupiter_days := SpacesimKepler.period(jupiter.orbit, jupiter_mu) / 86400.0
	h.check_near(jupiter_days, 4332.59, "and Jupiter's is 4,332.6 days (%.2f)" % jupiter_days, 0.5)

	var mars := sol.body_by_id("planet:mars")
	var mars_days := SpacesimKepler.period(mars.orbit, mu) / 86400.0
	h.check_near(mars_days, 686.98, "and Mars's is 687.0 days (%.3f)" % mars_days, 0.5)

	# Every planet must sit between the perihelion and aphelion its own elements imply.
	for body in sol.bodies:
		if body.orbit == null:
			continue
		var body_mu := SpacesimKepler.mu_of(star.mass + body.mass)
		var r := SpacesimKepler.position_at(body.orbit, body_mu, epoch, epoch).length()
		var perihelion := body.orbit.semi_major_axis * (1.0 - body.orbit.eccentricity)
		var aphelion := body.orbit.semi_major_axis * (1.0 + body.orbit.eccentricity)
		h.check(r >= perihelion * 0.999 and r <= aphelion * 1.001,
			"%s sits between its perihelion and aphelion (%.4f au)"
				% [body.display_name, r / AU])

	# Earth was a day and a half from perihelion at J2000, so its distance there is a number, not a
	# range: a(1-e) = 0.98329 au.
	var earth_r := SpacesimKepler.position_at(earth.orbit, mu, epoch, epoch).length()
	h.check_near(earth_r / AU, 0.9833, "Earth is near perihelion at J2000 (%.5f au)" % (earth_r / AU), 0.001)

	# And the inclination is real: the planets are not all in one plane.
	var mercury := sol.body_by_id("planet:mercury")
	var mercury_pos := SpacesimKepler.position_at(mercury.orbit, mu, epoch, epoch)
	h.check(absf(mercury_pos.y) > 1.0e9, "Mercury is out of the ecliptic by 7 degrees")


## The wiring: the scene takes the content and places the bodies from it, rather than from a file
## of literal positions.
func _test_the_scene_places_them(h, sol: SpacesimSolarSystem, root: Node) -> void:
	var scene := SpacesimSystemScene.from_content(sol)
	h.check(scene != null, "a scene wraps the content")
	if scene == null:
		return
	if scene.build(root) == null:
		h.check(false, "and builds")
		return

	h.check(scene.name == "Sol", "and names itself after its star: '%s'" % scene.name)
	h.check(scene.content_version() == sol.content_version, "and knows its content version")

	var star := scene.body_by_id("star:sol")
	var earth := scene.body_by_id("planet:earth")
	h.check(star != null and earth != null, "with Sol and Earth in it")
	if star != null and earth != null:
		var distance := earth.node.global_position.distance_to(star.node.global_position)
		h.check_near(distance / AU, 0.9833, "Earth is placed at its J2000 distance, not a literal position", 0.001)

	h.check(scene.frame_tree.frame_by_id("planet:earth/atmosphere") != null, "Earth has an atmosphere frame")
	h.check(scene.frame_tree.frame_by_id("planet:earth/surface") != null, "and a surface frame")
	h.check(scene.frame_tree.frame_by_id("planet:jupiter/surface") == null, "Jupiter has none: it is not landable")

	var start := scene.ship_start()
	var earth_node: Node3D = earth.node if earth != null else null
	if earth_node != null:
		h.check_near(start.distance_to(earth_node.global_position), earth.radius + sol.start_altitude,
			"and the ship starts above the start body", 1.0)

	scene.container.free()
