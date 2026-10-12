extends RefCounted
## Builds the player's ship and puts it into a world.
##
## Demo code: the flight model is an episode's business, and what is engine is the travel unit
## the controller applies. Shared by the demo scene and the headless tests so both fly the
## same ship.

const FlightController := preload("res://demo/flight_controller.gd")

const HULL_SIZE := Vector3(6.0, 3.0, 18.0)
const CAMERA_OFFSET := Vector3(0.0, 5.0, 32.0)


static func create(ship_name := "Ship") -> Node3D:
	var ship := FlightController.new()
	ship.name = ship_name

	var box := BoxMesh.new()
	box.size = HULL_SIZE
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.75, 0.78, 0.85)
	var hull := MeshInstance3D.new()
	hull.name = "Hull"
	hull.mesh = box
	hull.material_override = material
	ship.add_child(hull)

	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.position = CAMERA_OFFSET
	camera.fov = 70.0
	ship.add_child(camera)

	return ship


## Put a ship into a world at the world's start position, in the system frame.
static func place(world: SpacesimWorld, ship: Node3D) -> void:
	ship.bodies = world.scale_bodies()
	ship.frame_tree = world.frame_tree
	world.frame_tree.observer = ship
	world.system_frame.add_child(ship)
	ship.global_position = world.ship_start()
	world.frame_tree.enter_frame(world.system_frame)
