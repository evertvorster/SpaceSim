class_name SpacesimMarkers
extends Node3D
## Navigation markers: where each object that matters is, and what it is.
##
## **A ring at the object, a line, and a label** — the beginning of the navigation overlay.
##
## * **the ring** is the object's own screen position, and **may be off screen**. It is the label
##   that stays in view, so an object over the edge leaves its line running in from the edge,
##   pointing at where it is. That is the whole reason the ring is not clamped along with the label.
## * **the line** runs from the ring's edge to the label's box, which is what makes a label in the
##   middle of a crowded screen still belong to something.
## * **the label** is a name and a distance, placed by [SpacesimOverlay.place_label] clear of every
##   other label and of the HUD, so a screen full of markers reads as a set rather than a pile.
##
## The set is rebuilt every frame and the labels are **pooled, not allocated** — a set that changes
## per frame would otherwise churn nodes, and the pool size is the screen-space budget in one place.
##
## Which objects are marked is the caller's business. This decides only how they are drawn.

## Context is the ambient group (other planets while you are in space, say); a selected target
## outranks a mission objective, which outranks context.
enum Priority { CONTEXT = 0, MISSION = 1, SELECTED = 2 }

const Overlay := preload("res://addons/spacesim/navigation/overlay.gd")

const DEFAULT_POOL_SIZE := 12

## A projection is only meaningful on screen; anything past this is behind the camera or beside it,
## and both cases want the same thing — a line from the edge in the right direction.
const OFF_SCREEN_REACH := 1.0e6



@export var pool_size := DEFAULT_POOL_SIZE

## Hot: a setter rather than a value read once, so changing it re-applies to the live pool.
@export var font_size := 17:
	set(value):
		font_size = value
		for label in _labels:
			label.add_theme_font_size_override("font_size", value)

## Inset from the viewport edge. The labels are fitted inside it, so it is breathing room rather
## than the clearance an edge-clamped pointer used to need.
var margin := 24.0

## The selected target's colour; everything else is drawn in [constant SpacesimOverlay.COLOR]. A
## colour rather than a flag, so a target can be made to stand out against whatever it is seen
## against. Both defaults are declared in the settings registry, and this is the copy the caller
## overwrites from there.
var selected_color := Color(1.0, 0.9, 0.3)

## For each body that orbits another, the [SpacesimSceneBody] it orbits, keyed by the orbiting
## body's node. Handed over once by the caller, because it is a fact about the system rather than
## about a frame. Used by [method eclipsed].
var orbits: Dictionary = {}

## Rebuilt every frame by the caller. Later entries outrank earlier ones.
var context_targets: Array[Node3D] = []
var mission_targets: Array[Node3D] = []
var selected: Node3D = null

var _labels: Array[Label] = []
var _overlay: SpacesimOverlay
var _layer: CanvasLayer


func _ready() -> void:
	_build_pool()


## Changing how many markers there is room for is the one setting that cannot be applied in
## place: the pool has to be built again.
func rebuild_pool(new_size: int) -> void:
	var wanted := maxi(new_size, 1)
	if wanted == pool_size and not _labels.is_empty():
		return
	pool_size = wanted
	if _layer != null:
		_layer.free()
		_layer = null
	_labels.clear()
	_overlay = null
	_build_pool()


func _build_pool() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "Markers"
	add_child(_layer)

	_overlay = Overlay.new()
	_overlay.name = "Overlay"
	_layer.add_child(_overlay)

	for index in pool_size:
		var label := Label.new()
		label.name = "Marker%d" % index
		label.add_theme_font_size_override("font_size", font_size)
		label.add_theme_color_override("font_color", Overlay.COLOR)
		label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
		label.add_theme_constant_override("outline_size", 6)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.visible = false
		_layer.add_child(label)
		_labels.append(label)


## Rebuild the marker set, place its labels, and hand the rings to the overlay. Call once a frame.
##
## **The CANVAS rect, and that is a deliberate difference from the sky, the air and `SpacesimLod.pixel_angle`,
## which take the render target's size.** The markers are `Control`s in a `CanvasLayer`, and `unproject_position()`
## returns coordinates in the same space they are laid out in — so this file's space is the canvas's, and the
## other three's is the 3D buffer's. Under `video.aspect = keep` the canvas is letterboxed over a full-width
## buffer and the two rects differ, which is the setting this has never been exercised under: the reasoning says
## the choice is right (an off-screen label should clamp to the edge of the *visible canvas*, not the wider
## buffer behind it), and no run has confirmed it. Recorded as a watch rather than left as an inconsistency a
## reader would try to "fix".
func refresh(camera: Camera3D) -> void:
	if camera == null or _labels.is_empty():
		return

	var viewport_size := camera.get_viewport().get_visible_rect().size
	var bounds := Rect2(
		Vector2(margin, margin), viewport_size - Vector2(margin, margin) * 2.0
	)

	var gathered := _candidates(camera.get_global_transform_interpolated().origin)
	# Which bodies are marked at all, so a moon can tell whether the body it orbits is one of them.
	# The set is not thinned by that: a moon that gives up its label is still marked.
	var marked := {}
	for candidate in gathered:
		marked[(candidate["node"] as Node3D).get_instance_id()] = true

	var entries := _parents_before_their_moons(choose(gathered, pool_size))
	for entry in entries:
		entry["circle"] = _project(entry["node"], camera, viewport_size)

	# Only other labels: a label is placed against its own object, and the HUD is not reserved around.
	var taken: Array[Rect2] = []
	# Where each body's own label ended up, so a moon can tell whether its planet's is what took its
	# space rather than something else.
	var placed := {}

	var marks: Array[Dictionary] = []
	for index in _labels.size():
		var label := _labels[index]
		if index >= entries.size():
			label.visible = false
			continue
		var mark := _place(entries[index], label, marked, viewport_size, bounds, taken, placed)
		if not mark.is_empty():
			marks.append(mark)

	_overlay.marks = marks
	_overlay.queue_redraw()


## The chosen set with **the bodies that orbit something already in it moved to the end**, keeping the
## order within each part. A moon's label yields only to its planet's, so the planet has to be placed
## first for the moon to be able to tell.
func _parents_before_their_moons(entries: Array[Dictionary]) -> Array[Dictionary]:
	var first: Array[Dictionary] = []
	var last: Array[Dictionary] = []
	for entry in entries:
		var node: Node3D = entry["node"]
		var parent: SpacesimSceneBody = orbits.get(node, null)
		var parent_here := parent != null and parent.node != null and _in(entries, parent.node)
		if parent_here:
			last.append(entry)
		else:
			first.append(entry)
	first.append_array(last)
	return first


static func _in(entries: Array[Dictionary], node: Node3D) -> bool:
	for entry in entries:
		if entry["node"] == node:
			return true
	return false


## An object's own screen position, **not clamped**: the ring marks where the thing is, and it is the
## label that stays in view.
func _project(node: Node3D, camera: Camera3D, viewport_size: Vector2) -> Vector2:
	if is_behind(camera, node.global_position):
		# unproject_position mirrors for anything behind the camera, so that case is computed from
		# the camera's own transform instead.
		return viewport_size * 0.5 + screen_direction(camera, node.global_position) * OFF_SCREEN_REACH
	return camera.unproject_position(node.global_position)


## One marker: the ring where the object is, and its label placed clear of everything else.
func _place(
	entry: Dictionary,
	label: Label,
	marked: Dictionary,
	viewport_size: Vector2,
	bounds: Rect2,
	taken: Array[Rect2],
	placed: Dictionary
) -> Dictionary:
	var target: Node3D = entry["node"]
	var circle: Vector2 = entry["circle"]
	var colour := colour_of(int(entry["priority"]))

	label.text = "%s  %s" % [target.name, format_distance(entry["distance"])]
	label.size = label.get_minimum_size()
	# An object over the edge still wants its label in view, so the label gathers at the edge point in
	# the object's direction.
	var anchor := clamp_to_edge(circle, viewport_size, margin)

	# **Only the body a moon orbits can take a moon's space.** The planet's label is the one that
	# stays, because the planet is what tells you where you are — but *only where the two are competing
	# for the same piece of screen*. Near Earth the two rings are well apart and both labels are drawn;
	# by Jupiter, where Io is a pixel from the planet, the moon's nearest spot is the one Jupiter's
	# label already has. **The ring is always drawn**: this is a fact about two names, not about whether
	# the moon is there.
	var parent: SpacesimSceneBody = orbits.get(target, null)
	var parent_box: Variant = null
	if parent != null and parent.node != null:
		parent_box = placed.get(parent.node.get_instance_id())
	if (
		_orbits_a_marked_body(target, int(entry["priority"]), marked)
		and parent_box is Rect2
		and _crowds_its_parent(anchor, label.size, taken, parent_box, bounds)
	):
		label.visible = false
		return {"circle": circle, "color": colour}

	var box := Overlay.place_label(anchor, label.size, taken, bounds)
	taken.append(box)

	label.position = box.position
	label.add_theme_color_override("font_color", colour)
	label.visible = true
	placed[target.get_instance_id()] = box

	var mark := {"circle": circle, "color": colour}
	# **A line only where there is a ring to draw it from.** Off screen the ring is not there, so the
	# label at the edge is the whole marker — and a line to a ring nobody can see points at nothing.
	if Rect2(Vector2.ZERO, viewport_size).has_point(circle):
		var ring := Rect2(
			circle - Vector2.ONE * Overlay.RING_RADIUS, Vector2.ONE * Overlay.RING_RADIUS * 2.0
		)
		mark["start"] = Overlay.border_point(ring, box.get_center())
		mark["end"] = Overlay.border_point(box, circle)
	return mark


## The colour one marker is drawn in. The selected target is the only thing that stands out, which is
## what makes it findable among a screen of others.
func colour_of(priority: int) -> Color:
	return selected_color if priority == Priority.SELECTED else Overlay.COLOR


## Whether the planet's label is what stands between this moon and a label of its own.
##
## The nearest spot beside the moon's ring **ignoring the planet** is worked out, and the answer is
## whether the planet's label has taken it. That is what crowding means here: a moon whose ring is on
## its planet's has nowhere to put a name that is not where the planet's already is, while a moon well
## clear of its planet has its own space and keeps its label.
##
## No room at all — nothing free even with the planet's label set aside — is crowding too: the moon's
## label can only be beside its own ring, or it names something other than what the ring points at.
func _crowds_its_parent(
	anchor: Vector2, size: Vector2, taken: Array[Rect2], parent_box: Rect2, bounds: Rect2
) -> bool:
	var without: Array[Rect2] = []
	for box in taken:
		if box != parent_box:
			without.append(box)
	var spot := Overlay.nearest_free(anchor, size, without, bounds, 1)
	return not spot.has_area() or not Overlay.free_of(spot, taken)


## Whether this marker is a moon whose planet is also marked — the one case where its label yields to
## another rather than arranging itself around it.
##
## The planet is what tells you where you are, so **the parent's label is the one that stays** where the
## two are competing for the same space. A moon is drawn regardless when it is the target — you asked
## for that moon in particular — and when the body it orbits is not marked at all there is nothing to
## compete with.
func _orbits_a_marked_body(node: Node3D, priority: int, marked: Dictionary) -> bool:
	if priority == Priority.SELECTED:
		return false
	var parent: SpacesimSceneBody = orbits.get(node, null)
	if parent == null or parent.node == null:
		return false
	return marked.has(parent.node.get_instance_id())


func _candidates(eye: Vector3) -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	_gather(list, context_targets, Priority.CONTEXT, eye)
	_gather(list, mission_targets, Priority.MISSION, eye)
	if selected != null:
		list.append(
			{"node": selected, "priority": Priority.SELECTED, "distance": eye.distance_to(selected.global_position)}
		)
	return list


func _gather(list: Array[Dictionary], nodes: Array[Node3D], priority: int, eye: Vector3) -> void:
	for node in nodes:
		if node == null:
			continue
		list.append({"node": node, "priority": priority, "distance": eye.distance_to(node.global_position)})


## The keyed union for one frame: one marker per object, highest priority wins, then nearest
## first, then truncated to `limit`.
##
## Keying matters — a body that is both a mission target and in the ambient context group would
## otherwise get two labels stacked on one planet. Priority matters for the cap: capping by
## distance would cut off precisely the off-screen objects the pointers exist for.
static func choose(candidates: Array[Dictionary], limit: int) -> Array[Dictionary]:
	var best := {}
	for candidate in candidates:
		var node: Node3D = candidate["node"]
		var key := node.get_instance_id()
		var held: Variant = best.get(key)
		if held == null or int(candidate["priority"]) > int(held["priority"]):
			best[key] = candidate

	var entries: Array[Dictionary] = []
	for key in best:
		entries.append(best[key])
	entries.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			if int(a["priority"]) != int(b["priority"]):
				return int(a["priority"]) > int(b["priority"])
			return float(a["distance"]) < float(b["distance"])
	)
	if entries.size() > limit:
		entries.resize(limit)
	return entries


## Clamp a viewport point onto the edge of `size`, inset by `margin`, along the line from the centre.
## A point far outside the rectangle lands on the nearest edge, which is the smallest turn that would
## bring it into view. **A point already inside is left exactly where it is.**
##
## That last sentence is the whole of it, and `border_point` does not do it: projecting onto the border
## is right for an off-screen ring and wrong for an on-screen one, where it would throw every label out
## to the edge of the window with a line back to its own object.
static func clamp_to_edge(point: Vector2, size: Vector2, margin: float) -> Vector2:
	var inner := Rect2(Vector2(margin, margin), size - Vector2(margin, margin) * 2.0)
	if inner.size.x <= 0.0 or inner.size.y <= 0.0:
		return size * 0.5
	if inner.has_point(point):
		return point
	return Overlay.border_point(inner, point)


## Whether a point is behind the camera, from the **interpolated** transform the frame is drawn with.
##
## `Camera3D.is_position_behind` reads `get_global_transform()` — the raw physics transform — while
## `unproject_position`, called right next to it in [method _project], reads `get_camera_transform()`,
## which is the *interpolated* one outside the physics frame. With `physics/common/physics_interpolation`
## on those are two different cameras, and a marker near the screen edge could be classified by one and
## projected by the other: it would flicker between its on-screen ring and its off-screen edge label,
## and only sometimes. So the test is made here from the same transform the projection uses.
static func is_behind(camera: Camera3D, target: Vector3) -> bool:
	# Camera space looks down -Z, so anything with a positive z is behind the eye.
	return (camera.get_global_transform_interpolated().affine_inverse() * target).z > 0.0


## Direction in viewport space towards a target, valid even when the target is behind the camera
## — which is the case unproject_position gets wrong.
static func screen_direction(camera: Camera3D, target: Vector3) -> Vector2:
	# Typed explicitly: `get_global_transform_interpolated()` has no inferable return type.
	var local: Vector3 = camera.get_global_transform_interpolated().affine_inverse() * target
	# Camera space looks down -Z, and screen y grows downwards.
	var direction := Vector2(local.x, -local.y)
	if direction.length() < 0.0001:
		return Vector2(0.0, -1.0) # directly behind: any edge will do, take the top
	return direction.normalized()


static func format_distance(metres: float) -> String:
	if is_inf(metres) or is_nan(metres):
		return "--"
	var magnitude := absf(metres)
	if magnitude >= 1.0e9:
		return "%.2f Gm" % (metres / 1.0e9)
	if magnitude >= 1.0e6:
		return "%.2f Mm" % (metres / 1.0e6)
	if magnitude >= 1.0e3:
		return "%.1f km" % (metres / 1.0e3)
	return "%.0f m" % metres
