extends RefCounted
## Builds the player's ship and puts it into a system.
##
## The ship itself is game code — the flight model is an episode's business, and what is engine is the
## travel unit the controller applies. Shared by the game scene and the headless tests so both fly
## the same ship.

const FlightController := preload("res://game/flight_controller.gd")

static func create(ship_name := "Ship") -> Node3D:
	var ship := FlightController.new()
	ship.name = ship_name

	# **The viewpoint is the ship's origin.** It used to sit five metres up and thirty-two behind, because a
	# placeholder hull was drawn and the eye had to clear it. The hull went on 2026-10-28 and the offset stayed,
	# and it is 32 m of arm: beside a 28 m asteroid, turning the ship swung the eye right around the rock.
	# Evert, 2026-11-14: *"the observer should be in the ship in all frames."* `_camera_mount` still carries the
	# view basis (the six-sided screenshot views), and that is a rotation about the observer, which is what it
	# should be.
	var camera := Camera3D.new()
	camera.name = "Camera"
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
