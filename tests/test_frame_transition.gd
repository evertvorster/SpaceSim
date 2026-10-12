extends RefCounted
## Coordinate frames: threshold transitions, hysteresis, and pose continuity across a switch.
##
## The world under test is a planet 1e9 m from the system origin, with an atmosphere frame whose
## origin is the planet's centre. The observer starts in the system frame and flies down.

const Frame := preload("res://addons/spacesim/coordinate/frame.gd")
const FrameTree := preload("res://addons/spacesim/coordinate/frame_tree.gd")
const TransitionRule := preload("res://addons/spacesim/coordinate/transition_rule.gd")

const PLANET_RADIUS := 6_371_000.0 ## metres
const ENTER_ALTITUDE := 100_000.0 ## metres
const EXIT_ALTITUDE := 120_000.0 ## metres
const SYSTEM_OFFSET := 1.0e9 ## planet's position in the system frame, metres

## Tolerances. Positions pass through a reparent at 1e9 m scale, so absolute errors are bounded by
## double-precision round-trip noise (~1e-7 m) rather than by the algorithm.
const POSITION_EPSILON := 1.0e-4 ## metres
const BASIS_EPSILON := 1.0e-9
const ANGULAR_EPSILON := 1.0e-9 ## radians, ~1e-3 m at this scale


func run(h, root: Node) -> void:
	print("  coordinate frames")
	_test_stays_in_frame_above_threshold(h, root)
	_test_enters_frame_below_threshold(h, root)
	_test_hysteresis(h, root)
	_test_pose_survives_switch(h, root)
	_test_frame_position_math(h, root)


func _test_stays_in_frame_above_threshold(h, root: Node) -> void:
	var world := _build(root)
	_place_at_altitude(world, 150_000.0)
	world["tree"].evaluate()
	h.check(world["tree"].active_frame == world["system"], "300 km up: stays in the system frame")
	world["container"].free()


func _test_enters_frame_below_threshold(h, root: Node) -> void:
	var world := _build(root)
	_place_at_altitude(world, 99_000.0)
	world["tree"].evaluate()
	h.check(world["tree"].active_frame == world["atmosphere"], "99 km up: switches to the atmosphere frame")
	h.check(world["ship"].get_parent() == world["atmosphere"], "the observer is reparented into the new frame")
	world["container"].free()


func _test_hysteresis(h, root: Node) -> void:
	var world := _build(root)
	_place_at_altitude(world, 99_000.0)
	world["tree"].evaluate()
	h.check(world["tree"].active_frame == world["atmosphere"], "entered the atmosphere frame")

	# Between the two thresholds: neither rule applies, so the frame holds.
	_place_at_altitude(world, 110_000.0)
	world["tree"].evaluate()
	h.check(world["tree"].active_frame == world["atmosphere"], "110 km up: no flicker between thresholds")

	_place_at_altitude(world, 121_000.0)
	world["tree"].evaluate()
	h.check(world["tree"].active_frame == world["system"], "121 km up: the exit rule fires")
	world["container"].free()


func _test_pose_survives_switch(h, root: Node) -> void:
	var world := _build(root)
	var atmosphere: Node3D = world["atmosphere"]
	var ship: Node3D = world["ship"]

	# A frame that is both offset and rotated, so a lost or half-applied transform shows up.
	atmosphere.rotation = Vector3(0.3, 0.7, -0.2)
	_place_at_altitude(world, 99_000.0)
	ship.global_basis = Basis.from_euler(Vector3(0.15, 2.2, -0.4))

	var position_before: Vector3 = ship.global_position
	var basis_before: Basis = ship.global_basis
	var apparent_before := _apparent_radius(world)

	world["tree"].evaluate()

	h.check(world["tree"].active_frame == atmosphere, "crossing the threshold switches frame")
	h.check_vector_near(ship.global_position, position_before, "the observer does not move when the frame changes", POSITION_EPSILON)
	h.check_vector_near(ship.global_basis.x, basis_before.x, "orientation preserved (x axis)", BASIS_EPSILON)
	h.check_vector_near(ship.global_basis.y, basis_before.y, "orientation preserved (y axis)", BASIS_EPSILON)
	h.check_vector_near(ship.global_basis.z, basis_before.z, "orientation preserved (z axis)", BASIS_EPSILON)
	h.check_near(
		_apparent_radius(world), apparent_before, "the reference body's apparent size is unchanged (no pop)", ANGULAR_EPSILON
	)
	world["container"].free()


func _test_frame_position_math(h, root: Node) -> void:
	var world := _build(root)
	var atmosphere: Node3D = world["atmosphere"]
	var planet: Node3D = world["planet"]
	atmosphere.rotation = Vector3(0.0, 0.5, 0.0)

	# A point on the planet's surface, straight out along +X from the system's point of view.
	var outer: Vector3 = planet.global_position + Vector3(PLANET_RADIUS, 0.0, 0.0)
	var frame_position: Vector3 = atmosphere.to_frame_position(outer)
	h.check_vector_near(
		frame_position,
		Vector3(PLANET_RADIUS, 0.0, 0.0).rotated(Vector3.UP, -0.5),
		"to_frame_position undoes the frame's rotation",
		POSITION_EPSILON
	)
	h.check_vector_near(
		atmosphere.to_outer_position(frame_position), outer, "to_outer_position round-trips", POSITION_EPSILON
	)
	world["container"].free()


## The test world: a system frame, a planet, an atmosphere frame at the planet's centre, and an
## observer parked in the system frame with entry and exit rules wired up.
func _build(root: Node) -> Dictionary:
	var container := Node3D.new()
	container.name = "WorldUnderTest"
	root.add_child(container)

	var system := Frame.new()
	system.name = "System"
	system.kind = Frame.Kind.SPACE
	container.add_child(system)

	# Offset from the system origin so that a lost transform cannot go unnoticed.
	var planet := Node3D.new()
	planet.name = "Planet"
	planet.position = Vector3(SYSTEM_OFFSET, 0.0, 0.0)
	system.add_child(planet)

	var atmosphere := Frame.new()
	atmosphere.name = "Atmosphere"
	atmosphere.kind = Frame.Kind.ATMOSPHERE
	planet.add_child(atmosphere)

	var ship := Node3D.new()
	ship.name = "Observer"
	system.add_child(ship)

	var tree := FrameTree.new()
	tree.name = "FrameTree"
	tree.observer = ship
	tree.automatic = false # tests drive evaluate() themselves
	container.add_child(tree)

	tree.add_rule(
		TransitionRule.new(system, atmosphere, planet, PLANET_RADIUS, ENTER_ALTITUDE, TransitionRule.Direction.ENTER)
	)
	tree.add_rule(
		TransitionRule.new(atmosphere, system, planet, PLANET_RADIUS, EXIT_ALTITUDE, TransitionRule.Direction.EXIT)
	)
	tree.enter_frame(system)

	return {
		"container": container,
		"tree": tree,
		"system": system,
		"atmosphere": atmosphere,
		"planet": planet,
		"ship": ship,
	}


## Place the observer at an altitude above the planet's surface, expressed in outer space so the
## caller does not have to know which frame the observer is currently in.
func _place_at_altitude(world: Dictionary, altitude: float) -> void:
	var planet: Node3D = world["planet"]
	var ship: Node3D = world["ship"]
	ship.global_position = planet.global_position + Vector3(PLANET_RADIUS + altitude, 0.0, 0.0)


## Angular radius of the planet as seen from the observer, in radians. The visual quantity that
## must not jump when the coordinate frame changes.
func _apparent_radius(world: Dictionary) -> float:
	var planet: Node3D = world["planet"]
	var ship: Node3D = world["ship"]
	var distance := ship.global_position.distance_to(planet.global_position)
	return asin(PLANET_RADIUS / distance)
