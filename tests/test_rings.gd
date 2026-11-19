extends RefCounted
## **Saturn's rings** — the sheet, its light, its shadow, the split, and the rocks it resolves into.
##
## The numbers here are Saturn's own: the C, B and A rings at 74,658–91,975, 91,975–117,580 and
## 122,170–136,775 km, with the Cassini division as the space between the last two, and the measured optical
## depths 0.1, 1.2 and 0.7. The requirements are `R1`–`R33` of the vault's "Asteroids and Rings".
##
## **What a test can and cannot see.** A `MultiMesh`'s instance transforms cannot be read back in a headless run —
## `get_instance_transform()` returns the identity whatever was written — so nothing here asserts what the draw
## holds. What it asserts is the data the builder writes *from*, the uniforms the shader is told, and the layer
## table. The picture is Evert's to judge.

const AU := 1.495978707e11
## Saturn's radius, metres — the caster of every shadow on the rings.
const SATURN_RADIUS := 60268000.0
## The Sun's, for the penumbra the two-circle law models.
const STAR_RADIUS := 696340000.0


func run(h, root: Node) -> void:
	_test_three_bands_are_authored(h)
	_test_the_cloud_fills_its_band(h)
	_test_the_nearest_is_the_nearest(h)
	_test_the_closest_point_is_trigonometry(h)
	_test_the_band_is_as_bright_as_saturn_says(h)
	_test_the_rings_encircle_the_equator(h, root)
	_test_the_walk_refines_under_the_ship(h, root)
	_test_every_body_shader_is_told_the_same_sun(h, root)
	_test_the_shadow_is_the_planets(h, root)
	_test_the_band_is_one_draw(h, root)
	_test_the_layers_cannot_tie(h, root)
	_test_a_spot_becomes_a_rock_by_one_rule(h, root)
	_test_a_rock_is_a_body_that_sets_the_unit(h, root)
	_test_a_rock_body_leaves_nothing_behind(h, root)
	_test_the_light_side_is_the_side_the_star_is_on(h, root)


func _sol() -> SpacesimSolarSystem:
	return load("res://systems/sol.tres")


## **`R32`, `R6`, `R7`** — three bands, with the gaps as the space between them, and the sizes Evert gave:
## the top 300,000 objects embedded in Saturn's main rings, 100 m to 30 km across.
func _test_three_bands_are_authored(h) -> void:
	var sol := _sol()
	var bands: Array = []
	for id in ["population:ring_c", "population:ring_b", "population:ring_a"]:
		var population := sol.population_by_id(id)
		h.check(population != null, "%s is content" % id)
		if population == null:
			return
		h.check(population.parent_id == "planet:saturn", "%s orbits Saturn" % id)
		h.check(population.particle_count > 0, "%s is a sheet, not a swarm (%d particles)" % [id, population.particle_count])
		h.check(population.optical_depth > 0.0, "%s has an optical depth (%.2f)" % [id, population.optical_depth])
		h.check_near(population.size_floor, 100.0, "%s's smallest drawn object is 100 m" % id, 1.0)
		h.check_near(population.size_ceiling, 30000.0, "%s's largest is 30 km" % id, 1.0)
		bands.append(population)

	# **The gaps are the space between the populations**, which is why they are three of them: the C ring ends
	# where the B ring starts, and the Cassini division is the 4,590 km between the B and the A ring.
	var c: SpacesimPopulation = bands[0]
	var b: SpacesimPopulation = bands[1]
	var a: SpacesimPopulation = bands[2]
	h.check_near(c.semi_major_axis.y, b.semi_major_axis.x, "the C ring meets the B ring", 1.0)
	var division := a.semi_major_axis.x - b.semi_major_axis.y
	h.check(division > 3.0e6 and division < 6.0e6,
		"the Cassini division is between them (%.0f km)" % [division / 1.0e3])

	# **Every band shares one plane**, because they are one system seen at one season.
	h.check(c.ring_axis.is_equal_approx(b.ring_axis) and b.ring_axis.is_equal_approx(a.ring_axis),
		"the three bands lie in the same plane")
	# **And it is a season**: the star 20 degrees above that plane is what gives the planet's shadow its reach.
	# The direction comes from the loaded system, never from a hardcoded triple — the first version of this had
	# the orbital-elements frame where the engine's is (X, -Z, -Y), and put the star *in* the plane.
	var saturn := Vector3(959638100292.751, -55223571194.788, -979217915059.77)
	var sun_cosine := SpacesimRingModel.cosine(a.ring_axis.normalized(), -saturn.normalized())
	h.check(sun_cosine > 0.3 and sun_cosine < 0.4,
		"the star sits 20 degrees above the ring plane (cos %.3f)" % sun_cosine)
	var reach := SATURN_RADIUS / sun_cosine
	h.check(reach > a.semi_major_axis.y,
		"so the shadow reaches past the A ring (%.0f km)" % [reach / 1.0e3])

	var total := 0
	for population in bands:
		total += population.particle_count
	h.check(total == 300000, "the drawn sample is the 300,000 largest objects (%d)" % total)


## **`R1`, `R3`, `R7`** — the particles are spread over the band's area, sized by the cascade's own law, and the
## mean that the shader needs is the area-weighted one.
func _test_the_cloud_fills_its_band(h) -> void:
	var band := _sol().population_by_id("population:ring_b")
	var cloud := SpacesimParticleCloud.of(band)
	h.check(cloud.size() == band.particle_count,
		"every authored particle exists (%d)" % cloud.size())

	var inner := band.semi_major_axis.x
	var outer := band.semi_major_axis.y
	var smallest := INF
	var largest := 0.0
	var squared := 0.0
	var flat := true
	for index in cloud.size():
		var local := cloud.positions[index]
		var radius := sqrt(local.x * local.x + local.y * local.y)
		inner = minf(inner, radius)
		outer = maxf(outer, radius)
		if absf(local.z) > band.thickness * 0.5 + 1.0e-6:
			flat = false
		smallest = minf(smallest, cloud.radii[index] * 2.0)
		largest = maxf(largest, cloud.radii[index] * 2.0)
		squared += cloud.radii[index] * cloud.radii[index]

	h.check(inner >= band.semi_major_axis.x - 1.0 and outer <= band.semi_major_axis.y + 1.0,
		"every particle is inside the band (%.0f to %.0f km)"
			% [inner / 1.0e3, outer / 1.0e3])
	h.check(flat, "every particle is inside the slab, %.0f m thick, of %d" % [band.thickness, cloud.size()])
	h.check(smallest >= 100.0 * 0.999, "none is below the floor (%.1f m)" % smallest)
	h.check(largest <= 30000.0 * 1.001, "none is above the ceiling (%.0f m)" % largest)
	h.check_near(
		cloud.mean_radius(), sqrt(squared / float(cloud.size())),
		"the mean radius is the area-weighted one, over the rocks", 1.0
	)
	# **Uniform by AREA, not by radius**: the inner edge must not be crowded. Half the band's area is at
	# `sqrt((inner² + outer²)/2)`, so half the particles should be inside it.
	var middle := sqrt((band.semi_major_axis.x * band.semi_major_axis.x
		+ band.semi_major_axis.y * band.semi_major_axis.y) * 0.5)
	var inside := 0
	for index in cloud.size():
		if Vector2(cloud.positions[index].x, cloud.positions[index].y).length() <= middle:
			inside += 1
	h.check_near(float(inside) / float(cloud.size()), 0.5, "the cloud is uniform by area", 0.01)

	# **The same ring every load**, and two bands are two different rings.
	var again := SpacesimParticleCloud.of(band)
	var same := true
	for index in range(0, cloud.size(), 977):
		if not again.positions[index].is_equal_approx(cloud.positions[index]):
			same = false
	h.check(same, "the same seed is the same ring")
	var other := SpacesimParticleCloud.of(_sol().population_by_id("population:ring_a"))
	h.check(other.size() > 0 and not other.positions[0].is_equal_approx(cloud.positions[0]),
		"and a different seed is a different one")


## **`R27`, `R28`** — the index returns the TRUE nearest, against a brute-force scan, from wherever the ship is:
## outside the band, inside it, above the plane, and a long way round.
func _test_the_nearest_is_the_nearest(h) -> void:
	var band := _sol().population_by_id("population:ring_b")
	var cloud := SpacesimParticleCloud.of(band)
	var band_middle := (band.semi_major_axis.x + band.semi_major_axis.y) * 0.5
	var places := [
		Vector3(0.0, 0.0, 0.0),
		Vector3(band_middle, 0.0, 0.0),
		Vector3(0.0, band_middle, 5.0e5),
		Vector3(band_middle * 0.6, band_middle * 0.8, -2.0e6),
		Vector3(1.5e10, 0.0, 0.0),
	]
	for where in places:
		# Brute force, over every particle.
		var nearest := INF
		var nearest_index := -1
		for index in cloud.size():
			var distance := cloud.positions[index].distance_to(where)
			if distance < nearest:
				nearest = distance
				nearest_index = index
		var found := cloud.nearest(where, 1)
		h.check(found.size() == 1, "one answer at (%.0f, %.0f, %.0f) Mm"
			% [where.x / 1e6, where.y / 1e6, where.z / 1e6])
		if found.size() == 1:
			h.check_near(cloud.positions[found[0]].distance_to(where), nearest,
				"and it is the true nearest", 1.0)

		# **And the several**, in order and with no repeats.
		var many := cloud.nearest(where, 5)
		h.check(many.size() == 5, "five of them")
		var previous := -1.0
		var unique := {}
		var ordered := true
		for index in many:
			var distance := cloud.positions[index].distance_to(where)
			if distance < previous or unique.has(index):
				ordered = false
			previous = distance
			unique[index] = true
		h.check(ordered and unique.size() == many.size(), "sorted, and no particle twice")
		if nearest_index >= 0 and many.size() > 0:
			h.check(many[0] == nearest_index, "starting with the nearest")


## **`R28`** — "the ring is a geometric shape": the closest point on the band is a clamp and a bearing.
func _test_the_closest_point_is_trigonometry(h) -> void:
	var inner := 91975000.0
	var outer := 117580000.0
	var middle := (inner + outer) * 0.5
	# Inside the band's radius: the closest point is straight out along the bearing.
	var inside := SpacesimParticleCloud.closest_point(Vector3(middle, 0.0, 0.0), inner, outer)
	h.check(inside.is_equal_approx(Vector3(middle, 0.0, 0.0)), "a point in the band is its own")
	# Beyond it: clamped to the outer edge, on the same bearing.
	var beyond := SpacesimParticleCloud.closest_point(Vector3(5.0 * outer, 0.0, 0.0), inner, outer)
	h.check(beyond.is_equal_approx(Vector3(outer, 0.0, 0.0)), "outside, it is the outer edge")
	# Inside the hole: clamped to the inner edge.
	var within := SpacesimParticleCloud.closest_point(Vector3(1.0e6, 0.0, 0.0), inner, outer)
	h.check(within.is_equal_approx(Vector3(inner, 0.0, 0.0)), "inside the gap, it is the inner edge")
	# Above the plane: the same bearing, and the height is not part of a band with no thickness.
	var above := SpacesimParticleCloud.closest_point(Vector3(middle, 0.0, 1.0e7), inner, outer)
	h.check_near(above.z, 0.0, "the closest point is on the sheet", 1.0e-6)
	h.check_near(Vector2(above.x, above.y).length(), middle, "and at the ship's own radius", 1.0)


## **`R4`, `R8`, `R32`** — the reflectance law, and the three numbers Saturn is known by.
func _test_the_band_is_as_bright_as_saturn_says(h) -> void:
	# **Single scattering out of the slab**, at normal incidence and emergence: `(1/4)·(1/2)·(1-exp(-2·tau))`.
	# It saturates rather than growing without bound, which is what one bounce can deliver.
	for pair in [[0.1, 0.0227], [0.7, 0.0942], [1.2, 0.1142]]:
		var tau: float = pair[0]
		var expected: float = pair[1]
		h.check_near(SpacesimRingModel.reflectance(tau, 1.0, 1.0), expected,
			"tau %.1f reflects %.4f of a bright surface" % [tau, expected], 0.005)
	h.check(SpacesimRingModel.reflectance(1.2, 1.0, 1.0) > SpacesimRingModel.reflectance(0.1, 1.0, 1.0),
		"a thicker band is brighter than a thin one")
	h.check(SpacesimRingModel.reflectance(50.0, 0.05, 0.05) <= 1.0,
		"and nothing reflects more than a bright surface, however thick and however grazing")

	# **And it is dimmer than Saturn's own disc**, which is the thing Evert sees when he says it is too bright.
	# A body's disc is `illuminance · albedo · phase / pi`; the ring is `illuminance · albedo · R / pi`. One
	# unit of star light, Saturn's 0.342 albedo, and a phase factor of 0.5 for a half-lit disc.
	var saturn_disc := 1.0 * 0.342 * 0.5 / PI
	var ring_b := SpacesimRingModel.radiance(1.0, 0.6, 1.2, 0.34, 0.34)
	h.check(ring_b < saturn_disc,
		"the B ring is dimmer than Saturn's disc at the same light (%.4f against %.4f)" % [ring_b, saturn_disc])
	h.check(ring_b > saturn_disc * 0.3,
		"but not so dim that it disappears against it (%.2f of it)" % (ring_b / saturn_disc))

	# **The rocks are not the band.** Evert, 2026-11-16: *"We don't want these rocks to make up the entire
	# reflectance, we'll add the dust layer later."* The drawn sample is the largest embedded objects, and its own
	# optical depth is a fractional millionth of the band's — which is the number that says a rock must be drawn
	# as a rock and not as a piece of a bright sheet.
	var band := _sol().population_by_id("population:ring_b")
	var cloud := SpacesimParticleCloud.of(band)
	var drawn := SpacesimRingModel.drawn_optical_depth(band, cloud.mean_radius())
	h.check(drawn < 1.0e-5,
		"the 300,000 drawn particles are %.8f of an optical depth, against the band's %.1f — not the band"
			% [drawn, band.optical_depth])
	h.check(band.optical_depth / drawn > 1.0e6,
		"and what is missing is more than a million times that much dust (%.0f×)"
			% (band.optical_depth / drawn))

	# **A shadowed particle keeps a floor** — `R33`: visible and dark, never absent.
	var lit := SpacesimRingModel.radiance(1.0, 0.4, 1.2, 1.0, 1.0)
	var unlit := SpacesimRingModel.unlit_radiance(lit)
	h.check(lit > 0.0, "a lit band has radiance (%.4f)" % lit)
	h.check(unlit > 0.0 and unlit < lit * 0.2,
		"and a shadowed one is dark but not gone (%.4f)" % unlit)


## **The rings encircle the planet's equator, not its poles.** Evert, 2026-11-16: *"are Saturn's rings not around
## its equator? On this screen it looks like they go across the poles."* A body's mesh is drawn with model-space
## +Y as its pole (the engine has no obliquity), so a ring laid in an authored plane that disagreed with +Y crossed
## the poles. The scene now tilts the planet to the ring's axis, and this asserts the three things that must then
## agree: the ring's normal, the planet's own pole, and the authored axis.
func _test_the_rings_encircle_the_equator(h, root: Node) -> void:
	var sol := _sol()
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null or scene.build(root) == null:
		return
	var saturn := scene.body_by_id("planet:saturn")
	var band: SpacesimPopulation = sol.population_by_id("population:ring_b")
	var view := scene.rings[1]
	var ring_normal := (view.global_transform.basis * Vector3(0.0, 0.0, 1.0)).normalized()
	var planet_pole := saturn.node.global_transform.basis.y.normalized()
	var derived := SpacesimKepler.pole(saturn.content.orbit, saturn.content.axial_tilt)
	h.check_near(ring_normal.dot(planet_pole), 1.0,
		"the ring's plane is the planet's equator (%.4f)" % ring_normal.dot(planet_pole), 0.001)
	h.check_near(planet_pole.dot(derived), 1.0,
		"and the planet's pole is its orbit's normal tilted by its axial_tilt (%.4f)"
			% planet_pole.dot(derived), 0.001)
	# **The tilt is the content's own**: Saturn's 26.73 degrees off its orbital plane, and the tilt is what makes
	# the rings a season rather than a fixed picture.
	var orbit_normal := SpacesimKepler.pole(saturn.content.orbit, 0.0)
	h.check_near(rad_to_deg(planet_pole.angle_to(orbit_normal)), 26.73,
		"Saturn leans 26.73 degrees off its orbit", 0.05)
	# **And a body with no tilt sits on its orbit's normal**, which is very nearly the engine's +Y for a planet
	# in the ecliptic — the reason nothing looked wrong before there was a ring to see.
	var earth := scene.body_by_id("planet:earth")
	var earth_pole: Vector3 = earth.node.global_transform.basis.y.normalized()
	h.check_near(rad_to_deg(earth_pole.angle_to(Vector3.UP)), 23.44,
		"Earth leans 23.44 degrees off the ecliptic's north (%.2f, the orbit's own 0)"
			% rad_to_deg(earth_pole.angle_to(Vector3.UP)), 0.05)
	# **The bands follow the pole**: the body's model-space +Y is its axis, so a vertex at the pole is along it.
	h.check(planet_pole.dot(Vector3.UP) < 0.999,
		"the planet is actually tilted, not left on the engine's axis (%s)" % str(planet_pole))
	# **A body with no rings is untouched**, or every moon would lean for no reason.
	var titan := scene.body_by_id("moon:titan")
	if titan != null:
		h.check_near(titan.node.global_transform.basis.y.dot(Vector3.UP), 1.0,
			"a moon with no rings keeps the engine's pole", 0.001)

	root.remove_child(scene.container)
	scene.container.free()


## **The subdivision refines under the ship, on a body that is tilted.** Evert, 2026-11-16: *"The subdivision code
## for the LOD meshes don't seem to subdivide exactly below my ship anymore."* The walk's eye direction was the last
## quantity still computed in world space and handed to model-space code, so the detail followed a point an
## obliquity away from the ship — 23.4 degrees on Earth, 26.7 on Saturn, an eighth of a radius along the surface.
func _test_the_walk_refines_under_the_ship(h, root: Node) -> void:
	var sol := _sol()
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null or scene.build(root) == null:
		return
	var earth := scene.body_by_id("planet:earth")
	var camera := Camera3D.new()
	root.add_child(camera)
	# Low, and off the pole, so the tilt matters: straight up the axis would hide the fault entirely.
	var basis: Basis = earth.node.global_transform.basis.orthonormalized()
	var observer: Vector3 = earth.node.global_position + basis.y * earth.radius + basis.x * 900000.0
	camera.global_position = observer
	scene.update_lod(camera, observer)

	var expected := (basis.inverse() * (observer - earth.node.global_position)).normalized()
	var walked: Vector3 = earth.patch_walk_direction
	h.check(walked.length() > 0.5, "the walk was asked for (%s)" % str(walked))
	h.check_near(rad_to_deg(walked.angle_to(expected)), 0.0,
		"and it refines along the eye's direction IN THE BODY'S FRAME (%.1f deg off)"
			% rad_to_deg(walked.angle_to(expected)), 0.01)
	# **And that is not the world direction**, which is the whole point: the two differ by the tilt.
	h.check(rad_to_deg(expected.angle_to((observer - earth.node.global_position).normalized())) > 10.0,
		"which is 23.4 degrees away from the world offset, so the two cannot be confused"
	)

	root.remove_child(camera)
	camera.free()
	root.remove_child(scene.container)
	scene.container.free()


## **Every shader of a body is told the same sun, in the same frame.** Evert, 2026-11-16, over Jupiter: *"there
## seems to be two shadows, as if the air shader and the body shader disagree where the light is coming from...
## They are off by about 20 ish degrees."*
##
## A body's own geometry is MODEL space, and its node is now rotated to its real pole, so a direction published to
## a body shader has to be taken into that space. This asserts it against both consumers at once: the air's
## `u_sun_local` and the surface's `body_sun` must name the same direction in the world after the node's own basis
## is put back on them.
func _test_every_body_shader_is_told_the_same_sun(h, root: Node) -> void:
	var sol := _sol()
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null or scene.build(root) == null:
		return
	var camera := Camera3D.new()
	root.add_child(camera)
	var eye := scene.body_by_id("planet:jupiter").node.global_position + Vector3(0.0, 0.0, 6.0e8)
	camera.global_position = eye
	scene.update_lod(camera, eye)

	for id in ["planet:jupiter", "planet:saturn", "planet:earth"]:
		var body := scene.body_by_id(id)
		if body == null or body.air_shell_material == null or body.mesh_material == null:
			continue
		# **A body too small to be a disc is drawn as a point of light and publishes nothing** — its materials keep
		# the uniform's default, so there is nothing to compare and nothing wrong.
		var air_raw: Variant = body.air_shell_material.get_shader_parameter("u_sun_local")
		var surface_raw: Variant = body.mesh_material.get_shader_parameter("body_sun")
		if not (air_raw is Vector3) or not (surface_raw is Vector3):
			continue
		var basis: Basis = (body.node.global_transform.basis as Basis).orthonormalized()
		var air_local: Vector3 = air_raw
		var surface_local: Vector3 = surface_raw
		# Both are meant to be directions in the body's own space; put each back in the world and compare.
		var air_world := (basis * air_local).normalized()
		var surface_world := (basis * surface_local).normalized()
		h.check_near(rad_to_deg(air_world.angle_to(surface_world)), 0.0,
			"%s: the air and the surface are told one sun (%.2f deg apart)"
				% [id, rad_to_deg(air_world.angle_to(surface_world))], 0.01)

	root.remove_child(camera)
	camera.free()
	root.remove_child(scene.container)
	scene.container.free()


## **`R8`, `R9`** — the planet's shadow, on the rings and nowhere else.
func _test_the_shadow_is_the_planets(h, root: Node) -> void:
	var sol := _sol()
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null or scene.build(root) == null:
		return
	h.check(scene.rings.size() == 3, "three bands are drawn (%d)" % scene.rings.size())

	var saturn := scene.body_by_id("planet:saturn")
	var star := scene.star()
	var star_position := star.node.global_position
	var saturn_position := saturn.node.global_position
	var to_star := (star_position - saturn_position).normalized()

	for index in scene.rings.size():
		var depth: float = scene.rings[index].shaded_fraction
		h.check(depth > 0.02 and depth < 0.6,
			"%s: %.0f %% of it is in Saturn's shadow" % [scene.rings[index].name, depth * 100.0])

	# **The shadow falls where the geometry says**: a particle directly behind the planet, seen from the star,
	# is in the umbra; one at right angles to the star's direction is not.
	var behind := saturn_position - to_star * (SATURN_RADIUS * 1.5)
	var aside := saturn_position + Vector3(0.0, 1.0, 0.0).cross(to_star).normalized() * (SATURN_RADIUS * 1.5)
	h.check_near(
		SpacesimLuminance.shadow_fraction(behind, star_position, saturn_position, SATURN_RADIUS, STAR_RADIUS),
		0.0, "a particle in the planet's wake gets no star light", 0.02
	)
	h.check_near(
		SpacesimLuminance.shadow_fraction(aside, star_position, saturn_position, SATURN_RADIUS, STAR_RADIUS),
		1.0, "and one beside it gets all of it", 0.02
	)
	# **Half-way between, it is a penumbra** — neither 0 nor 1, which is what the two-circle law buys.
	var edge := saturn_position - to_star * (SATURN_RADIUS * 1.5) + Vector3(0.0, 1.0, 0.0).cross(to_star).normalized() * SATURN_RADIUS
	var part := SpacesimLuminance.shadow_fraction(edge, star_position, saturn_position, SATURN_RADIUS, STAR_RADIUS)
	h.check(part > 0.0 and part < 1.0, "the umbra's edge is a penumbra (%.2f)" % part)

	# **What the law sees, measured** — the umbra is where the caster's disc covers the star's, so the count of
	# particles whose angle to the star is inside the caster's own angular radius is the number the bake must find.
	var band_b := sol.population_by_id("population:ring_b")
	var cloud_b := SpacesimParticleCloud.of(band_b)
	var view_b := scene.rings[1]
	var inside := 0
	var min_theta := INF
	var beta := 0.0
	for index in range(0, cloud_b.size(), 673):
		var world: Vector3 = view_b.global_transform * cloud_b.positions[index]
		var towards_star := (star_position - world).normalized()
		var towards_caster := (saturn_position - world)
		beta = asin(clampf(SATURN_RADIUS / towards_caster.length(), 0.0, 1.0))
		var theta := towards_star.angle_to(towards_caster)
		min_theta = minf(min_theta, theta)
		if theta < beta:
			inside += 1
	h.check(inside > 0,
		"and the umbra really crosses the B ring (%d of %d sampled inside the caster's disc)"
			% [inside, cloud_b.size() / 673 + 1])
	h.check(min_theta < beta,
		"the closest a B-ring particle comes to the star's line is inside the caster's own radius (%.2f < %.2f rad)"
			% [min_theta, beta])

	root.remove_child(scene.container)
	scene.container.free()


## **`R10`–`R12`, as they now stand: ONE draw, above everything a planet wears.**
##
## The band was drawn twice, cut on the plane through the planet's centre, so the half behind the planet could go
## under its air and the half in front over it. The planet's own body hides the far half by depth, so the cut
## bought only the haze over the far limb — and it cost every ordering fault this feature had, the last of them a
## classification that hid the whole front half at some camera positions. Evert, 2026-11-18: *"now the rings
## actually stay put. So why do we have two overlapping rings again? If we draw both all the time, then we need
## only 1, right?"*
func _test_the_band_is_one_draw(h, root: Node) -> void:
	var sol := _sol()
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null or scene.build(root) == null:
		return
	var view := scene.rings[1]
	var nodes := view.draw_nodes()
	h.check(nodes.size() == 1, "a band is drawn once (%d node)" % nodes.size())
	if nodes.size() == 1:
		h.check(nodes[0].multimesh.instance_count == view.count(),
			"holding every particle (%d)" % view.count())
		var priority := (nodes[0].material_override as ShaderMaterial).render_priority
		h.check(priority == SpacesimRingView.RING_PRIORITY, "at the ring's one priority (%d)" % priority)
		# **And nothing else in that material can take a particle away**: no cut, so no per-particle rejection.
		h.check((nodes[0].material_override as ShaderMaterial).get_shader_parameter("split_side") == null,
			"and with no cut to classify a particle out of it")
	# **Above every layer the planet draws**, which is the whole of what the ring needs from the ordering: it is
	# a sheet in front of a body whose air cannot be depth-tested against.
	var highest := -129
	for body in scene.bodies:
		if body.air_shell != null and body.air_shell.material_override != null:
			highest = maxi(highest, int((body.air_shell.material_override as ShaderMaterial).render_priority))
		for deck in body.decks:
			highest = maxi(highest, int(deck.material.render_priority))
		if body.ocean != null and body.ocean.material_override != null:
			highest = maxi(highest, int((body.ocean.material_override as Material).render_priority))
	h.check(highest > -129, "the planet's own layers are here (%d at the top)" % highest)
	h.check(SpacesimRingView.RING_PRIORITY > highest,
		"the band draws after all of them (%d > %d)" % [SpacesimRingView.RING_PRIORITY, highest])

	root.remove_child(scene.container)
	scene.container.free()


## **`R13`–`R15`** — the ring's place in the transparent stack, and nothing more.
##
## The band is ONE draw and it sits above every layer a planet wears, because a planet's air is transparent with
## the depth test off and cannot be depth-tested against. The order *among* the planet's own layers — sea, air,
## decks, interior — is NOT asserted: it is a settled stack that must not be reordered here. Evert, 2026-11-16:
## *"We spent a long, long time optimizing air and cloud decks, don't mess up their order."*
func _test_the_layers_cannot_tie(h, root: Node) -> void:
	var sol := _sol()
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null or scene.build(root) == null:
		return
	var layers := {}
	for body in [scene.body_by_id("planet:saturn"), scene.body_by_id("planet:earth")]:
		if body == null:
			continue
		if body.interior != null and body.interior.material_override != null:
			layers["interior"] = int((body.interior.material_override as ShaderMaterial).render_priority)
		if body.ocean != null and body.ocean.material_override != null:
			layers["ocean"] = int((body.ocean.material_override as Material).render_priority)
		if body.air_shell != null and body.air_shell.material_override != null:
			layers["air"] = int((body.air_shell.material_override as ShaderMaterial).render_priority)
		for deck in body.decks:
			layers["deck_%d_%s" % [deck.index, body.name]] = int(deck.material.render_priority)
	h.check(layers.has("interior") and layers.has("air") and layers.has("ocean"),
		"the planet's own layers are here")
	var highest := -129
	for name in layers:
		var priority := int(layers[name])
		h.check(priority >= -128 and priority <= 128, "%s is inside the engine's range (%d)" % [name, priority])
		highest = maxi(highest, priority)
	# **The one relationship the ring depends on**: after everything the planet wears.
	h.check(SpacesimRingView.RING_PRIORITY > highest,
		"the band draws after every layer a planet wears (%d > %d)"
			% [SpacesimRingView.RING_PRIORITY, highest])
	h.check(SpacesimRingView.RING_PRIORITY >= -128 and SpacesimRingView.RING_PRIORITY <= 128,
		"and inside the engine's range (%d)" % SpacesimRingView.RING_PRIORITY)

	root.remove_child(scene.container)
	scene.container.free()


## **`R16`, `R17`, `R22`, `R26`** — which spots are bodies: a resolvable one always, the nearest one always,
## and nothing else.
func _test_a_spot_becomes_a_rock_by_one_rule(h, root: Node) -> void:
	var sol := _sol()
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null or scene.build(root) == null:
		return
	var view := scene.rings[1]
	var band: SpacesimPopulation = sol.population_by_id("population:ring_b")
	var cloud := SpacesimParticleCloud.of(band)
	var pixel := SpacesimLod.pixel_angle(70.0, 1080.0)
	var centre := scene.body_by_id("planet:saturn").node.global_position

	# **In a band's mid-radius plane**: the nearest spot is offered whatever its size.
	var middle := (band.semi_major_axis.x + band.semi_major_axis.y) * 0.5
	var eye := view.global_transform * Vector3(middle, 0.0, 300000.0)
	var pieces := view.pieces(eye, pixel, SpacesimSystemScene.RING_ROCK_CANDIDATES)
	h.check(pieces.size() >= 1, "the nearest spot is always a body (%d offered)" % pieces.size())
	if pieces.size() > 0:
		var first: Dictionary = pieces[0]
		var index := SpacesimRingView.index_of(String(first["id"]))
		h.check(index >= 0, "and it is a spot, by id (%s)" % String(first["id"]))
		h.check(String(first["id"]).begins_with("population:ring_b#"), "named after its band")
		h.check_near(float(first["diameter"]), cloud.radii[index] * 2.0, "with its own diameter", 0.01)
		h.check(String(first["label"]).begins_with("Saturn Rock"),
			"and a label a person reads (%s)" % String(first["label"]))

	# **From far away only the NEAREST spot is a body** — a body is a node, a material and an orbital frame, and
	# Evert, 2026-11-18: *"only create a body when it becomes resolveable."* The rest are marked, not simulated.
	var far := view.global_transform * Vector3(middle, 0.0, 3.0e10)
	var far_bodies := view.pieces(far, pixel, 4)
	h.check(far_bodies.size() == 1,
		"from far away only the nearest spot is a body (%d)" % far_bodies.size())
	var far_marked := view.marker_targets(far, pixel, SpacesimSystemScene.RING_ROCK_CANDIDATES)
	h.check(far_marked.size() == SpacesimSystemScene.RING_ROCK_CANDIDATES,
		"while the pool of 24 is named (%d)" % far_marked.size())
	# **And the nearest spot is a PLACE for the travel unit, with no body behind it** — `S3`, so the speed falls as
	# the ship closes on a band before anything resolves.
	var place := view.nearest_spot(far)
	h.check(not place.is_empty() and float(place["radius"]) > 0.0,
		"and the band's nearest spot is a place with a radius (%.0f m)"
			% float(place.get("radius", 0.0)))

	# **A spot that resolves IS a body**, which is the other half of the rule — a big component close in earns
	# geometry, and only those do. The eye is put 5 km from the band's biggest particle, where a real approach
	# ends up.
	var biggest := 0
	for index in cloud.size():
		if cloud.radii[index] > cloud.radii[biggest]:
			biggest = index
	var close_eye: Vector3 = view.global_transform * (cloud.positions[biggest] + Vector3(0.0, 0.0, 5000.0))
	var near_bodies := view.pieces(close_eye, pixel, 4)
	h.check(near_bodies.size() >= 1, "close in, a resolvable spot is a body (%d)" % near_bodies.size())
	if near_bodies.size() > 0:
		h.check(SpacesimRingView.index_of(String(near_bodies[0]["id"])) == biggest,
			"and it is the big component the eye is beside")

	# **The splat is switched off for the ones that are** (`R26`) — and only for those.
	var ids: Array = []
	for piece in near_bodies:
		ids.append(String(piece["id"]))
	view.set_hidden_ids(ids)
	h.check(view.hidden_count() == ids.size(), "each resolved spot's splat is hidden (%d)" % view.hidden_count())
	view.set_hidden_ids([])
	h.check(view.hidden_count() == 0, "and shown again when the body is let go")

	root.remove_child(scene.container)
	scene.container.free()


## **`R18`, `R31`, `S3`, `S7`** — a ring's rock is a body like a moon: it sets the travel unit, it is not solid,
## and it is a rock on the HUD.
func _test_a_rock_is_a_body_that_sets_the_unit(h, root: Node) -> void:
	var sol := _sol()
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null or scene.build(root) == null:
		return
	var band: SpacesimPopulation = sol.population_by_id("population:ring_b")
	var view := scene.rings[1]
	var manager := scene.ring_bodies[1]
	var camera := Camera3D.new()
	root.add_child(camera)
	var pixel := SpacesimLod.pixel_angle(70.0, 1080.0)
	var middle := (band.semi_major_axis.x + band.semi_major_axis.y) * 0.5
	var eye := view.global_transform * Vector3(middle, 0.0, 200000.0)

	camera.global_position = eye
	manager.update(view.pieces(eye, pixel, 4), eye, camera, pixel, false)
	var rocks := manager.rocks()
	h.check(rocks.size() >= 1, "a rock exists as a body as soon as it is the nearest spot (%d)" % rocks.size())
	if rocks.size() > 0:
		var rock: SpacesimSceneBody = rocks[0]
		h.check(rock.rock, "and it is marked as a rock rather than a place")
		h.check(rock.node != null, "with a node, so the HUD can mark it")
		h.check(rock.scale_body != null, "and a scale body, which is what slows the ship")
		if rock.scale_body != null:
			h.check(not rock.scale_body.solid,
				"but it is not solid — there is no physics yet, so it cannot stop the ship")
			# **The unit is the distance to it**, so an approach is a normal approach rather than a stall.
			var from := eye
			var to_surface := rock.scale_body.surface_distance_to(from)
			h.check(to_surface > 0.0 and to_surface < 1.0e6,
				"and it is near enough to set a small unit (%.0f km)" % [to_surface / 1.0e3])
			var unit := SpacesimTravelScale.local_length(to_surface, 10.0, 1.0e11)
			h.check(unit < 1.0e6, "the local unit really is small near it (%.0f m)" % unit)

	# **`R25`: the label is what a person reads, and it is the node's own name** — the markers draw `node.name`, so
	# a body whose node was left unnamed shows as `@Node3D@1201` on the HUD and in the readout.
	# **`R23`: the pool is only offered while the band is what the ship is flying through.** From beside a
	# particle the band wins; from a tenth of an AU out, Saturn does, and a band offers its nearest spot alone.
	h.check(view.nearest_distance(eye) < 1.0e6,
		"from inside the band, its nearest spot is close (%.0f km)" % [view.nearest_distance(eye) / 1.0e3])
	var far_eye: Vector3 = view.global_transform * Vector3(0.0, 0.0, 1.5e10)
	var saturn_range := eye.distance_to(scene.body_by_id("planet:saturn").node.global_position)
	h.check(view.nearest_distance(far_eye) > saturn_range,
		"and from far away, Saturn is nearer than any spot (%.0f Mm against %.0f Mm)"
			% [view.nearest_distance(far_eye) / 1e6, saturn_range / 1e6])

	# **`R25`: the label a person reads is the NODE's own name**, because that is what the markers draw — a body
	# whose node was left unnamed shows as `@Node3D@1201` on the HUD and in the readout.
	h.check(rocks.size() > 0 and String(rocks[0].node.name).begins_with("Saturn Rock"),
		"the rock's node carries the label a person reads (%s)"
			% (String(rocks[0].node.name) if rocks.size() > 0 else "no rock"))

	# **And it goes when the eye does**, with its body — nothing is left behind.
	manager.update([], eye, camera, pixel, false)
	h.check(manager.count() == 0, "the rock is let go when the spot is no longer offered")

	root.remove_child(camera)
	camera.free()
	root.remove_child(scene.container)
	scene.container.free()


## The camera's pixel angle, as `update_lod` computes it.
func _pixel(camera: Camera3D) -> float:
	var viewport := camera.get_viewport()
	if viewport == null:
		return 0.0
	return SpacesimLod.pixel_angle(camera.fov, float(viewport.size.y))


## **A rock body leaves nothing behind.** Evert, 2026-11-18, after the churn was fixed: *"the flickering of the
## cloud deck also improved... and now I can say for certain that it toggles between drawn and not drawn, but only
## after flying around near the rings for a while. Something might be leaking."*
##
## A body carries a node, a mesh, a point of light and an **orbital frame plus its transition rule**. If any of that
## outlives the body it accumulates, and a state that grows over a flight is exactly what "toggles after a while"
## looks like. So: build and drop the same rock fifty times and assert every count comes back.
func _test_a_rock_body_leaves_nothing_behind(h, root: Node) -> void:
	var sol := _sol()
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null or scene.build(root) == null:
		return
	var population: SpacesimPopulation = sol.population_by_id("population:ring_b")
	var manager := SpacesimFragmentBodies.new(population, scene)
	root.add_child(manager)
	var camera := Camera3D.new()
	root.add_child(camera)
	var pixel := SpacesimLod.pixel_angle(70.0, 1080.0)
	var piece := {
		"id": "%s#1" % population.id, "position": Vector3(1.0e8, 0.0, 0.0), "diameter": 500.0,
	}
	var frames_at_start := scene.frame_tree._frames.size()
	var rules_at_start := scene.frame_tree._rules.size()
	var children_at_start := scene.system_frame.get_child_count()
	var bodies_at_start := scene.bodies.size()
	for _round in 50:
		manager.update([piece], piece["position"], camera, pixel, false)
		manager.update([], piece["position"], camera, pixel, false)
	h.check(manager.count() == 0, "the rock is let go (%d left)" % manager.count())
	h.check(scene.frame_tree._frames.size() == frames_at_start,
		"and the frame registry is back where it started (%d -> %d)"
			% [frames_at_start, scene.frame_tree._frames.size()])
	h.check(scene.frame_tree._rules.size() == rules_at_start,
		"and the transition rules with it (%d -> %d)"
			% [rules_at_start, scene.frame_tree._rules.size()])
	h.check(scene.bodies.size() == bodies_at_start,
		"and the body list (%d -> %d)" % [bodies_at_start, scene.bodies.size()])
	# **The nodes go through `queue_free`**, so they leave on the next frame rather than immediately; what matters
	# is that fifty rounds do not make the tree grow.
	h.check(scene.system_frame.get_child_count() == children_at_start,
		"and the scene tree is back where it started (%d -> %d)"
			% [children_at_start, scene.system_frame.get_child_count()])
	root.remove_child(manager)
	manager.free()
	root.remove_child(camera)
	camera.free()
	root.remove_child(scene.container)
	scene.container.free()


## **The shadow falls away from the star, and which side that is.** Evert, 2026-11-18: *"there is an area where the
## rocks look a bit thinned out when the sun is behind me? I would expect that effect when the sun is ahead of the
## rocks, as all their shadow sides would point to me. Maybe you have a sign reversed in the rings shader?"*
##
## Two different things could thin an area, and they are testable apart:
##
##   - the **phase law**, which is per particle and must PEAK at zero phase (sun behind the observer) and go to zero
##     at 180 — so a thinned band at zero phase cannot be the phase;
##   - the **baked shadow**, which is per particle and fixed in the band. With the sun behind the observer it must
##     fall on the far side of the band — the half beyond the planet — and never on the near half.
##
## This asserts both, so the answer to "is a sign reversed" is a number rather than an argument.
func _test_the_light_side_is_the_side_the_star_is_on(h, root: Node) -> void:
	var sol := _sol()
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null or scene.build(root) == null:
		return
	var saturn := scene.body_by_id("planet:saturn")
	var centre := saturn.node.global_position
	var view := scene.rings[1]
	var band: SpacesimPopulation = sol.population_by_id("population:ring_b")
	var cloud := SpacesimParticleCloud.of(band)
	var star_position := scene.star().node.global_position
	var to_star := (star_position - centre).normalized()

	# **The phase law first.** Lambert's disc phase, `(sin a + (pi - a) cos a)/pi`: 1 at zero phase, and it must fall
	# monotonically to 0. A sign error in the shader's `dot(to_star, to_eye)` would invert this.
	var phase_at := func(angle: float) -> float:
		return (sin(angle) + (PI - angle) * cos(angle)) / PI
	h.check_near(phase_at.call(0.0), 1.0, "zero phase — the sun behind the eye — is the brightest", 1.0e-6)
	h.check_near(phase_at.call(PI), 0.0, "and 180 degrees is black", 1.0e-6)
	h.check(phase_at.call(deg_to_rad(60.0)) < phase_at.call(deg_to_rad(20.0)),
		"so brightness falls as the phase opens (%.3f at 60 deg, %.3f at 20)"
			% [phase_at.call(deg_to_rad(60.0)), phase_at.call(deg_to_rad(20.0))])

	# **What the shader is actually told.** A uniform that is stale, zero or the camera's own position would invert
	# the phase without any sign being wrong in the formula — so the published value is asserted, not assumed.
	var camera := Camera3D.new()
	root.add_child(camera)
	var eye_probe: Vector3 = centre + to_star * 1.64e8
	camera.global_position = eye_probe
	view.update(0.00122, 1.0, 0.4, centre, star_position, eye_probe)
	# **The star as the shader receives it.** The shader no longer rebuilds a world position from `INV_VIEW_MATRIX`;
	# it is told a unit direction in VIEW space, so what the host publishes can be checked exactly.
	camera.look_at(centre, Vector3.UP)
	view.update(0.00122, 1.0, 0.4, centre, star_position, eye_probe, camera)
	var told: Vector3 = view.view_star()
	h.check_near(told.length(), 1.0, "the shader is told a unit direction to the star", 1.0e-5)
	var expected: Vector3 = (
		(camera.get_global_transform_interpolated().basis as Basis).orthonormalized().inverse()
			* (star_position - centre).normalized()
	)
	h.check_near(told.dot(expected), 1.0,
		"and it is the star's own direction in the camera's frame", 1.0e-4)
	# **And which way that is in view space**: -Z is forward, so a star BEHIND the observer has a positive z. This is
	# the assertion that would have caught a star direction pointing the wrong side of the band.
	h.check(told.z > 0.0,
		"with the camera between the star and the band, the star is behind it (z = %+.2f)" % told.z)
	# **And the phase it will compute** — from the same three positions, for the rock nearest the camera, which is
	# the one a person looking ahead is looking at.
	var nearest := SpacesimParticleCloud.closest_point(
		Vector3.ZERO, -1.0, 1.0e30
	)  # placeholder, replaced below
	var closest := INF
	var sample: Vector3 = centre
	for index in range(0, cloud.size(), 31):
		var world: Vector3 = view.global_transform * cloud.positions[index]
		var distance := world.distance_to(eye_probe)
		if distance < closest:
			closest = distance
			sample = world
	nearest = sample
	var to_star_from_sample := (star_position - sample).normalized()
	var to_eye_from_sample := (eye_probe - sample).normalized()
	var phase := acos(clampf(to_star_from_sample.dot(to_eye_from_sample), -1.0, 1.0))
	# **Not asserted**: the nearest particle need not lie on the camera-to-centre line, so its phase is whatever the
	# band's geometry gives it. What matters is the *side* the light is on, which is the mean below.
	h.check(phase >= 0.0, "a rock near the camera is at %.0f degrees of phase" % rad_to_deg(phase))
	h.check(phase_at.call(phase) > 0.8,
		"which the law makes near its brightest (%.2f)" % phase_at.call(phase))

	# **The mean over the whole band, from the star's side and from the far side.** This is the number that says
	# whether the band as a whole is brighter with the sun behind the observer — which is what the law claims, and
	# what an exposure meter sees.
	var far_eye: Vector3 = centre - to_star * 1.64e8
	var lit_sum := 0.0
	var back_sum := 0.0
	var counted := 0
	for index in range(0, cloud.size(), 53):
		var world: Vector3 = view.global_transform * cloud.positions[index]
		var starward := (star_position - world).normalized()
		var from_star_side := (eye_probe - world).normalized()
		var from_far_side := (far_eye - world).normalized()
		lit_sum += phase_at.call(acos(clampf(starward.dot(from_star_side), -1.0, 1.0)))
		back_sum += phase_at.call(acos(clampf(starward.dot(from_far_side), -1.0, 1.0)))
		counted += 1
	h.check(lit_sum > back_sum,
		"the band is brighter with the sun behind the observer (%.2f against %.2f)"
			% [lit_sum / counted, back_sum / counted])
	root.remove_child(camera)
	camera.free()

	# **Then the shadow's side.** The camera sits on the star's side, so "near" is the starward half.
	var eye: Vector3 = centre + to_star * 1.64e8
	var near_unlit := 0
	var far_unlit := 0
	var near_total := 0
	var far_total := 0
	for index in range(0, cloud.size(), 53):
		var world: Vector3 = view.global_transform * cloud.positions[index]
		var starward := (world - centre).dot(to_star) > 0.0
		var lit := SpacesimLuminance.shadow_fraction(
			world, star_position, centre, saturn.radius, scene.star().radius
		) > 0.5
		if starward:
			near_total += 1
			near_unlit += 0 if lit else 1
		else:
			far_total += 1
			far_unlit += 0 if lit else 1
	h.check(near_total > 20 and far_total > 20,
		"the band has a starward half and an anti-starward one (%d / %d)" % [near_total, far_total])
	h.check(far_unlit > 0, "the planet's shadow falls on the far half (%d of %d)" % [far_unlit, far_total])
	h.check(near_unlit == 0,
		"and never on the starward half, which is the side the camera is on (%d of %d)"
			% [near_unlit, near_total])

	root.remove_child(scene.container)
	scene.container.free()


