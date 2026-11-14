extends RefCounted
## Navigation markers: the set for one frame, and the geometry that draws it.

const Markers := preload("res://addons/spacesim/navigation/markers.gd")
const Overlay := preload("res://addons/spacesim/navigation/overlay.gd")


## **A marker target is a position and a name, not a node** — bodies and fragments arrive the same way.
## Most of these tests only care about the keyed union and the ordering, so they build targets directly.
static func _target(
	id: int, priority: int, distance: float, text := "thing",
	parent := -1, ring := true
) -> Dictionary:
	return {
		"id": id, "position": Vector3.ZERO, "text": text, "priority": priority,
		"parent": parent, "ring": ring, "distance": distance,
	}


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
	_test_a_moon_gives_up_its_label_only_when_crowded(h, root)
	_test_a_projection_in_a_subviewport_is_converted(h)
	_test_a_place_has_no_range_limit(h, root)
	_test_the_nearest_moons_are_marked(h, root)
	_test_a_whole_system_leaves_room_for_the_belt(h)


func _test_keyed_union(h) -> void:
	# A body that is both an ambient object and a mission target must get one marker, not two
	# stacked on the same planet.
	var candidates: Array[Dictionary] = [
		_target(7, Markers.Priority.CONTEXT, 100.0),
		_target(7, Markers.Priority.MISSION, 500.0),
	]
	var chosen := Markers.choose(candidates, 10)
	h.check(chosen.size() == 1, "an object in two groups gets one marker")
	h.check(int(chosen[0]["priority"]) == Markers.Priority.MISSION, "and the higher priority survives")


func _test_priority_ordering(h) -> void:
	var chosen := Markers.choose(
		[
			_target(1, Markers.Priority.CONTEXT, 10.0),
			_target(2, Markers.Priority.SELECTED, 1.0e9),
		],
		10
	)
	h.check(chosen.size() == 2 and int(chosen[0]["id"]) == 2, "a selected target outranks a nearer one")
	# **A rock you are flying among outranks a moon on the far side of the system.** It used to be the
	# other way round, and on the first flight the HUD showed no asteroids at all: Sol has 40 significant
	# bodies, so a 24-slot pool was full before a fragment was ever considered.
	var mixed := Markers.choose(
		[
			_target(3, Markers.Priority.ASTEROID, 1.0e6),
			_target(4, Markers.Priority.CONTEXT, 10.0),
			_target(5, Markers.Priority.PRIMARY, 1.0e12),
		],
		10
	)
	h.check(int(mixed[0]["id"]) == 5, "a place outranks both")
	h.check(int(mixed[1]["id"]) == 3, "the fragment outranks the nearer moon")
	h.check(int(mixed[2]["id"]) == 4, "which is last")


func _test_cap_keeps_what_matters(h) -> void:
	var chosen := Markers.choose(
		[
			_target(1, Markers.Priority.CONTEXT, 300.0),
			_target(2, Markers.Priority.CONTEXT, 100.0),
			_target(3, Markers.Priority.CONTEXT, 200.0),
			_target(4, Markers.Priority.SELECTED, 1.0e9),
		],
		2
	)
	h.check(chosen.size() == 2, "the pool size is the cap")
	h.check(int(chosen[0]["id"]) == 4, "the selected target survives it")
	h.check(int(chosen[1]["id"]) == 2, "and the nearest ambient object fills the rest")


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



## **A moon gives up its label only when there is no room beside its own ring** — and never its ring.
## Io is a pixel from Jupiter from anywhere short of close approach, so a label pushed off its ring
## names something other than what the ring points at; but by Earth the two rings are well apart and
## both labels fit, so both are drawn.
func _test_a_moon_gives_up_its_label_only_when_crowded(h, root: Node) -> void:
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

	# **Both marked, with the moon's ring on the planet's: the moon's label goes and its mark stays.**
	# Driven through `_place`, because that is where the rule now lives — a helper that answered the
	# same question was deleted with the node-shaped candidate.
	var space := Vector2(1372.0, 720.0)
	var square := Rect2(24.0, 24.0, 1324.0, 672.0)
	var planet_entry := _target(1, Markers.Priority.PRIMARY, 100.0, "planet")
	planet_entry["circle"] = Vector2(690.0, 360.0)
	var moon_entry := _target(2, Markers.Priority.CONTEXT, 100.0, "moon", 1)
	moon_entry["circle"] = Vector2(686.0, 360.0)
	var marked := {1: true, 2: true}
	var crowded_taken: Array[Rect2] = []
	var crowded_placed := {}
	var planet_label := Label.new()
	var moon_label := Label.new()
	markers._place(planet_entry, planet_label, marked, space, square, crowded_taken, crowded_placed)
	var crowded := markers._place(moon_entry, moon_label, marked, space, square, crowded_taken, crowded_placed)
	h.check(not moon_label.visible, "a moon on its planet's ring gives up its label")
	h.check(crowded.has("circle"), "but keeps its ring")
	h.check(planet_label.visible, "while the planet's label stays")

	# **The target is drawn regardless**: you asked for that moon in particular.
	var selected_taken: Array[Rect2] = []
	var selected_placed := {}
	var chosen_label := Label.new()
	var replacement_label := Label.new()
	markers._place(planet_entry, replacement_label, marked, space, square, selected_taken, selected_placed)
	var target_entry := _target(2, Markers.Priority.SELECTED, 100.0, "moon", 1)
	target_entry["circle"] = Vector2(686.0, 360.0)
	markers._place(target_entry, chosen_label, marked, space, square, selected_taken, selected_placed)
	h.check(chosen_label.visible, "unless it is the target, which is when you asked for that moon")

	# The planet is not marked at all: there is nothing to compete with, so the moon keeps its name.
	var only_moon := {2: true}
	var alone_taken: Array[Rect2] = []
	var alone_placed := {}
	var alone_label := Label.new()
	markers._place(moon_entry, alone_label, only_moon, space, square, alone_taken, alone_placed)
	h.check(alone_label.visible, "and it keeps its name when the body it orbits is not marked")
	for label in [planet_label, moon_label, chosen_label, alone_label, replacement_label]:
		label.free()

	# --- and the half that decides it: is the planet's label what took the moon's space?
	var bounds := Rect2(24.0, 24.0, 1324.0, 672.0)
	var size := Vector2(150.0, 24.0)
	var planet_box := Overlay.place_label(Vector2(690.0, 360.0), size, [], bounds)
	var taken: Array[Rect2] = [planet_box]

	# The moon's ring on the planet's: its nearest spot is the one the planet's label already has.
	h.check(
		markers._crowds_its_parent(Vector2(686.0, 360.0), size, taken, planet_box, bounds),
		"a moon on its planet's ring is crowding the planet's label"
	)
	h.check(
		not markers._crowds_its_parent(Vector2(200.0, 560.0), size, taken, planet_box, bounds),
		"a moon well clear of its planet keeps its own space, and its label"
	)

	# Nothing free even with the planet's label set aside is crowding too: a moon's label is beside its
	# own ring or it names something other than what the ring points at.
	var blocked: Array[Rect2] = [bounds]
	h.check(
		markers._crowds_its_parent(Vector2(686.0, 360.0), size, blocked, Rect2(), bounds),
		"and a moon with nowhere at all beside its ring is crowding too"
	)

	# Nothing within reach is reported, not faked: the caller decides what to do about it.
	var full: Array[Rect2] = [bounds]
	h.check(
		not Overlay.nearest_free(Vector2(686.0, 360.0), size, full, bounds, Overlay.STEPS).has_area(),
		"and a screen with nowhere at all says so"
	)
	h.check(
		Overlay.place_label(Vector2(686.0, 360.0), size, full, bounds).has_area(),
		"while place_label still draws something, because a label that overlaps beats no label"
	)
	# Last, because the markers above are its children: freeing it first leaves every call after it
	# on a freed object, which is a segfault rather than a failure.
	container.free()


## **The camera may be inside a `SubViewport`**, and then its projection is in that viewport's pixels while
## the labels are `Control`s in the root canvas — the two are the same picture at two scales. An empty band
## is the single-viewport case, where nothing needs converting.
func _test_a_projection_in_a_subviewport_is_converted(h) -> void:
	var drawn := Vector2(800.0, 450.0)
	# The band is twice the camera's rect, which is what a 1080-window over a 540-pixel band looks like to a
	# canvas the labels are laid out in.
	var band := Rect2(0.0, 0.0, 1600.0, 900.0)
	var mid := Markers.to_canvas(drawn * 0.5, drawn, band)
	h.check(mid == Vector2(800.0, 450.0), "the camera's centre is the band's centre (%s)" % str(mid))
	h.check(
		Markers.to_canvas(Vector2.ZERO, drawn, band) == band.position,
		"and its origin is the band's origin (%s)" % str(Markers.to_canvas(Vector2.ZERO, drawn, band))
	)
	# **A band that starts somewhere other than the origin** carries the point with it, which is what makes
	# this a conversion rather than a scale.
	var offset := Rect2(0.0, 120.0, 1600.0, 900.0)
	h.check(
		Markers.to_canvas(Vector2.ZERO, drawn, offset) == Vector2(0.0, 120.0),
		"and an offset band offsets the point with it"
	)
	# **No band is the no-conversion case**: the camera draws into the canvas the labels live in.
	var same := Vector2(123.0, 45.0)
	h.check(Markers.to_canvas(same, drawn, Rect2()) == same, "with no band a point is left exactly as it is")
	# A viewport with no width would divide by zero on the way to a NaN, which then places nothing at all.
	h.check(
		Markers.to_canvas(same, Vector2.ZERO, band) == same,
		"and a camera with no rect cannot scale anything (%s)" % str(Markers.to_canvas(same, Vector2.ZERO, band))
	)


func _test_distance_format(h) -> void:
	h.check(SpacesimMarkers.format_distance(1.5e9) == "1.50 Gm", "gigametres")
	h.check(SpacesimMarkers.format_distance(2500.0) == "2.5 km", "kilometres")
	h.check(SpacesimMarkers.format_distance(12.0) == "12 m", "metres")
	h.check(SpacesimMarkers.format_distance(INF) == "--", "and nothing at all reads as dashes")


## **A place is marked however far away it is.**
##
## Evert, 2026-11-12: *"significant objects like planets and SOL stop showing up when they are beyond 600Gm ... There
## should be no range limit."* The marker set was capped at `pool_size` and ordered by distance, so a system full of
## nearby moons spent the whole budget and the star fell off the list — a distance limit that nobody wrote as one.
func _test_a_place_has_no_range_limit(h, root: Node) -> void:
	var container := Node3D.new()
	root.add_child(container)
	var markers := Markers.new()
	container.add_child(markers)

	var star := Node3D.new()
	star.position = Vector3(1.0e12, 0.0, 0.0)
	container.add_child(star)
	var nearby: Array[Node3D] = []
	for index in 20:
		var moon := Node3D.new()
		moon.position = Vector3(float(index) * 1.0e6, 0.0, 0.0)
		container.add_child(moon)
		nearby.append(moon)
		var parent := SpacesimSceneBody.new()
		parent.node = star
		markers.orbits[moon] = parent

	markers.context_targets = [star]
	markers.context_targets.append_array(nearby)

	var gathered := markers._candidates(Vector3.ZERO)
	var places := 0
	for candidate in gathered:
		if int(candidate["priority"]) >= Markers.Priority.PRIMARY:
			places += 1
	h.check(places == 1, "the star is a place and is a candidate at a terametre (%d)" % places)
	var chosen := Markers.choose(gathered, maxi(4, places))
	h.check(chosen.size() > 0 and int(chosen[0]["id"]) == star.get_instance_id(),
		"and it is the FIRST marker chosen, ahead of twenty nearer moons")
	container.free()


## **The moons that are marked are the ones nearest the eye.**
##
## Evert, 2026-11-12: *"when close to a body, I might be flying in between the moons, so I want the list of moons to be
## marked to be calculated from the moons that are closest to me."* The places take their slots first and the rest of
## the pool goes to details in distance order — so a moon behind its planet is still marked when it is the near one,
## and a moon far off is not.
func _test_the_nearest_moons_are_marked(h, root: Node) -> void:
	var container := Node3D.new()
	root.add_child(container)
	var markers := Markers.new()
	container.add_child(markers)

	var planet := Node3D.new()
	planet.position = Vector3(5000.0, 0.0, 0.0)
	container.add_child(planet)
	var body := SpacesimSceneBody.new()
	body.node = planet

	markers.context_targets = [planet]
	var moons: Array[Node3D] = []
	for index in 6:
		var moon := Node3D.new()
		# 100 m, 200 m ... out from the eye, and all of them nearer than the planet except the last two.
		moon.position = Vector3(100.0 * float(index + 1), 0.0, 0.0)
		container.add_child(moon)
		markers.orbits[moon] = body
		moons.append(moon)
		markers.context_targets.append(moon)

	var gathered := markers._candidates(Vector3.ZERO)
	var chosen := Markers.choose(gathered, 4)
	var picked: Array = []
	for entry in chosen:
		picked.append(int(entry["id"]))
	h.check(picked.size() == 4 and picked[0] == planet.get_instance_id(),
		"the planet is a place, so it is marked even though every moon is nearer")
	h.check(
		picked.has(moons[0].get_instance_id()) and picked.has(moons[1].get_instance_id())
		and picked.has(moons[2].get_instance_id()),
		"and the pool goes to the three NEAREST moons (%d marked)" % picked.size()
	)
	h.check(not picked.has(moons[5].get_instance_id()), "not to the furthest one")
	container.free()


## **The flight that found this, 2026-11-14**: Evert flew from Phobos towards Jupiter, the ship slowed
## down about halfway, *Closest* read an asteroid — and no asteroid markers appeared.
##
## Sol has **40 significant bodies**: the star and eight planets at `PRIMARY`, and thirty-one moons at
## `CONTEXT`, every one of them a candidate at any distance. Fragments sat at the bottom of the ladder, so a
## 24-slot pool was filled by the places and the moons before a fragment was ever considered. The tier
## ordering is what was wrong, not the gathering.
func _test_a_whole_system_leaves_room_for_the_belt(h) -> void:
	var candidates: Array[Dictionary] = []
	for index in 9:
		candidates.append(_target(1 + index, Markers.Priority.PRIMARY, 1.0e11 * float(index + 1)))
	for index in 31:
		candidates.append(_target(100 + index, Markers.Priority.CONTEXT, 1.0e9))
	# The belt, as the field hands it over: nearer than anything else, and with no node behind it.
	for index in 24:
		candidates.append(_target(-1 - index, Markers.Priority.ASTEROID, 4.6e7 + float(index)))

	var chosen := Markers.choose(candidates, 24)
	var places := 0
	var rocks := 0
	for entry in chosen:
		if int(entry["priority"]) == Markers.Priority.PRIMARY:
			places += 1
		elif int(entry["priority"]) == Markers.Priority.ASTEROID:
			rocks += 1
	h.check(places == 9, "all nine places are marked")
	h.check(rocks == 15, "and the rest of the pool goes to the belt (%d rocks)" % rocks)
	h.check(int(chosen[8]["priority"]) == Markers.Priority.PRIMARY,
		"the places come first, in distance order")
	h.check(int(chosen[9]["priority"]) == Markers.Priority.ASTEROID,
		"and the rocks take the pool after them")
