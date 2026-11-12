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
	_test_moons(h, sol)
	_test_the_scene_places_them(h, sol, root)
	_test_internal_heat(h, sol)


## **A body's own heat has to move its temperature, and must not move any other body's.** The insolation
## alone is recomputed here rather than by unsetting the field, because the loaded content is shared and a
## test that mutates it leaks into every suite that runs after it.
func _test_internal_heat(h, sol: SpacesimSolarSystem) -> void:
	var materials := SpacesimMaterialTable.engine_table()
	var star_luminosity := 0.0
	for body in sol.bodies:
		if body.kind == SpacesimSystemBody.Kind.STAR:
			star_luminosity = SpacesimStarModel.luminosity(body)
	for name in ["jupiter", "earth"]:
		var content := sol.body_by_id("planet:%s" % name)
		if content == null or content.orbit == null:
			continue
		var distance := content.orbit.semi_major_axis
		var albedo := SpacesimSurfaceModel.bond_albedo(content, materials)
		var absorbed := (1.0 - albedo) * star_luminosity / (4.0 * PI * distance * distance * 4.0)
		var insolation_only := pow(absorbed / SpacesimAtmosphereModel.STEFAN_BOLTZMANN, 0.25)
		var derived := SpacesimAtmosphereModel.equilibrium_temperature(
			content, materials, star_luminosity, distance
		)
		if content.internal_heat_flux > 0.0:
			h.check(derived > insolation_only + 1.0,
				"%s is warmer than its starlight alone (%.1f K against %.1f K)"
					% [name, derived, insolation_only])
		else:
			h.check(absf(derived - insolation_only) < 1.0e-6,
				"and %s, with no internal heat, is unchanged (%.1f K)" % [name, derived])


func _test_shape(h, sol: SpacesimSolarSystem) -> void:
	h.check(sol.system_name() == "Sol", "named after its star: '%s'" % sol.system_name())
	h.check(sol.epoch == "2000-01-01T12:00:00", "at the J2000 epoch")
	h.check(
		sol.bodies.size() == 40,
		"the Sun, eight planets and thirty-one moons — the small ones and then Saturn's and Uranus's round ones "
		+ "joined on 2026-11-12 (%d)" % sol.bodies.size()
	)

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
	h.check(
		landable == 35,
		"thirty-five landable bodies: four planets and thirty-one moons (%d)" % landable
	)


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


## The two-body parameter for whatever `body` orbits: a planet's mass for a moon, the star's for a
## planet. Using the star for a moon would be a quiet way to be wrong everywhere.
func _mu_for(sol: SpacesimSolarSystem, body: SpacesimSystemBody) -> float:
	var parent := sol.body_by_id(body.parent_id)
	if parent == null:
		parent = sol.star()
	return SpacesimKepler.mu_of((parent.mass if parent != null else 0.0) + body.mass)


## The formulas against the real data. This is what having an authored Sol buys: a period and a
## distance that come from physics can be checked against a number that came from a measurement.
func _test_orbits_from_real_data(h, sol: SpacesimSolarSystem) -> void:
	var star := sol.star()
	var mu := SpacesimKepler.mu_of(star.mass)
	var epoch := SpacesimWorldTime.clock_at_epoch(sol.epoch)
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

	# Every orbiting body must stay between the perihelion and aphelion its own elements imply —
	# sampled all the way round, not just at the epoch. At the epoch alone the mean anomaly is just
	# m0 and the mass cancels out, so that would test the rotation and nothing about the solver.
	for body in sol.bodies:
		if body.orbit == null:
			continue
		var body_mu := _mu_for(sol, body)
		var orbit_period := SpacesimKepler.period(body.orbit, body_mu)
		var perihelion := body.orbit.semi_major_axis * (1.0 - body.orbit.eccentricity)
		var aphelion := body.orbit.semi_major_axis * (1.0 + body.orbit.eccentricity)
		var worst := 0.0
		for step in 12:
			var when := epoch + orbit_period * float(step) / 12.0
			var r := SpacesimKepler.position_at(body.orbit, body_mu, when, epoch).length()
			worst = maxf(worst, maxf(perihelion - r, r - aphelion))
		h.check(worst <= perihelion * 0.001,
			"%s stays between its perihelion and aphelion all the way round" % body.display_name)

	# Earth was a day and a half from perihelion at J2000, so its distance there is a number, not a
	# range: a(1-e) = 0.98329 au.
	var earth_r := SpacesimKepler.position_at(earth.orbit, mu, epoch, epoch).length()
	h.check_near(earth_r / AU, 0.9833, "Earth is near perihelion at J2000 (%.5f au)" % (earth_r / AU), 0.001)

	# And the inclination is real: the planets are not all in one plane.
	var mercury := sol.body_by_id("planet:mercury")
	var mercury_pos := SpacesimKepler.position_at(mercury.orbit, mu, epoch, epoch)
	h.check(absf(mercury_pos.y) > 1.0e9, "Mercury is out of the ecliptic by 7 degrees")


## The moons check the hierarchy. A moon's period comes from its **planet's** mass and its own
## semi-major axis, so it only solves correctly if the parent lookup, the two-body parameter and
## the solver are all right together.
func _test_moons(h, sol: SpacesimSolarSystem) -> void:
	var expected := {
		"moon:luna": [27.284, "Luna"],
		"moon:io": [1.7693, "Io"],
		"moon:europa": [3.5516, "Europa"],
		"moon:ganymede": [7.1552, "Ganymede"],
		"moon:callisto": [16.6908, "Callisto"],
		"moon:titan": [15.9505, "Titan"],
		"moon:triton": [5.8887, "Triton"],
		# **The small moons, whose elements are real** — a period that solves correctly out of the parent's mass
		# and the semi-major axis is what proves the authored numbers are the published ones and not invented.
		"moon:metis": [0.29478, "Metis"],
		"moon:adrastea": [0.29826, "Adrastea"],
		"moon:amalthea": [0.49818, "Amalthea"],
		"moon:thebe": [0.67454, "Thebe"],
		"moon:pan": [0.57505, "Pan"],
		"moon:daphnis": [0.59400, "Daphnis"],
		"moon:atlas": [0.60169, "Atlas"],
		"moon:prometheus": [0.61300, "Prometheus"],
		"moon:pandora": [0.62850, "Pandora"],
		"moon:epimetheus": [0.69433, "Epimetheus"],
		"moon:janus": [0.69459, "Janus"],
		# The round moons of Saturn and Uranus.
		"moon:mimas": [0.94242, "Mimas"],
		"moon:enceladus": [1.37022, "Enceladus"],
		"moon:tethys": [1.88780, "Tethys"],
		"moon:dione": [2.73692, "Dione"],
		"moon:rhea": [4.51750, "Rhea"],
		"moon:iapetus": [79.3200, "Iapetus"],
		"moon:miranda": [1.41348, "Miranda"],
		"moon:ariel": [2.52038, "Ariel"],
		"moon:umbriel": [4.14418, "Umbriel"],
		"moon:titania": [8.70587, "Titania"],
		"moon:oberon": [13.4632, "Oberon"],
	}
	for id in expected:
		var label: String = expected[id][1]
		var moon := sol.body_by_id(id)
		h.check(moon != null, "%s is present" % label)
		if moon == null:
			continue
		h.check(moon.kind == SpacesimSystemBody.Kind.MOON, "and is a moon")
		var parent := sol.body_by_id(moon.parent_id)
		h.check(parent != null and parent.kind == SpacesimSystemBody.Kind.PLANET,
			"orbiting a planet (%s)" % (parent.display_name if parent != null else "?"))
		if parent == null:
			continue
		var mu := SpacesimKepler.mu_of(parent.mass + moon.mass)
		var days := SpacesimKepler.period(moon.orbit, mu) / 86400.0
		# **The tolerance is relative past 20 days**, because the published pair itself only agrees to about 0.02 %:
		# Iapetus's measured a and period are consistent with each other only to that much, so an absolute 0.02 days
		# asks the solver to be more accurate than the data it is checked against.
		var tolerance := maxf(0.02, float(expected[id][0]) * 0.001)
		h.check_near(days, expected[id][0], "and its period solves to %.4f days" % days, tolerance)
		# Tidally locked: one face in, so the rotation period IS the orbital period. Half a percent,
		# because the authored rotation uses the measured period and the solved one comes from the
		# mean semi-major axis.
		var turn := moon.rotation_period / (days * 86400.0)
		h.check(absf(turn - 1.0) < 0.005, "and is tidally locked (%.4f turns per orbit)" % turn)

	# Triton was captured and orbits backwards, which the format expresses as an inclination past
	# 90 degrees rather than a negative anything.
	var triton := sol.body_by_id("moon:triton")
	h.check(triton.orbit.inclination > 90.0,
		"Triton is retrograde, at %.1f degrees" % triton.orbit.inclination)


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

	# A moon is placed relative to its planet, not to the star — which is what the dependency-ordered
	# placement exists for.
	var luna := scene.body_by_id("moon:luna")
	if luna != null and earth != null:
		var to_earth := luna.node.global_position.distance_to(earth.node.global_position)
		h.check_near(to_earth, 3.844e8,
			"Luna orbits Earth rather than the Sun (%s m away)" % String.num(to_earth), 3.844e8 * 0.06)
		var to_sun := luna.node.global_position.distance_to(star.node.global_position)
		h.check(to_sun > 1.4e11, "and is a long way from the star, not circling it")

	var start := scene.ship_start()
	var earth_node: Node3D = earth.node if earth != null else null
	if earth_node != null:
		h.check_near(start.distance_to(earth_node.global_position), earth.radius + sol.start_altitude,
			"and the ship starts above the start body", 1.0)

	# **Moons are not in a line.** Every moon in the file leaves `mean_anomaly_at_epoch` at 0, and one anomaly for a
	# whole planet puts its moons on one straight line out of it. Evert, 2026-11-12: *"All the moons are placed in
	# straight lines, which is highly unlikely and looks wrong."* The phase is derived from the body's address, so
	# this is deterministic rather than lucky.
	var mars := scene.body_by_id("planet:mars")
	var phobos := scene.body_by_id("moon:phobos")
	var deimos := scene.body_by_id("moon:deimos")
	if mars != null and phobos != null and deimos != null:
		var to_phobos := (phobos.node.global_position - mars.node.global_position).normalized()
		var to_deimos := (deimos.node.global_position - mars.node.global_position).normalized()
		var apart := rad_to_deg(acos(clampf(to_phobos.dot(to_deimos), -1.0, 1.0)))
		h.check(apart > 15.0,
			"Mars' two moons are %.0f degrees apart round the planet, not on one line" % apart)

	var jupiter := scene.body_by_id("planet:jupiter")
	var spread := 0.0
	var jupiter_moons: Array[SpacesimSceneBody] = []
	for body in scene.bodies:
		if body.parent_id == "planet:jupiter" and body.node != null:
			jupiter_moons.append(body)
	for a in jupiter_moons:
		for b in jupiter_moons:
			if a == b or jupiter == null:
				continue
			var da := (a.node.global_position - jupiter.node.global_position).normalized()
			var db := (b.node.global_position - jupiter.node.global_position).normalized()
			spread = maxf(spread, rad_to_deg(acos(clampf(da.dot(db), -1.0, 1.0))))
	h.check(jupiter_moons.size() > 2 and spread > 90.0,
		"and Jupiter's %d moons spread %.0f degrees round it" % [jupiter_moons.size(), spread])

	_test_the_rocks(h, scene, root)

	scene.container.free()


## **A non-planet is built by its own mechanism, and the mesh that is drawn is the generated shape.**
##
## This is the check that did not exist when the last attempt at irregular bodies went wrong: a green suite that
## asserted the shape and never looked at a vertex that reached a mesh. Evert, 2026-11-08: *"I am not getting a
## height translation for this shape ... the body of Phobos still looks very round"*, five commits after every test
## in the branch passed.
##
## So: the vertex COUNT is the sweep's grid, the vertices ARE the generator's, nothing planet-shaped was created
## beside them, and the eye moving does not replace the mesh.
func _test_the_rocks(h, scene: SpacesimSystemScene, root: Node) -> void:
	var phobos := scene.body_by_id("moon:phobos")
	var earth := scene.body_by_id("planet:earth")
	h.check(phobos != null, "Phobos built")
	if phobos == null or phobos.mesh == null:
		return
	h.check(phobos.irregular, "and is drawn by its own mechanism, because 11 km of rock was never rounded")

	# **The boundary is DERIVED per material, and the inventory is what falsifies it.** Evert, 2026-11-12: *"Lets add
	# the round moons as well."* One constant could not serve both: Mimas is 198 km of ice and is round, Amalthea is
	# 83 km of rock and is a lump. Ice (2 MPa) rounds at 130 km against rock's 384, and both facts come out right.
	var materials := SpacesimMaterialTable.engine_table()
	var mimas := scene.body_by_id("moon:mimas")
	var amalthea := scene.body_by_id("moon:amalthea")
	h.check(mimas != null and not mimas.irregular,
		"Mimas, 198 km of ice, is round — ice rounds at %.0f km"
			% (SpacesimIrregularBody.rounding_radius(mimas.content, materials) / 1000.0))
	h.check(amalthea != null and amalthea.irregular,
		"while Amalthea, 83 km of rock, is still a lump — rock rounds at %.0f km"
			% (SpacesimIrregularBody.rounding_radius(amalthea.content, materials) / 1000.0))
	h.check(earth != null and not earth.irregular, "while Earth, which gravity did round, keeps the planet path")

	# **Placed at load, NOT extracted at load.** Evert, 2026-11-12: *"We should only be building them when we get
	# close enough to start resolving them. Does the LOD principle mean nothing to you?"* — a system with a dozen
	# small moons paid ten seconds at load for geometry nobody was looking at.
	h.check(not phobos.irregular_built and phobos.mesh.mesh == null,
		"a rock nobody is close enough to resolve is placed but not extracted")

	# **From far away it is its own point of light**, which is what keeps it from being a hole while it is still
	# unextracted — the publish-over rule the patch walk and the cloud maps follow.
	var camera := Camera3D.new()
	camera.fov = 70.0
	root.add_child(camera)
	camera.global_position = phobos.node.global_position + Vector3(0.0, 0.0, 1.0e7)
	scene.update_lod(camera)
	h.check(phobos.point != null and phobos.point.visible,
		"from far away it is drawn as its point of light, so it is never a hole")
	h.check(not phobos.irregular_built, "and still not extracted, because nothing can resolve it")

	# Bring the eye in: at 40 km an 11 km rock is a disc, so the extraction is asked for and the join publishes it.
	camera.global_position = phobos.node.global_position + Vector3(0.0, 0.0, 40000.0)
	scene.update_lod(camera)
	scene.await_patch_builds()
	h.check(phobos.irregular_built and phobos.mesh.mesh != null,
		"closing in on it extracts the shape, once")
	# The frame after the join is what makes it visible — a mesh published mid-frame is drawn from the next one.
	scene.update_lod(camera)
	h.check(phobos.mesh.visible and not phobos.point.visible,
		"and the next frame draws the shape instead of the splat")

	var arrays: Array = (phobos.mesh.mesh as ArrayMesh).surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var generated: Array = SpacesimBlobShape.mesh(
		hash("moon:phobos"), phobos.radius, SpacesimIrregularBody.RESOLUTION, [], phobos.irregularity
	).surface_get_arrays(0)
	h.check(vertices.size() > 500 and vertices.size() == (generated[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(),
		"its mesh comes from the field's extraction, not from an icosphere (%d vertices)" % vertices.size())
	h.check(generated[Mesh.ARRAY_VERTEX] == vertices,
		"and every vertex is the generated surface — this is the check the last attempt never had")

	# **Wound the way the ENGINE winds, measured against the engine.** Evert, 2026-11-12, flying it: *"it seems its
	# rendered inside-out... I see the far side of the mesh, and its lit wrong."* Every outward triangle was culled
	# and the inside of the far wall drawn instead. **A check against my own convention could not catch that** — the
	# sign is what has to match Godot, so it is measured against `SphereMesh`, whose winding every material here is
	# written for (`tests/test_icosphere.gd` does the same thing for the sphere levels).
	var reference := SphereMesh.new()
	reference.radius = 1.0
	reference.height = 2.0
	reference.radial_segments = 16
	reference.rings = 8
	h.check(
		signf(_signed_volume(reference)) == signf(_signed_volume(phobos.mesh.mesh)),
		"and the rock is wound the SAME way as SphereMesh, so it is drawn from outside and not inside out"
	)

	# **And the altitude is measured to its own vertices.** A mean radius is wrong by the whole relief: on Phobos
	# 830 m, which is the difference between hovering and standing. Asked at a vertex, the mesh datum answers ~0
	# while the sphere answers whatever the relief is there — which is what makes this check able to fail.
	var nearest_vertex := Vector3.ZERO
	var furthest := -1.0
	for vertex in vertices:
		if vertex.length() > furthest:
			furthest = vertex.length()
			nearest_vertex = vertex
	var on_the_lump := phobos.node.global_position + nearest_vertex
	var to_the_mesh := phobos.scale_body.surface_distance_mesh(on_the_lump)
	var to_the_sphere := phobos.scale_body.surface_distance_to(on_the_lump)
	h.check(to_the_mesh < 1.0,
		"standing on the highest vertex is zero altitude to the mesh (%.2f m)" % to_the_mesh)
	h.check(to_the_sphere > 200.0,
		"and the mean sphere would have said %.0f m, which is why it is not the datum" % to_the_sphere)

	var lo := Vector3.ONE * INF
	var hi := Vector3.ONE * -INF
	for vertex in vertices:
		lo = Vector3(minf(lo.x, vertex.x), minf(lo.y, vertex.y), minf(lo.z, vertex.z))
		hi = Vector3(maxf(hi.x, vertex.x), maxf(hi.y, vertex.y), maxf(hi.z, vertex.z))
	var size := hi - lo
	var thin := minf(size.x, minf(size.y, size.z))
	var thick := maxf(size.x, maxf(size.y, size.z))
	h.check(thick / maxf(thin, 1.0) > 1.4,
		"and it is a rock across its axes (%.1f x %.1f x %.1f km)"
			% [size.x / 1000.0, size.y / 1000.0, size.z / 1000.0])

	# **And none of the planet machinery was built beside it.** A flag that says "skip the walk" is what the last
	# attempt had, and it meant five other switches; here there is simply nothing to skip.
	h.check(phobos.surface_plan == null, "with no field plan, because it has no field")
	h.check(phobos.decks.is_empty() and phobos.air.is_empty(), "and no decks and no air")
	h.check(phobos.sphere == null and phobos.ocean == null and phobos.interior == null,
		"and no datum lattice, sea or interior")

	# **Irregularity tapers with size.** Evert, 2026-11-12: *"smaller moons would look more irregular, and larger
	# moons would tend to look more round from a distance."* Both shades of "not a sphere" — the off-centre balls and
	# the fractal relief — scale with the same number, so a body near its own rounding radius is a slightly lumpy
	# sphere and one far below it is a rock. Which also means a misclassified body costs relief, not a wrong shape.
	var rocky := SpacesimBlobShape.arrays(hash("moon:phobos"), 40000.0, 48, [], 0.9)
	var rounding := SpacesimBlobShape.arrays(hash("moon:phobos"), 40000.0, 48, [], 0.15)
	var sphere := SpacesimBlobShape.arrays(hash("moon:phobos"), 40000.0, 48, [], 0.0)
	h.check(_lumpiness(rocky) > _lumpiness(rounding) * 1.8,
		"the same body at a lower irregularity is rounder (%.2f against %.2f)"
			% [_lumpiness(rocky), _lumpiness(rounding)])
	h.check(_lumpiness(sphere) < 0.02,
		"and at zero it IS a sphere (%.3f)" % _lumpiness(sphere))

	# **The eye cannot replace its mesh with a walked one.** This is the fault that made the last attempt draw a
	# sphere in flight: a body whose geometry the walk rebuilt underneath it.
	h.check(phobos.patch_walk_task == -1 and phobos.patch_task == -1,
		"no walk was asked for it when the eye moved")
	h.check(phobos.patch_chunks.is_empty(), "and it has no patch tree")
	var after: Array = (phobos.mesh.mesh as ArrayMesh).surface_get_arrays(0)
	h.check(after[Mesh.ARRAY_VERTEX] == vertices, "so its mesh is the same shape after the eye moved")
	h.check(phobos.mesh.visible, "and it is drawn")
	camera.queue_free()

	# **And the debug view shows ITS mesh, as lines.** Evert, 2026-11-12: *"in wireframe mode, I want to see the
	# meshes of EVERYTHING."* A wireframe here is a `PRIMITIVE_LINES` mesh and not a material, so a body with no walk
	# had none — the check is that the primitive type actually changes, not that something was made white.
	var top_camera := Camera3D.new()
	top_camera.fov = 70.0
	root.add_child(top_camera)
	top_camera.global_position = phobos.node.global_position + Vector3(0.0, 0.0, 40000.0)
	scene.wireframe = true
	scene.update_lod(top_camera)
	var wire := phobos.mesh.mesh as ArrayMesh
	h.check(wire != null and wire.surface_get_primitive_type(0) == Mesh.PRIMITIVE_LINES,
		"in wireframe mode the rock's own mesh is drawn as lines")
	var edges: PackedInt32Array = wire.surface_get_arrays(0)[Mesh.ARRAY_INDEX] if wire != null else PackedInt32Array()
	h.check(edges.size() > 0 and edges.size() % 2 == 0,
		"with the grid's edges as segments (%d)" % edges.size())
	scene.wireframe = false
	scene.update_lod(top_camera)
	h.check((phobos.mesh.mesh as ArrayMesh).surface_get_primitive_type(0) == Mesh.PRIMITIVE_TRIANGLES,
		"and turning the view off gives the solid mesh back, not a wireframe left standing")
	top_camera.queue_free()

	# **The datum must answer everywhere the ship can ask it.** `surface_distance_mesh` is called every tick, and
	# its answer IS the ship's speed (`local_length / TRAVERSE_SECONDS`); an INF or a NaN there means the system
	# band's 1e13 m maximum, which is 1.7e10 m in one tick. Evert, 2026-11-12: *"suddenly I was transported quite
	# the distance away from the moons & mars"*. So the whole shell the caller is allowed to ask about is swept,
	# not one point of it.
	var worst := 0.0
	var missing := 0
	for index in 128:
		var direction := Vector3(
			cos(TAU * float(index) / 128.0), sin(TAU * float(index) / 128.0), 0.0
		).normalized()
		for multiplier in [1.0, 1.05, 1.1, 1.2, 1.3, 1.35]:
			var probe: Vector3 = phobos.node.global_position + direction * (phobos.radius * multiplier)
			var distance := phobos.scale_body.surface_distance_mesh(probe)
			if not is_finite(distance):
				missing += 1
			else:
				worst = maxf(worst, distance)
	h.check(missing == 0,
		"the altitude datum answers at every point inside its own reach (%d answers were not a number)" % missing)
	h.check(worst < phobos.radius * 2.0,
		"and never answers more than the body is wide (%.1f km)" % (worst / 1000.0))

	# **A mined body is the seed plus its removals**, and the datum follows: the surface recedes where the chunk
	# came out and is untouched everywhere else. This is the property mining will be built on, so it is asserted
	# before there is a pickaxe rather than after.
	var seed_value := hash("moon:phobos")
	var before := SpacesimBlobShape.radius_at(
		seed_value, phobos.radius, Vector3.RIGHT, SpacesimIrregularBody.RESOLUTION
	)
	var behind := SpacesimBlobShape.radius_at(
		seed_value, phobos.radius, Vector3.LEFT, SpacesimIrregularBody.RESOLUTION
	)
	# **At the surface, not out in space.** A removal is a ball, so one placed beyond the body grazes it and removes
	# almost nothing — which is what the first version of this asserted, and it reported 4.6 km to 4.4 km.
	var at_surface := Vector3(before / phobos.radius, 0.0, 0.0)
	var removals := [[at_surface, 0.25]]
	var carved := SpacesimBlobShape.radius_at(
		seed_value, phobos.radius, Vector3.RIGHT, SpacesimIrregularBody.RESOLUTION, removals
	)
	var still_there := SpacesimBlobShape.radius_at(
		seed_value, phobos.radius, Vector3.LEFT, SpacesimIrregularBody.RESOLUTION, removals
	)
	h.check(carved < before * 0.85 and carved > 0.0,
		"a chunk taken out of a body takes its surface in (%.1f km to %.1f km)"
			% [before / 1000.0, carved / 1000.0])
	h.check(is_equal_approx(still_there, behind),
		"and the far side of the body is untouched, because a removal is local")


## **A mesh's signed volume**, which is the one thing about winding that is measurable with no render: the sign
## flips when the whole surface is wound the other way. Borrowed verbatim from `tests/test_icosphere.gd`, where
## the same measurement proved the sphere levels against `SphereMesh`.
static func _signed_volume(mesh: Mesh) -> float:
	var arrays := mesh.surface_get_arrays(0)
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var total := 0.0
	if indices.is_empty():
		for i in range(0, points.size(), 3):
			total += points[i].dot(points[i + 1].cross(points[i + 2]))
	else:
		for i in range(0, indices.size(), 3):
			total += points[indices[i]].dot(points[indices[i + 1]].cross(points[indices[i + 2]]))
	return total / 6.0


## **How lumpy a shape is**, as the spread of vertex distances from the centre over their mean. A sphere is 0, a rock
## is a tenth or more. Used to compare the same seed at different irregularities, so the only variable is the one
## under test.
static func _lumpiness(surface: Array) -> float:
	var points: PackedVector3Array = surface[Mesh.ARRAY_VERTEX]
	if points.is_empty():
		return 0.0
	var lo := INF
	var hi := 0.0
	var total := 0.0
	for point in points:
		var length := point.length()
		lo = minf(lo, length)
		hi = maxf(hi, length)
		total += length
	return (hi - lo) / maxf(total / float(points.size()), 1.0e-9)
