extends RefCounted
## Navigation markers: the set for one frame, and the geometry that draws it.

const Markers := preload("res://addons/spacesim/navigation/markers.gd")


func run(h, root: Node) -> void:
	print("  navigation markers")
	_test_keyed_union(h)
	_test_priority_ordering(h)
	_test_cap_keeps_what_matters(h)
	_test_pointer_is_the_smallest_turn(h)
	_test_screen_direction(h, root)
	_test_distance_format(h)


func _test_keyed_union(h) -> void:
	# A body that is both an ambient object and a mission target must get one marker, not two
	# stacked on the same planet.
	var node := Node3D.new()
	var candidates: Array[Dictionary] = [
		{"node": node, "priority": Markers.Priority.CONTEXT, "distance": 100.0},
		{"node": node, "priority": Markers.Priority.MISSION, "distance": 500.0},
	]
	var chosen := Markers.choose(candidates, 10)
	h.check(chosen.size() == 1, "an object in two groups gets one marker")
	h.check(int(chosen[0]["priority"]) == Markers.Priority.MISSION, "and the higher priority survives")
	node.free()


func _test_priority_ordering(h) -> void:
	var nearby := Node3D.new()
	var distant := Node3D.new()
	var chosen := Markers.choose(
		[
			{"node": nearby, "priority": Markers.Priority.CONTEXT, "distance": 10.0},
			{"node": distant, "priority": Markers.Priority.SELECTED, "distance": 1.0e9},
		],
		10
	)
	h.check(chosen.size() == 2 and chosen[0]["node"] == distant, "a selected target outranks a nearer one")
	nearby.free()
	distant.free()


func _test_cap_keeps_what_matters(h) -> void:
	var a := Node3D.new()
	var b := Node3D.new()
	var c := Node3D.new()
	var chosen_target := Node3D.new()
	var chosen := Markers.choose(
		[
			{"node": a, "priority": Markers.Priority.CONTEXT, "distance": 300.0},
			{"node": b, "priority": Markers.Priority.CONTEXT, "distance": 100.0},
			{"node": c, "priority": Markers.Priority.CONTEXT, "distance": 200.0},
			{"node": chosen_target, "priority": Markers.Priority.SELECTED, "distance": 1.0e9},
		],
		2
	)
	h.check(chosen.size() == 2, "the pool size is the cap")
	h.check(chosen[0]["node"] == chosen_target, "the selected target survives it")
	h.check(chosen[1]["node"] == b, "and the nearest ambient object fills the rest")
	a.free()
	b.free()
	c.free()
	chosen_target.free()


func _test_pointer_is_the_smallest_turn(h) -> void:
	var size := Vector2(1000.0, 600.0)
	var edge := Markers.clamp_to_edge(Vector2(5000.0, 300.0), size, 100.0)
	h.check_near(edge.x, 900.0, "off to the right lands on the right edge", 0.01)
	h.check_near(edge.y, 300.0, "at the same height", 0.01)

	var further := Markers.clamp_to_edge(Vector2(9000.0, 300.0), size, 100.0)
	h.check_vector2_near(further, edge, "however far out it is, the pointer is the same", 0.01)

	var corner := Markers.clamp_to_edge(Vector2(-5000.0, -5000.0), size, 100.0)
	h.check(
		corner.x >= 99.9 and corner.y >= 99.9 and corner.x <= 500.0 and corner.y <= 300.0,
		"a point up and behind lands inside the margin on the correct side"
	)

	var inside := Markers.clamp_to_edge(Vector2(500.0, 300.0), size, 100.0)
	h.check_vector2_near(inside, Vector2(500.0, 300.0), "a point at the centre is left alone", 0.01)


func _test_screen_direction(h, root: Node) -> void:
	var container := Node3D.new()
	root.add_child(container)
	var camera := Camera3D.new()
	container.add_child(camera) # looking down -Z by default

	var ahead := Markers.screen_direction(camera, Vector3(0.0, 0.0, -100.0))
	h.check(ahead.length() > 0.5, "a target dead ahead still yields a usable direction")

	var right := Markers.screen_direction(camera, Vector3(100.0, 0.0, -100.0))
	h.check(right.x > 0.5, "a target to the right points right")

	# The case unproject_position gets wrong: behind the camera it mirrors, so the pointer
	# would send you the wrong way.
	var behind_left := Markers.screen_direction(camera, Vector3(-100.0, 0.0, 100.0))
	h.check(behind_left.x < -0.5, "a target behind and to the left points left, not mirrored")
	container.free()


func _test_distance_format(h) -> void:
	h.check(SpacesimMarkers.format_distance(1.5e9) == "1.50 Gm", "gigametres")
	h.check(SpacesimMarkers.format_distance(2500.0) == "2.5 km", "kilometres")
	h.check(SpacesimMarkers.format_distance(12.0) == "12 m", "metres")
	h.check(SpacesimMarkers.format_distance(INF) == "--", "and nothing at all reads as dashes")
