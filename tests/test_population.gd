extends RefCounted
## A population is a distribution, and the field makes fragments up out of it.
##
## The numbers here are Sol's own belt: 2.1 to 3.3 AU, 1.1 million fragments above 1 km, a 10 m
## floor. What the arithmetic should give is in `Asteroids and Rings Plan` — a density of about
## 8.6e-25 fragments per cubic metre, a mean spacing of about 105,000 km, and a field ball of about
## 188,000 km for two dozen fragments.

const AU := 1.495978707e11
## Sol's gravitational parameter, G(M_sun + m): a fragment's own mass is not worth adding.
const SUN_MU := 1.3271244e20


func run(h, root: Node) -> void:
	print("  populations")
	_test_the_arithmetic(h)
	_test_the_band(h)
	_test_validation(h)
	_test_the_field_fills_where_the_belt_is(h)
	_test_the_field_empties_away_from_the_belt(h)
	_test_a_fragment_does_not_move(h)
	_test_sizes_follow_the_power_law(h)
	_test_sol_authors_the_belt(h)
	_test_a_fragment_is_significant(h)
	_test_a_fragment_earns_its_shape(h)
	_test_the_belt_reaches_the_marker_pool(h, root)


func _belt() -> SpacesimPopulation:
	var population := SpacesimPopulation.new()
	population.id = "population:main_belt"
	population.parent_id = "star:sol"
	population.seed_value = 108
	population.semi_major_axis = Vector2(2.1 * AU, 3.3 * AU)
	population.inclination = Vector2(0.0, 20.0)
	population.reference_size = 1000.0
	population.count = 1100000
	population.size_index = 2.5
	population.size_floor = 10.0
	population.size_ceiling = 5.0e5
	return population


## The published figure is 1.1 million above 1 km; the number of *objects* is that scaled down to
## the size floor by the power law, and the density is that divided by the belt's own volume.
func _test_the_arithmetic(h) -> void:
	var belt := _belt()
	var addressable := SpacesimPopulationField.addressable_count(belt)
	h.check_near(addressable, 1.1e11, "1.1 million above 1 km becomes 1.1e11 above 10 m", 1.0e8)

	var volume := SpacesimPopulationField.volume_of(belt)
	# 4/3 pi sin(20 deg) (a_hi^3 - a_lo^3): a shell as thick as the inclination makes it.
	h.check_near(volume, 1.28e35, "the belt's volume", 1.0e33)

	var density := SpacesimPopulationField.density_of(belt)
	h.check_near(density, 8.6e-25, "fragments per cubic metre", 1.0e-26)

	var spacing := pow(1.0 / density, 1.0 / 3.0)
	h.check(spacing > 9.0e7 and spacing < 1.3e8, "the mean spacing is about 105,000 km")

	var ball := SpacesimPopulationField.spawn_radius_of(belt)
	h.check(ball > 1.7e8 and ball < 2.1e8, "two dozen fragments are expected within ~188,000 km")

	# The ball is by definition the radius that holds FIELD_COUNT fragments, so the density it is
	# derived from and the density it implies agree. A test that cannot fail is not a test, so this
	# one asks whether the two routes give the same number.
	var implied := SpacesimPopulationField.FIELD_COUNT / (4.0 / 3.0 * PI * pow(ball, 3.0))
	h.check_near(implied, density, "the ball holds exactly FIELD_COUNT at that density", 1.0e-26)


func _test_the_band(h) -> void:
	var belt := _belt()
	h.check(SpacesimPopulationField.in_band(belt, Vector3(2.5 * AU, 0.0, 0.0)), "2.5 AU on the plane is in the belt")
	h.check(not SpacesimPopulationField.in_band(belt, Vector3(1.0 * AU, 0.0, 0.0)), "1 AU is inside the inner edge")
	h.check(not SpacesimPopulationField.in_band(belt, Vector3(3.8 * AU, 0.0, 0.0)), "3.8 AU is outside the outer edge")
	# sin(20 deg) is 0.342, so a fragment at 2.5 AU reaches z = 1.28e11 m and no further. The radius
	# is measured to the fragment, so the point inside the band has to be placed at that radius.
	var band_radius := 2.5 * AU
	var high := band_radius * sin(deg_to_rad(20.0))
	var across := sqrt(band_radius * band_radius - high * high)
	h.check(SpacesimPopulationField.in_band(belt, Vector3(across, 0.0, high * 0.99)),
		"just inside the top of the band")
	h.check(not SpacesimPopulationField.in_band(belt, Vector3(across, 0.0, high * 1.01)),
		"just outside it")


func _test_validation(h) -> void:
	var system := _system_with(_belt())
	h.check(system.validate().is_empty(), "a sound population validates clean")

	_breaks(h, "a band that runs backwards",
		func(population: SpacesimPopulation) -> void:
			population.semi_major_axis = Vector2(3.3 * AU, 2.1 * AU))
	_breaks(h, "a band that starts inside the star",
		func(population: SpacesimPopulation) -> void:
			population.semi_major_axis = Vector2(1.0e8, 3.3 * AU))
	_breaks(h, "an inclination that runs backwards",
		func(population: SpacesimPopulation) -> void:
			population.inclination = Vector2(20.0, 5.0))
	_breaks(h, "no fragments at all",
		func(population: SpacesimPopulation) -> void:
			population.count = 0)
	_breaks(h, "a size floor above the ceiling",
		func(population: SpacesimPopulation) -> void:
			population.size_floor = 1.0e6)
	_breaks(h, "a composition that does not sum to 1",
		func(population: SpacesimPopulation) -> void:
			population.composition = {"carbonaceous": 0.5})


## Rebuild the system with one wrong field, and require that it is reported. **The report is the
## test**: a validator that silently repairs is the thing this suite exists to prevent.
func _breaks(h, what: String, spoil: Callable) -> void:
	var population := _belt()
	population.composition = {"carbonaceous": 1.0}
	spoil.call(population)
	h.check(not _system_with(population).validate().is_empty(), "rejected: %s" % what)


func _system_with(population: SpacesimPopulation) -> SpacesimSolarSystem:
	var system := SpacesimSolarSystem.new()
	var star := SpacesimSystemBody.new()
	star.id = "star:sol"
	star.display_name = "Sol"
	star.kind = SpacesimSystemBody.Kind.STAR
	star.primary = true
	star.radius = 6.957e8
	star.mass = 1.989e30
	system.bodies.append(star)
	system.populations.append(population)
	return system


## At 2.5 AU the field has to fill, every fragment has to be in the band, and the distances have to be
## the population's rather than the field's own choice.
func _test_the_field_fills_where_the_belt_is(h) -> void:
	var field := SpacesimPopulationField.new(_belt())
	var ship := Vector3(2.5 * AU, 0.0, 0.0)
	field.update(Vector3.ZERO, SUN_MU, ship, 0.0)

	var fragments := field.fragments()
	h.check(fragments.size() == SpacesimPopulationField.FIELD_COUNT,
		"the field fills inside the belt (%d fragments)" % fragments.size())

	var reach := SpacesimPopulationField.spawn_radius_of(_belt())
	var nearest := INF
	var worst := 0.0
	var all_in_band := true
	for fragment in fragments:
		var where := field.position_of(fragment, Vector3.ZERO)
		var distance := where.distance_to(ship)
		nearest = minf(nearest, distance)
		worst = maxf(worst, distance)
		all_in_band = all_in_band and SpacesimPopulationField.in_band(_belt(), where)
	h.check(all_in_band, "every fragment is inside the band")
	h.check(worst <= reach + 1.0, "no fragment is outside the ball the field draws in")
	h.check(nearest < reach * 0.6, "the nearest is well inside it (%.0f km)" % (nearest / 1.0e3))
	h.check(nearest > 1.0e7, "and far enough that it is not on top of the ship")

## One AU from the Sun is Earth: outside the band, so the population has nothing there and the field
## says so rather than inventing a belt.
func _test_the_field_empties_away_from_the_belt(h) -> void:
	var field := SpacesimPopulationField.new(_belt())
	field.update(Vector3.ZERO, SUN_MU, Vector3(AU, 0.0, 0.0), 0.0)
	h.check(field.fragments().is_empty(), "no fragments at 1 AU")


## **Nothing moves yet, and the orbit is known anyway** — the same arrangement the planets and moons
## have. Evert, 2026-11-14: *"in theory we know which direction and speed they will be traveling in, but
## for simplicity's sake nothing is moving yet."*
##
## So there are two halves to check: the position does not change, and the motion that is *known* is the
## right one, waiting to be applied.
func _test_a_fragment_does_not_move(h) -> void:
	var field := SpacesimPopulationField.new(_belt())
	var ship := Vector3(2.5 * AU, 0.0, 0.0)
	field.update(Vector3.ZERO, SUN_MU, ship, 0.0)
	var fragment: SpacesimPopulationField.Fragment = field.fragments()[0]
	var start := field.position_of(fragment, Vector3.ZERO)

	# A minute of the tick, five times over, and the rock is where it was.
	for _step in 300:
		field.update(Vector3.ZERO, SUN_MU, ship, 1.0)
	h.check_vector_near(field.position_of(fragment, Vector3.ZERO), start,
		"a fragment does not move across five minutes of ticks", 1.0e-6)

	# **The motion it will have is still the right one**: a circular orbit at its radius, in the parent's
	# field. Asserted so that the knowledge cannot rot while nothing uses it.
	var rate := sqrt(SUN_MU / pow(fragment.radius, 3.0))
	h.check_near(fragment.rate, rate, "its rate is the circular one for its radius", 1.0e-15)
	h.check_near(fragment.velocity().length(), rate * fragment.radius,
		"and its speed is rate x radius", 1.0e-6)
	h.check(fragment.velocity().dot(fragment.u) < 1.0e-6,
		"travelling across the radius, not along it")
	h.check(fragment.velocity().length() > 1.0e3,
		"which at 2.5 AU is kilometres per second, not metres")

## N(>D) ~ D^-2.5, so a 10 m floor makes almost everything 10 to 20 metres across. That is what the
## real size distribution says, and the field has to draw from it rather than around it.
func _test_sizes_follow_the_power_law(h) -> void:
	var field := SpacesimPopulationField.new(_belt())
	field.update(Vector3.ZERO, SUN_MU, Vector3(2.5 * AU, 0.0, 0.0), 0.0)
	var small := 0
	for fragment in field.fragments():
		h.check(fragment.diameter >= 10.0 and fragment.diameter <= 5.0e5,
			"%s is between the floor and the ceiling" % fragment.designation)
		if fragment.diameter < 20.0:
			small += 1
	# The median of u^-0.4 is 1.32, so half of the draws are under 13.2 m and nearly all are
	# under 20: a field where most fragments are metres-scale is the distribution working.
	h.check(small > SpacesimPopulationField.FIELD_COUNT / 2,
		"most fragments are under 20 m (%d of %d)" % [small, field.fragments().size()])


func _test_sol_authors_the_belt(h) -> void:
	var sol: SpacesimSolarSystem = load("res://systems/sol.tres")
	h.check(sol != null, "the Sol system loads")
	if sol == null:
		return
	var belt := sol.population_by_id("population:main_belt")
	h.check(belt != null, "Sol authors the main belt")
	if belt == null:
		return
	h.check(belt.parent_id == "star:sol", "and it orbits the star")
	h.check_near(belt.semi_major_axis.x, 2.1 * AU, "its inner edge is 2.1 AU", 1.0e6)
	h.check_near(belt.semi_major_axis.y, 3.3 * AU, "its outer edge is 3.3 AU", 1.0e6)
	h.check(SpacesimPopulationField.density_of(belt) > 0.0, "and it has a density")


## **A fragment is significant from the moment it exists** — it sets the local travel unit, so it has to
## be a scale body the ship's own proximity scan can see. It has no node at all, which is the half of
## `SpacesimScaleBody` this adds.
func _test_a_fragment_is_significant(h) -> void:
	var rock := SpacesimScaleBody.new(null, 5.0)
	rock.position = Vector3(1000.0, 0.0, 0.0)
	rock.name = "A-0007"
	h.check_near(rock.surface_distance_to(Vector3.ZERO), 995.0,
		"a scale body with no node answers its distance", 1.0e-6)
	h.check_near(rock.surface_distance_mesh(Vector3.ZERO), 995.0,
		"and its altitude, without a mesh to ask", 1.0e-6)

	var planet := SpacesimScaleBody.new(null, 6.371e6)
	planet.position = Vector3(1.0e11, 0.0, 0.0)
	var bodies: Array[SpacesimScaleBody] = [planet, rock]
	h.check(SpacesimProximity.nearest_body(Vector3.ZERO, bodies) == rock,
		"the rock is nearest even though the planet is a place")
	h.check_near(SpacesimProximity.nearest_surface_distance(Vector3.ZERO, bodies), 995.0,
		"and the nearest surface is the rock's", 1.0e-6)

	# **The unit is the rock's, not the planet's**, which is what makes full throttle drop as the belt is
	# entered rather than only once the ship is on top of something. 1e11 m to 995 m is eight orders.
	var band := Vector2(1.0, 1.0e11)
	var near_unit := SpacesimTravelScale.local_length(995.0, band.x, band.y)
	var far_unit := SpacesimTravelScale.local_length(1.0e11 - 6.371e6, band.x, band.y)
	h.check(near_unit < far_unit / 1.0e6,
		"the rock's unit is orders below the planet's (%s against %s)"
			% [String.num(near_unit), String.num(far_unit)])


## **A rock has no geometry until the eye can resolve one.** Four pixels is where a shape is worth
## extracting, and a fragment of diameter d is one pixel across at 900 d.
func _test_a_fragment_earns_its_shape(h) -> void:
	h.check_near(SpacesimFragmentRenderer.resolve_distance(100.0), 22500.0,
		"a 100 m fragment earns its shape inside 22.5 km", 1.0e-6)
	h.check_near(SpacesimFragmentRenderer.resolve_distance(10.0), 2250.0,
		"and a 10 m one inside 2.25 km", 1.0e-6)

	var material := SpacesimFragmentRenderer.material_for(_belt_with_composition())
	h.check(material.roughness == 1.0 and material.metallic_specular == 0.0,
		"a rock scatters rather than reading as glass")
	h.check(material.albedo_color.is_equal_approx(Color(0.18, 0.16, 0.15)),
		"and is the colour of what it is mostly made of")


func _belt_with_composition() -> SpacesimPopulation:
	var belt := _belt()
	belt.composition = {"carbonaceous": 0.75, "iron": 0.08, "silicate": 0.17}
	return belt


## **Evert's flight, reproduced headlessly.** Fly from Phobos towards Jupiter: the ship slows down, *Closest*
## reads an asteroid, and **no asteroid markers appear**.
##
## Sol has 40 significant bodies — nine places at `PRIMARY` and thirty-one moons at `CONTEXT`, every one of
## them a candidate at any distance — so a 24-slot pool was filled before a fragment was ever considered.
## The gathering and the drawing were both right; the tier ordering was not. This builds the real scene, the
## real field and the real 40 candidates, so the next regression of it fails here rather than in flight.
func _test_the_belt_reaches_the_marker_pool(h, root: Node) -> void:
	var sol: SpacesimSolarSystem = load("res://systems/sol.tres")
	var scene := SpacesimSystemScene.from_content(sol)
	h.check(scene != null, "the Sol scene wraps the content")
	if scene == null:
		return
	scene.build(root)

	var belt := sol.population_by_id("population:main_belt")
	var field := SpacesimPopulationField.new(belt)
	var ship := Vector3(2.5 * AU, 0.0, 0.0)
	field.update(Vector3.ZERO, SUN_MU, ship, 0.0)
	h.check(field.fragments().size() == SpacesimPopulationField.FIELD_COUNT,
		"the field is full at 2.5 AU (%d fragments)" % field.fragments().size())

	var markers := SpacesimMarkers.new()
	root.add_child(markers)
	markers.orbits = scene.orbit_parents()
	markers.context_targets = scene.significant_nodes()

	var targets: Array[Dictionary] = []
	for slot in field.fragments().size():
		var fragment: SpacesimPopulationField.Fragment = field.fragments()[slot]
		targets.append({
			"id": -(slot + 1),
			"position": field.position_of(fragment, Vector3.ZERO),
			"text": fragment.designation,
			"priority": SpacesimMarkers.Priority.ASTEROID,
			"parent": SpacesimMarkers.NO_PARENT,
			"ring": false,
		})
	markers.targets = targets

	var gathered := markers._candidates(ship)
	h.check(gathered.size() > 24, "a whole system is more candidates than the pool holds (%d)" % gathered.size())

	var chosen := SpacesimMarkers.choose(gathered, 24)
	var places := 0
	var moons := 0
	var rocks := 0
	for entry in chosen:
		match int(entry["priority"]):
			SpacesimMarkers.Priority.PRIMARY:
				places += 1
			SpacesimMarkers.Priority.CONTEXT:
				moons += 1
			SpacesimMarkers.Priority.ASTEROID:
				rocks += 1
	h.check(places == 9, "all nine places are marked (%d)" % places)
	h.check(rocks > 0, "**the belt reaches the pool** (%d rocks)" % rocks)
	h.check(rocks + moons + places == 24, "and the rest of the pool is a choice between moons and rocks")
	root.remove_child(markers)
	markers.free()
