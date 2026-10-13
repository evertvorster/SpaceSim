extends RefCounted
## Navigation markers: the set for one frame, and the geometry that draws it.

const Markers := preload("res://addons/spacesim/navigation/markers.gd")
const Overlay := preload("res://addons/spacesim/navigation/overlay.gd")


func run(h, root: Node) -> void:
	print("  navigation markers")
	_test_keyed_union(h)
	_test_priority_ordering(h)
	_test_cap_keeps_what_matters(h)
	_test_pointer_is_the_smallest_turn(h)
	_test_screen_direction(h, root)
	_test_distance_format(h)
	_test_a_label_keeps_clear_of_the_others(h)
	_test_a_line_leaves_the_ring_at_its_edge(h)
	_test_the_target_has_its_own_colour(h, root)
	_test_a_moon_gives_up_its_label_to_its_planet(h, root)


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

	# **Not the centre.** A point inside is left alone — and the centre is the one place where a
	# projection onto the border and a clamp agree, so testing only that hid a regression that threw
	# every on-screen label out to the edge of the window with a line back to its own object.
	var off_centre := Vector2(420.0, 260.0)
	h.check_vector2_near(
		Markers.clamp_to_edge(off_centre, size, 100.0), off_centre, "a point inside is left where it is", 0.01
	)
	h.check_vector2_near(
		Markers.clamp_to_edge(Vector2(850.0, 450.0), size, 100.0),
		Vector2(850.0, 450.0),
		"anywhere inside, not just near the middle",
		0.01
	)


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


## **The whole point of the overlay.** Nine objects all lying in one direction is the ordinary case
## in a solar system seen from far away — Jupiter and Saturn behind each other, and every moon with
## them — so the labels have to arrange themselves, not simply be drawn at their objects.
func _test_a_label_keeps_clear_of_the_others(h) -> void:
	var bounds := Rect2(24.0, 24.0, 1324.0, 672.0)
	var size := Vector2(150.0, 22.0)

	# **As close as its own shape allows**, not somewhere off at the edge. A wide label belongs beside
	# its ring: sideways it needs half its width, and vertically it needs a third of that. Using one
	# radius for both — the label's largest dimension — put a short wide label a hundred pixels off in
	# every direction, including straight up.
	var wide := Vector2(200.0, 20.0)
	var beside := Overlay.place_label(Vector2(700.0, 400.0), wide, [], bounds)
	h.check_near(beside.get_center().y, 400.0, "a wide label sits level with its ring", 0.01)
	h.check_near(
		beside.get_center().x - 700.0,
		100.0 + Overlay.RING_RADIUS + Overlay.GAP,
		"and just clear of it — half its width and the clearance, and no more",
		0.01
	)

	# Block both sides and it stacks instead — **by its own half-height**, which is a third of the
	# distance: a short wide label needs half its width sideways and only half its height up. One
	# radius for every direction cannot tell those apart, which is what pushed labels off to the edges.
	var other_side := Overlay.place_label(Vector2(700.0, 400.0), wide, [beside], bounds)
	h.check_near(other_side.get_center().x, 578.0, "and with that taken it goes to the other side", 0.01)
	var above := Overlay.place_label(Vector2(700.0, 400.0), wide, [beside, other_side], bounds)
	h.check_near(above.get_center().x, 700.0, "with both sides taken, a wide label stacks", 0.01)
	h.check_near(
		absf(above.get_center().y - 400.0),
		10.0 + Overlay.RING_RADIUS + Overlay.GAP,
		"by its own half-height and the clearance, not its half-width",
		0.01
	)

	# Nine objects in one direction: the anchors are on top of each other.
	var taken: Array[Rect2] = []
	for index in 9:
		var anchor := Vector2(686.0 + float(index) * 0.5, 360.0)
		taken.append(Overlay.place_label(anchor, size, taken, bounds))

	var clashes: Array[String] = []
	for a in taken.size():
		for b in range(a + 1, taken.size()):
			if taken[a].intersects(taken[b]):
				clashes.append("%d and %d" % [a, b])
	h.check(
		clashes.is_empty(),
		"nine labels from one spot do not overlap each other%s" % (
			"" if clashes.is_empty() else ": " + ", ".join(clashes)
		)
	)

	var outside: Array[String] = []
	for index in taken.size():
		if not bounds.encloses(taken[index]):
			outside.append("label %d at %s" % [index, str(taken[index])])
	h.check(outside.is_empty(), "and all of them are inside the screen%s" % (
		"" if outside.is_empty() else ": " + ", ".join(outside)
	))

	# Deliberately overlapping now: same inputs, same answer. A placement that wandered between
	# frames would make the whole overlay flicker.
	var again: Array[Rect2] = []
	for index in 9:
		again.append(
			Overlay.place_label(Vector2(686.0 + float(index) * 0.5, 360.0), size, again, bounds)
		)
	h.check(again == taken, "and the same inputs place them in the same places")

	# The HUD is avoided through the same mechanism, so a reserved rectangle is respected too.
	var reserved: Array[Rect2] = [Rect2(0.0, 0.0, 600.0, 400.0)]
	var over_hud := Overlay.place_label(Vector2(100.0, 100.0), size, reserved, bounds)
	h.check(not reserved[0].intersects(over_hud), "a reserved rectangle is avoided like any other")

	# Nothing free anywhere is still a label: an overlapping one says where something is, a missing
	# one says nothing.
	var full: Array[Rect2] = [bounds]
	var last := Overlay.place_label(Vector2(686.0, 360.0), size, full, bounds)
	h.check(last.size == size, "and a label is never dropped, even with nowhere to put it")

	# A label bigger than the screen is left alone rather than squashed to fit.
	var huge := Vector2(2000.0, 40.0)
	var unclamped := Overlay.place_label(Vector2(686.0, 360.0), huge, [], bounds)
	h.check(unclamped.size == huge, "a label too wide for the screen is not squashed")


## The selected target is the one thing on the overlay that stands out, and it does so in a colour of
## its own so it can be made to stand out against whatever it happens to be seen against.
func _test_the_target_has_its_own_colour(h, root: Node) -> void:
	var markers := Markers.new()
	root.add_child(markers)

	h.check(
		markers.colour_of(Markers.Priority.SELECTED) == markers.selected_color,
		"the selected target is drawn in its own colour"
	)
	h.check(
		markers.colour_of(Markers.Priority.CONTEXT) == Overlay.COLOR
		and markers.colour_of(Markers.Priority.MISSION) == Overlay.COLOR,
		"and a mission target and the ambient group in the one colour"
	)
	h.check(
		markers.selected_color.r > 0.9
		and markers.selected_color.g > 0.8
		and markers.selected_color.b < 0.4,
		"which starts yellow (%s)" % markers.selected_color
	)

	# Hot, like every other setting: read per frame, never cached at startup.
	markers.selected_color = Color(0.2, 1.0, 0.4)
	h.check(
		markers.colour_of(Markers.Priority.SELECTED) == Color(0.2, 1.0, 0.4),
		"and follows the setting rather than the default"
	)
	markers.free()


## A line exists only where there is a ring to draw it from.
func _test_a_line_leaves_the_ring_at_its_edge(h) -> void:
	var ring := Rect2(Vector2(490.0, 290.0), Vector2(20.0, 20.0))
	var edge := Overlay.border_point(ring, Vector2(500.0, 200.0))
	h.check_near(
		edge.distance_to(Vector2(500.0, 300.0)), Overlay.RING_RADIUS,
		"a line leaves a ring at the ring's edge, not its middle",
		0.01
	)



## **A moon gives up its label, not its ring.** Io is a pixel from Jupiter and Luna a pixel from
## Earth from anywhere short of close approach, so two names a pixel apart say no more than one — and
## the parent's is the one that stays, because the planet is what tells you where you are.
func _test_a_moon_gives_up_its_label_to_its_planet(h, root: Node) -> void:
	var container := Node3D.new()
	root.add_child(container)

	var markers := Markers.new()
	container.add_child(markers)
	var planet := Node3D.new()
	container.add_child(planet)
	var moon := Node3D.new()
	container.add_child(moon)
	var other := Node3D.new()
	container.add_child(other)

	var body := SpacesimSceneBody.new()
	body.node = planet
	markers.orbits[moon] = body

	# Both marked: the moon's label goes, the planet's stays.
	var marked := {planet.get_instance_id(): true, moon.get_instance_id(): true}
	h.check(
		markers._yields_to_parent(moon, Markers.Priority.CONTEXT, marked),
		"a moon whose planet is also marked gives way to it"
	)
	h.check(
		not markers._yields_to_parent(moon, Markers.Priority.SELECTED, marked),
		"unless it is the target, which is when you asked for that moon in particular"
	)
	h.check(
		not markers._yields_to_parent(planet, Markers.Priority.CONTEXT, marked),
		"the planet itself orbits nothing, so it never gives way"
	)
	h.check(
		not markers._yields_to_parent(other, Markers.Priority.CONTEXT, marked),
		"and neither does a body with no parent"
	)

	# The planet is not marked at all: there is nothing to give way to, so the moon keeps its name.
	var only_moon := {moon.get_instance_id(): true}
	h.check(
		not markers._yields_to_parent(moon, Markers.Priority.CONTEXT, only_moon),
		"a moon keeps its label when the body it orbits is not marked"
	)
	container.free()


func _test_distance_format(h) -> void:
	h.check(SpacesimMarkers.format_distance(1.5e9) == "1.50 Gm", "gigametres")
	h.check(SpacesimMarkers.format_distance(2500.0) == "2.5 km", "kilometres")
	h.check(SpacesimMarkers.format_distance(12.0) == "12 m", "metres")
	h.check(SpacesimMarkers.format_distance(INF) == "--", "and nothing at all reads as dashes")
