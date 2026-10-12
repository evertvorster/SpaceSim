extends RefCounted
## Fly the demo world from space down to the planet's surface, headless.
##
## The engine's spatial-scale proof, driven to completion and asserted rather than
## eyeballed: the chain space -> atmosphere -> surface, no penetration, and the travel
## unit behaving the way the design claims.

const ScaleWorld := preload("res://demo/scale_world.gd")

const STEP := 1.0 / 60.0
const MAX_STEPS := 60000


func run(h, root: Node) -> void:
	print("  descend to the surface")
	var world := ScaleWorld.new().build(root)
	var ship = world["ship"]
	var tree = world["frame_tree"]
	var planet: Node3D = world["planet"]

	var visited := {}
	var lowest_altitude := INF
	var highest_speed := 0.0
	var lowest_speed := INF
	var length_never_rose := true
	var previous_length := INF
	var steps := 0
	var landed := false

	while steps < MAX_STEPS:
		ship.step(STEP, {"throttle": 1.0, "aim": planet.global_position})
		tree.evaluate()
		visited[tree.active_frame.name] = true

		lowest_altitude = minf(lowest_altitude, ship.altitude())
		highest_speed = maxf(highest_speed, ship.speed)
		if ship.speed > 0.0:
			lowest_speed = minf(lowest_speed, ship.speed)
		if ship.travel_length > previous_length + 1.0:
			length_never_rose = false
		previous_length = ship.travel_length
		steps += 1

		if ship.landed and tree.active_frame == world["surface"]:
			landed = true
			break

	h.check(visited.has("System"), "starts in the system frame")
	h.check(visited.has("Atmosphere"), "crosses into the atmosphere")
	h.check(visited.has("Surface"), "and reaches the surface frame")
	h.check(landed, "the ship gets down (%d steps, %.0f s of flight)" % [steps, steps * STEP])
	h.check(lowest_altitude >= -0.01, "and never passes through the planet")
	h.check(
		length_never_rose, "the travel unit never rises on the way down, so bands and thresholds agree"
	)
	h.check(
		highest_speed > 1.0e5 and lowest_speed < 1.0e3,
		(
			"and it slows by orders of magnitude on approach (%.1f km/s at first, %.1f m/s at the end)"
			% [highest_speed / 1.0e3, lowest_speed]
		)
	)
	world["container"].free()
