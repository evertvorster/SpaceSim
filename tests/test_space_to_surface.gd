extends RefCounted
## Fly the playground world: down to one planet, back up, then across to another.
##
## The spatial-scale proof, driven to completion and asserted rather than eyeballed. The second
## landing is the one that matters for a solar system: it crosses the gap between two bodies, so
## it exercises the travel unit following whichever body is nearest.

const PlayerShip := preload("res://demo/player_ship.gd")

const WORLD_PATH := "res://worlds/playground.json"
const STEP := 1.0 / 60.0
const MAX_STEPS := 120000


func run(h, root: Node) -> void:
	print("  fly the playground")
	var world := SpacesimWorld.from_file(WORLD_PATH)
	if world == null:
		h.check(false, "the playground world file loads")
		return
	world.build(root)
	var ship := PlayerShip.create()
	PlayerShip.place(world, ship)
	var tree = world.frame_tree

	var terra := world.body_by_id("planet:terra")
	var borealis := world.body_by_id("planet:borealis")

	var first := _descend(world, ship, terra)
	h.check(first["saw_atmosphere"], "descending to Terra crosses its atmosphere")
	h.check(first["saw_surface"], "and reaches its surface frame")
	h.check(first["landed"], "and lands (%d steps, %.0f s of flight)" % [first["steps"], first["steps"] * STEP])
	h.check(first["lowest_altitude"] >= -0.01, "without passing through the planet")
	h.check(
		first["unit_never_rose"],
		"and the travel unit never rises on the way down, so bands and thresholds agree"
	)
	h.check(
		first["highest_speed"] > 1.0e5 and first["lowest_speed"] < 1.0e3,
		(
			"slowing by orders of magnitude on approach (%.1f km/s, then %.1f m/s)"
			% [first["highest_speed"] / 1.0e3, first["lowest_speed"]]
		)
	)

	# --- back up ------------------------------------------------------------------
	var outward: Vector3 = (ship.global_position - terra.node.global_position).normalized()
	var climb_to: Vector3 = ship.global_position + outward * 1.0e7
	var takeoff_steps := 0
	var airborne := false
	while takeoff_steps < MAX_STEPS:
		ship.step(STEP, {"throttle": 1.0, "aim": climb_to})
		tree.evaluate()
		takeoff_steps += 1
		if ship.altitude() > 10000.0:
			airborne = true
			break

	h.check(airborne, "taking off again works (%d steps, %.0f s of climb)" % [takeoff_steps, takeoff_steps * STEP])
	h.check(not ship.landed, "and the ship is no longer in contact")
	h.check(tree.active_frame == terra.atmosphere, "and has climbed out of the surface frame")

	# --- across to another planet -------------------------------------------------
	var second := _descend(world, ship, borealis)
	h.check(second["landed"], "then flies across the system and lands on Borealis (%d steps)" % second["steps"])
	h.check(tree.active_frame == borealis.surface, "in Borealis's surface frame, not Terra's")
	h.check(
		second["longest_unit"] > 1.0e9,
		(
			"the travel unit grew to the size of the gap between planets (%.3f Gm), so it follows whichever body is nearest"
			% (second["longest_unit"] / 1.0e9)
		)
	)
	h.check(second["saw_borealis_as_nearest"], "and the nearest body became Borealis on the way")

	world.container.free()


## Fly at a body until the ship is down on its surface.
func _descend(world: SpacesimWorld, ship: Node3D, body: SpacesimWorldBody) -> Dictionary:
	var tree = world.frame_tree
	var saw_atmosphere := false
	var saw_surface := false
	var saw_body_as_nearest := false
	var lowest_altitude := INF
	var highest_speed := 0.0
	var lowest_speed := INF
	var longest_unit := 0.0
	var unit_never_rose := true
	var previous_unit := INF
	var steps := 0
	var landed := false

	while steps < MAX_STEPS:
		ship.step(STEP, {"throttle": 1.0, "aim": body.node.global_position})
		tree.evaluate()

		if tree.active_frame == body.atmosphere:
			saw_atmosphere = true
		if tree.active_frame == body.surface:
			saw_surface = true
		if ship.nearest_name == body.name:
			saw_body_as_nearest = true

		lowest_altitude = minf(lowest_altitude, ship.altitude())
		highest_speed = maxf(highest_speed, ship.speed)
		longest_unit = maxf(longest_unit, ship.travel_length)
		if ship.speed > 0.0:
			lowest_speed = minf(lowest_speed, ship.speed)

		# Monotonicity only means anything once the target is the nearest thing and the ship is
		# closing on it; during the cruise the unit legitimately rises as it leaves the last body.
		if saw_atmosphere and not landed:
			if ship.travel_length > previous_unit + 1.0:
				unit_never_rose = false
			previous_unit = ship.travel_length

		steps += 1
		if ship.landed and tree.active_frame == body.surface:
			landed = true
			break

	return {
		"steps": steps,
		"landed": landed,
		"saw_atmosphere": saw_atmosphere,
		"saw_surface": saw_surface,
		"saw_borealis_as_nearest": saw_body_as_nearest,
		"lowest_altitude": lowest_altitude,
		"highest_speed": highest_speed,
		"lowest_speed": lowest_speed,
		"longest_unit": longest_unit,
		"unit_never_rose": unit_never_rose,
	}
