extends RefCounted
## The travel unit: how close the nearest significant thing is decides how fast you move.

const TravelScale := preload("res://addons/spacesim/travel/travel_scale.gd")
const Proximity := preload("res://addons/spacesim/travel/proximity.gd")
const ScaleBody := preload("res://addons/spacesim/travel/scale_body.gd")

const BAND_MIN := 1.0e3
const BAND_MAX := 1.0e9
const T := TravelScale.TRAVERSE_SECONDS


func run(h, root: Node) -> void:
	print("  travel unit")
	_test_band_clamps(h)
	_test_deep_space_is_the_largest_scale(h)
	_test_throttle_is_a_fraction(h)
	_test_closer_is_slower(h)
	_test_stopping_gets_easier_as_you_close(h)
	_test_never_overshoots(h)
	_test_surface_distance_is_radius_aware(h, root)
	_test_nearest_of_several(h, root)
	_test_handover_is_continuous(h, root)
	_test_a_moving_target_is_reachable(h)
	_test_the_carried_motion_is_the_reference_s(h)


func _test_band_clamps(h) -> void:
	h.check_near(TravelScale.local_length(500.0, BAND_MIN, BAND_MAX), BAND_MIN, "below the band takes the floor", 1e-6)
	h.check_near(
		TravelScale.local_length(1.0e12, BAND_MIN, BAND_MAX), BAND_MAX, "above the band takes the ceiling", 1e-6
	)
	h.check_near(
		TravelScale.local_length(1.0e6, BAND_MIN, BAND_MAX), 1.0e6, "inside the band is the distance itself", 1e-6
	)


func _test_deep_space_is_the_largest_scale(h) -> void:
	# Nothing near enough to matter must read as the largest scale, never as zero.
	h.check_near(
		TravelScale.local_length(INF, BAND_MIN, BAND_MAX), BAND_MAX, "deep space is the largest scale", 1e-6
	)


func _test_throttle_is_a_fraction(h) -> void:
	h.check_near(TravelScale.speed_for(0.0, 1.0e6, BAND_MIN, BAND_MAX), 0.0, "zero throttle is stationary", 1e-9)
	h.check_near(
		TravelScale.speed_for(0.5, 1.0e6, BAND_MIN, BAND_MAX),
		0.5 * 1.0e6 / T,
		"half throttle is half the neighbourhood per traversal",
		1e-6
	)
	h.check_near(
		TravelScale.speed_for(2.0, 1.0e6, BAND_MIN, BAND_MAX),
		1.0e6 / T,
		"throttle clamps to full",
		1e-6
	)


func _test_closer_is_slower(h) -> void:
	var far := TravelScale.speed_for(1.0, 1.0e7, BAND_MIN, BAND_MAX)
	var near := TravelScale.speed_for(1.0, 1.0e5, BAND_MIN, BAND_MAX)
	h.check(near < far, "the same throttle is slower near something than far from it")
	h.check_near(far / near, 100.0, "and slower in proportion to distance", 1e-6)


func _test_stopping_gets_easier_as_you_close(h) -> void:
	# Following the unit at full throttle means the speed falls as d/T, so the deceleration
	# it demands is d/T^2 -- which shrinks as you close. Being able to stop is therefore a
	# property of the unit, not a separate braking calculation.
	var far := TravelScale.speed_for(1.0, 1.0e6, BAND_MIN, BAND_MAX) / T
	var mid := TravelScale.speed_for(1.0, 1.0e5, BAND_MIN, BAND_MAX) / T
	var near := TravelScale.speed_for(1.0, 1.0e4, BAND_MIN, BAND_MAX) / T
	h.check(far > mid and mid > near, "required deceleration falls as you close on something")
	h.check(far / near >= 100.0, "and falls by orders of magnitude by the time you are close")


func _test_never_overshoots(h) -> void:
	# Straight in at full throttle: the distance must fall monotonically and arrive, never
	# pass through. This is the whole claim of the unit, as a test.
	const STEP := 1.0 / 60.0
	var distance := 1.0e7
	var steps := 0
	var arrived := false
	var monotonic := true
	var previous := distance

	while steps < 200000:
		var speed := TravelScale.speed_for(1.0, distance, BAND_MIN, BAND_MAX)
		distance -= speed * STEP
		if distance > previous:
			monotonic = false
		previous = distance
		steps += 1
		if distance <= 1.0:
			arrived = true
			break

	h.check(distance > -1e-3, "the approach never passes through the target")
	h.check(monotonic, "the approach is monotonic")
	h.check(arrived, "and it arrives at full throttle without braking logic")


func _test_surface_distance_is_radius_aware(h, root: Node) -> void:
	const RADIUS := 6.371e6
	var container := Node3D.new()
	root.add_child(container)
	var planet := Node3D.new()
	container.add_child(planet)
	var body := ScaleBody.new(planet, RADIUS)

	h.check_near(body.surface_distance_to(Vector3.ZERO), 0.0, "at the centre reads as zero, not negative", 1e-6)
	h.check_near(
		body.surface_distance_to(Vector3(RADIUS, 0.0, 0.0)),
		0.0,
		"on the surface reads as zero",
		1e-6
	)
	h.check_near(
		body.surface_distance_to(Vector3(RADIUS + 1000.0, 0.0, 0.0)),
		1000.0,
		"altitude is measured to the surface, not the centre",
		1e-6
	)
	container.free()


func _test_nearest_of_several(h, root: Node) -> void:
	var container := Node3D.new()
	root.add_child(container)
	var far_node := Node3D.new()
	far_node.position = Vector3(1.0e6, 0.0, 0.0)
	container.add_child(far_node)
	var near_node := Node3D.new()
	near_node.position = Vector3(5000.0, 0.0, 0.0)
	container.add_child(near_node)

	var bodies: Array[SpacesimScaleBody] = [
		ScaleBody.new(far_node, 100.0),
		ScaleBody.new(near_node, 100.0),
	]
	var probe := Vector3.ZERO
	h.check_near(
		Proximity.nearest_surface_distance(probe, bodies), 4900.0, "the nearest surface wins, not the largest", 1e-6
	)
	var nearest := Proximity.nearest_body(probe, bodies)
	h.check(nearest != null and nearest.node == near_node, "and the nearest body is reported")

	var empty: Array[SpacesimScaleBody] = []
	h.check(
		is_inf(Proximity.nearest_surface_distance(probe, empty)),
		"nothing near enough reads as infinite distance, not zero"
	)
	container.free()


func _test_handover_is_continuous(h, root: Node) -> void:
	# A min over bodies is continuous, so handing over from one body to the next must not
	# lurch the unit. A body streaming in as nearest would break this; a hand-off cannot.
	var container := Node3D.new()
	root.add_child(container)
	var a := Node3D.new()
	container.add_child(a)
	var b := Node3D.new()
	b.position = Vector3(1000.0, 0.0, 0.0)
	container.add_child(b)

	var bodies: Array[SpacesimScaleBody] = [ScaleBody.new(a, 100.0), ScaleBody.new(b, 100.0)]

	var worst_distance_step := 0.0
	var worst_speed_step := 0.0
	var previous_distance := Proximity.nearest_surface_distance(Vector3(-500.0, 0.0, 0.0), bodies)
	var previous_speed := TravelScale.speed_for(1.0, previous_distance, 1.0, 1.0e5)
	var x := -500.0
	while x <= 1500.0:
		var distance := Proximity.nearest_surface_distance(Vector3(x, 0.0, 0.0), bodies)
		var speed := TravelScale.speed_for(1.0, distance, 1.0, 1.0e5)
		worst_distance_step = maxf(worst_distance_step, absf(distance - previous_distance))
		worst_speed_step = maxf(worst_speed_step, absf(speed - previous_speed))
		previous_distance = distance
		previous_speed = speed
		x += 1.0

	# 1 m of travel can change the distance by at most 1 m (slope <= 1), so a lurch would
	# show up as a step far larger than that.
	h.check(worst_distance_step <= 1.001, "handing over between bodies does not jump the distance")
	h.check(
		worst_speed_step <= 1.0 / T * 1.001, "and does not jump the travel unit"
	)
	container.free()


## **A target that moves is reachable only because the ship is carried by it.**
##
## Evert flew to the asteroid belt and could not catch a rock: the ship stalled about 188 km away and the
## rock ran. The arithmetic is that the closing speed is `distance / TRAVERSE_SECONDS`, and a fragment at
## 2.5 AU orbits at 18.8 km/s — so below 188 km the target is simply faster than the ship. Nothing about
## the unit is wrong; the world was assumed to stand still.
##
## This drives the real integration, one 1/60 s step at a time, from a start well outside the stall.
func _test_a_moving_target_is_reachable(h) -> void:
	var delta := 1.0 / 60.0
	var orbital_speed := 18800.0 # a fragment at 2.5 AU
	var start := Vector3(0.0, 0.0, 46.0e9)

	# **The ship aims at the target every step**, which is what a pilot does — a fixed heading overshoots
	# once the step can cover the remaining distance, and the loop then diverges for a reason that has
	# nothing to do with the model.
	var reached := _chase(start, orbital_speed, delta, true, 40000)
	h.check(reached < 1.0e5, "a carried ship arrives at a target moving at 18.8 km/s (%.0f m)" % reached)

	# **The same chase without the carried term is the bug**, and it must not arrive: that is what makes
	# the check above a measurement rather than a tautology. It stalls where the target outruns the ship.
	var stalled := _chase(start, orbital_speed, delta, false, 40000)
	h.check(stalled > 1.0e5, "and without it the ship stalls at %.0f km, which is the report" % (stalled / 1.0e3))


## Chase a target running away along +Z, and answer the distance it ends at.
func _chase(start: Vector3, target_speed: float, delta: float, carried: bool, steps: int) -> float:
	var ship := Vector3.ZERO
	var target := start
	for _step in steps:
		var distance: float = ship.distance_to(target)
		var aim: Vector3 = (target - ship) / maxf(distance, 1.0)
		var closing: Vector3 = aim * TravelScale.speed_for(1.0, distance, BAND_MIN, BAND_MAX)
		var reference := Vector3(0.0, 0.0, target_speed) if carried else Vector3.ZERO
		target += Vector3(0.0, 0.0, target_speed * delta)
		ship += TravelScale.carried_step(reference, closing, delta)
	return ship.distance_to(target)


## The step is the reference's motion **plus** the closing speed, and nothing else.
func _test_the_carried_motion_is_the_reference_s(h) -> void:
	var carried := Vector3(20.0, 0.0, 0.0)
	var closing := Vector3(0.0, 0.0, -30.0)
	h.check_vector_near(
		TravelScale.carried_step(carried, closing, 2.0), Vector3(40.0, 0.0, -60.0),
		"one step is carried plus closing, times the step", 1.0e-9
	)
	h.check_vector_near(
		TravelScale.carried_step(Vector3.ZERO, Vector3.ZERO, 2.0), Vector3.ZERO,
		"a ship near nothing and going nowhere does not move", 1.0e-9
	)
