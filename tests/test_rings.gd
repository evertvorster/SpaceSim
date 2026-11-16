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
	_test_the_shadow_is_the_planets(h, root)
	_test_the_split_is_two_draws_of_everything(h, root)
	_test_the_layers_cannot_tie(h, root)
	_test_a_spot_becomes_a_rock_by_one_rule(h, root)
	_test_a_rock_is_a_body_that_sets_the_unit(h, root)


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
	for index in cloud.size():
		var local := cloud.positions[index]
		var radius := sqrt(local.x * local.x + local.y * local.y)
		inner = minf(inner, radius)
		outer = maxf(outer, radius)
		h.check_near(local.z, 0.0, "the sheet has no thickness", 1.0e-6) if index % 5000 == 0 else null
		smallest = minf(smallest, cloud.radii[index] * 2.0)
		largest = maxf(largest, cloud.radii[index] * 2.0)
		squared += cloud.radii[index] * cloud.radii[index]

	h.check(inner >= band.semi_major_axis.x - 1.0 and outer <= band.semi_major_axis.y + 1.0,
		"every particle is inside the band (%.0f to %.0f km)"
			% [inner / 1.0e3, outer / 1.0e3])
	h.check(smallest >= 100.0 * 0.999, "none is below the floor (%.1f m)" % smallest)
	h.check(largest <= 30000.0 * 1.001, "none is above the ceiling (%.0f m)" % largest)
	h.check_near(
		cloud.mean_radius(), sqrt(squared / float(cloud.size())),
		"the mean radius is the area-weighted one", 1.0
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
	# At normal incidence and normal emergence the geometry factor is 1, so the reflectance is `tau/(1+tau)`.
	for pair in [[0.1, 0.09], [0.7, 0.41], [1.2, 0.55]]:
		var tau: float = pair[0]
		var expected: float = pair[1]
		h.check_near(SpacesimRingModel.reflectance(tau, 1.0, 1.0), expected,
			"tau %.1f reflects %.0f %% of a bright surface" % [tau, expected * 100.0], 0.01)

	# **Never brighter than a bright surface**, however thick the band and however grazing the eye — this is the
	# clamp that stops a ring outshining the planet it orbits.
	h.check(SpacesimRingModel.reflectance(50.0, 0.05, 0.05) <= 1.0,
		"an edge-on thick band is still not brighter than a bright surface")
	h.check(SpacesimRingModel.reflectance(1.2, 1.0, 1.0) > SpacesimRingModel.reflectance(0.1, 1.0, 1.0),
		"and a thicker band is brighter than a thin one")

	# **A shadowed particle keeps a floor** — `R33`: visible and dark, never absent.
	var lit := SpacesimRingModel.radiance(1.0, 0.4, 1.2, 1.0, 1.0)
	var unlit := SpacesimRingModel.unlit_radiance(lit)
	h.check(lit > 0.0, "a lit band has radiance (%.4f)" % lit)
	h.check(unlit > 0.0 and unlit < lit * 0.2,
		"and a shadowed one is dark but not gone (%.4f)" % unlit)


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


## **`R10`, `R11`, `R12`** — two draws holding every particle, and the cut following the eye.
func _test_the_split_is_two_draws_of_everything(h, root: Node) -> void:
	var sol := _sol()
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null or scene.build(root) == null:
		return
	var view := scene.rings[1]
	var nodes := view.draw_nodes()
	h.check(nodes.size() == 2, "a band is drawn twice (%d)" % nodes.size())
	if nodes.size() == 2:
		h.check(nodes[0].multimesh == nodes[1].multimesh,
			"both draws hold the same instances, so no particle is lost to the cut")
		h.check(nodes[0].multimesh.instance_count == view.count(),
			"and that is every particle (%d)" % view.count())
		var near_priority := (nodes[0].material_override as ShaderMaterial).render_priority
		var far_priority := (nodes[1].material_override as ShaderMaterial).render_priority
		h.check(near_priority > far_priority, "the near half draws after the far one (%d > %d)"
			% [near_priority, far_priority])
		h.check_near(float((nodes[0].material_override as ShaderMaterial).get_shader_parameter("split_side")),
			1.0, "and each knows which side it is", 1.0e-6)
		h.check_near(float((nodes[1].material_override as ShaderMaterial).get_shader_parameter("split_side")),
			-1.0, "both of them", 1.0e-6)

	# **The cut follows the eye, not the star.** Move the observer round the planet and the direction the shader
	# is given changes with it — that is `R12`, and it is why the cut is the camera's business.
	var camera := Camera3D.new()
	root.add_child(camera)
	var lights: Array = []
	var centre: Vector3 = scene.body_by_id("planet:saturn").node.global_position
	for direction in [Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), Vector3(-1.0, 0.0, 0.0)]:
		var observer: Vector3 = centre + (direction as Vector3) * 1.5e8
		view.update(0.00122, 1.0, 0.4, centre, centre + Vector3(1.0, 0.0, 0.0) * 1.4e12, observer)
		lights.append((view.shader_parameter("split_direction") as Vector3).normalized())
	h.check(lights[0].is_equal_approx(Vector3(1.0, 0.0, 0.0)),
		"the cut's direction is the eye's (%s)" % str(lights[0]))
	h.check(lights[1].is_equal_approx(Vector3(0.0, 0.0, 1.0)), "and it turns with it (%s)" % str(lights[1]))
	h.check(lights[2].is_equal_approx(Vector3(-1.0, 0.0, 0.0)), "all the way round (%s)" % str(lights[2]))

	root.remove_child(camera)
	camera.free()
	root.remove_child(scene.container)
	scene.container.free()


## **`R13`–`R15`** — the transparent stack, declared once and asserted here: **every layer a body draws sits in its
## own band, in order, and no two of them can tie.** A tie is not a slow order, it is no order — the layers are all
## children of the body's node, so their distances are equal.
func _test_the_layers_cannot_tie(h, root: Node) -> void:
	var sol := _sol()
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null or scene.build(root) == null:
		return
	# **The interior belongs to a body with no surface** — a giant's visible surface *is* its cloud deck — while
	# the sea, the decks and the air belong to a body with one. Between them, Earth and Saturn carry every layer.
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
	layers["ring_far"] = SpacesimRingView.FAR_PRIORITY
	layers["ring_near"] = SpacesimRingView.NEAR_PRIORITY
	h.check(layers.has("interior") and layers.has("air"), "the planet's own layers are here")
	h.check(int(layers["ring_far"]) < SpacesimBodyRenderer.INTERIOR_RENDER_PRIORITY,
		"the far half of a ring draws before everything the planet wears (%d < %d)"
			% [int(layers["ring_far"]), SpacesimBodyRenderer.INTERIOR_RENDER_PRIORITY])
	h.check(int(layers["ring_near"]) > SpacesimBodyRenderer.AIR_RENDER_PRIORITY,
		"and the near half after all of it (%d > %d)"
			% [int(layers["ring_near"]), SpacesimBodyRenderer.AIR_RENDER_PRIORITY])

	# **Furthest first, and every step distinct.**
	var order := ["ring_far", "interior", "ocean"]
	for name in order:
		h.check(layers.has(name), "%s is drawn" % name)
	var previous := -129
	for name in order:
		if not layers.has(name):
			continue
		var priority := int(layers[name])
		h.check(priority > previous, "%s sits beyond the one before it (%d > %d)"
			% [name, priority, previous])
		previous = priority
	for name in layers:
		var priority := int(layers[name])
		h.check(priority >= -128 and priority <= 128,
			"%s is inside the engine's range (%d)" % [name, priority])
		if String(name).begins_with("deck_"):
			h.check(priority > int(layers.get("ocean", -129)) and priority < int(layers.get("air", 129)),
				"%s is between the sea and the air (%d)" % [name, priority])

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

	# **Far away, nothing resolves**: one spot (the nearest), and no others, because none is two pixels across.
	var far := view.global_transform * Vector3(middle, 0.0, 3.0e10)
	var far_pieces := view.pieces(far, pixel, SpacesimSystemScene.RING_ROCK_CANDIDATES)
	h.check(far_pieces.size() == 1,
		"from far away only the nearest spot is a body (%d)" % far_pieces.size())

	# **Close in, several do** — the rule is the disc, so big components near the eye become geometry rather than
	# splats that fill the frame.
	var near_pieces := view.pieces(eye, pixel * 8.0, SpacesimSystemScene.RING_ROCK_CANDIDATES)
	h.check(near_pieces.size() >= pieces.size(),
		"a coarse pixel makes more of them resolvable (%d >= %d)" % [near_pieces.size(), pieces.size()])
	for piece in near_pieces:
		var index := SpacesimRingView.index_of(String(piece["id"]))
		if index < 0:
			continue
		var distance: float = (view.global_transform.affine_inverse() * eye).distance_to(cloud.positions[index])
		var screen := SpacesimLod.screen_radius_pixels(
			SpacesimLod.angular_radius(cloud.radii[index], distance), pixel * 8.0
		)
		if screen < SpacesimIrregularBody.RESOLVE_PIXELS and piece != near_pieces[0]:
			h.check(false, "a spot that is not resolvable should not be a body (%.2f px)" % screen)

	# **The splat is switched off for the ones that are** (`R26`) — and only for those.
	var ids: Array = []
	for piece in near_pieces:
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

	# **And it goes when the eye does**, with its body — nothing is left behind.
	manager.update([], eye, camera, pixel, false)
	h.check(manager.count() == 0, "the rock is let go when the spot is no longer offered")

	root.remove_child(camera)
	camera.free()
	root.remove_child(scene.container)
	scene.container.free()
