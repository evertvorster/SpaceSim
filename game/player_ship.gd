extends RefCounted
## Builds the player's ship and puts it into a system.
##
## The ship itself is game code — the flight model is an episode's business, and what is engine is the
## travel unit the controller applies. Shared by the game scene and the headless tests so both fly
## the same ship.

const FlightController := preload("res://game/flight_controller.gd")

## **Where the viewpoint sits in the ship's frame** — five metres up and thirty-two behind the origin. There is no
## hull: the placeholder box was an 18 m slab floating in front of the camera, and at a low altitude it appeared as a
## plate on the ground — Evert, 2026-10-28: *"There is some sort of landing pad that pops up when I am close to the
## surface. Strip that out, and clear out the mechanism that makes it."* It came back because deep space's near plane is
## 100 m and clipped it away, and `_update_camera` pulled that plane inside the hull once it was drawn — so the box was
## invisible from orbit and popped into view on approach. With no hull there is nothing to clip and no reason to move the
## near plane, so both go.
const CAMERA_OFFSET := Vector3(0.0, 5.0, 32.0)


static func create(ship_name := "Ship") -> Node3D:
	var ship := FlightController.new()
	ship.name = ship_name

	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.position = CAMERA_OFFSET
	camera.fov = 70.0
	# Exposure is NOT set here: it is physics-computed and kept up to date by the game
	# (SpacesimExposure), so the ship does not guess at it.
	ship.add_child(camera)

	return ship


## Put a ship into a system at the system's start position, in the system frame.
static func place(system: SpacesimSystemScene, ship: Node3D) -> void:
	ship.bodies = system.scale_bodies()
	ship.frame_tree = system.frame_tree
	system.frame_tree.observer = ship
	system.system_frame.add_child(ship)
	ship.global_position = system.ship_start()
	# A starting position is a placement, not motion: without this the first frames would render the
	# ship gliding in from wherever the node was created.
	#
	# The interpolated transform is read *first* on purpose. `get_global_transform_interpolated`
	# creates the interpolation pump that the reset then talks to, and the engine asks for it to have
	# been called at least once before a reset — otherwise a followed node can streak on first sight.
	ship.get_global_transform_interpolated()
	ship.reset_physics_interpolation()
	system.frame_tree.enter_frame(system.system_frame)
