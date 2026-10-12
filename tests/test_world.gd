extends RefCounted
## Loading a world from data and building it.

const PlayerShip := preload("res://demo/player_ship.gd")

const WORLD_PATH := "res://worlds/playground.json"


func run(h, root: Node) -> void:
	print("  playground world")
	var world := SpacesimWorld.from_file(WORLD_PATH)
	h.check(world != null, "the playground world file loads")
	if world == null:
		return

	h.check(world.name == "playground", "and is named '%s'" % world.name)
	h.check(world.bodies.size() == 5, "with five bodies (%d)" % world.bodies.size())

	var star := world.body_by_id("star:helios")
	h.check(star != null and not star.landable, "the star is a body but not landable")
	var terra := world.body_by_id("planet:terra")
	h.check(terra != null and terra.landable, "Terra is landable")
	h.check(terra != null and terra.radius > 6.0e6, "at planet scale, not toggle scale")

	world.build(root)
	h.check(world.system_frame != null and world.frame_tree != null, "building gives frames")

	var landable := 0
	var framed := 0
	for body in world.bodies:
		if not body.landable:
			continue
		landable += 1
		if body.atmosphere != null and body.surface != null:
			framed += 1
	h.check(landable == 4, "four landable bodies")
	h.check(framed == 4, "each with atmosphere and surface frames")
	h.check(world.scale_bodies().size() == 5, "every body counts towards the local travel unit")

	# The landing zone goes wherever the ship came down, with local up pointing outwards.
	# Anywhere else would leave the ship millions of metres from its own frame's origin.
	var point: Vector3 = terra.node.global_position + Vector3(0.0, 0.0, terra.radius)
	world.place_landing_zone(terra, point)
	h.check_near(
		terra.surface.global_position.distance_to(terra.node.global_position),
		terra.radius,
		"the landing zone sits on the surface",
		1.0e-6
	)
	h.check_vector_near(
		terra.surface.global_basis.y,
		(point - terra.node.global_position).normalized(),
		"with local up pointing away from the centre",
		1.0e-9
	)

	var ship := PlayerShip.create()
	PlayerShip.place(world, ship)
	ship.step(1.0 / 60.0, {"throttle": 0.0})
	h.check(world.frame_tree.active_frame == world.system_frame, "a ship starts in the system frame")
	h.check(
		ship.altitude() != INF and nearest_is(world, ship, "planet:terra"),
		"above the world's start body"
	)
	h.check_near(ship.altitude(), world.start_altitude, "at the world's start altitude", 1.0)

	world.container.free()


## Whether the ship's nearest significant body is the one with this id.
func nearest_is(world: SpacesimWorld, ship: Node3D, id: String) -> bool:
	var body := world.body_by_id(id)
	return body != null and ship.nearest_name == body.name
