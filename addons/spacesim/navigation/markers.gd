class_name SpacesimMarkers
extends Node3D
## Navigation markers: a name and distance for the objects that matter right now.
##
## Two presentations, one projection:
##
## * **on screen** — a [Label3D] at the object's position, billboarded and at a constant screen
##   size, depth tested. Because it sits at the object's *centre*, the object's own projected area
##   eats it: while the body is a dot the label reads cleanly, and once the body outgrows the label
##   it is gone. No distance test, no size test, no fade — visibility falls out of depth ordering.
## * **off screen** — a [Label] in a [CanvasLayer], clamped to the viewport edge in the direction
##   that would bring the object into view. "Smallest angle to get it into view" is what edge
##   clamping already gives.
##
## The set is rebuilt every frame and the nodes are **pooled, not allocated** — a set that changes
## per frame would otherwise churn nodes, and the pool size is the screen-space budget in one
## place.
##
## This is also the first **cross-frame proxy**: a marker is a reference at the object's correct
## apparent position, which is the minimal form of what a distant body will draw as later.
##
## Which objects are marked is the caller's business. This decides only how they are drawn.

## Context is the ambient group (other planets while you are in space, say); a selected target
## outranks a mission objective, which outranks context.
enum Priority { CONTEXT = 0, MISSION = 1, SELECTED = 2 }

const DEFAULT_POOL_SIZE := 12

@export var pool_size := DEFAULT_POOL_SIZE

## Hot: a setter rather than a value read once, so changing it re-applies to the live pool.
@export var font_size := 20:
	set(value):
		font_size = value
		for label in _labels:
			label.font_size = value
		for pointer in _pointers:
			pointer.add_theme_font_size_override("font_size", value - 3)

## Inset from the viewport edge, kept clear so a pointer's own width does not fall off the screen.
var margin := 100.0

## Rebuilt every frame by the caller. Later entries outrank earlier ones.
var context_targets: Array[Node3D] = []
var mission_targets: Array[Node3D] = []
var selected: Node3D = null

var _labels: Array[Label3D] = []
var _pointers: Array[Label] = []
var _pointers_layer: CanvasLayer


func _ready() -> void:
	_build_pool()


## Changing how many markers there is room for is the one setting that cannot be applied in
## place: the pool has to be built again.
func rebuild_pool(new_size: int) -> void:
	var wanted := maxi(new_size, 1)
	if wanted == pool_size and not _labels.is_empty():
		return
	pool_size = wanted
	for label in _labels:
		label.free()
	_labels.clear()
	if _pointers_layer != null:
		_pointers_layer.free()
		_pointers_layer = null
	_pointers.clear()
	_build_pool()


func _build_pool() -> void:
	_pointers_layer = CanvasLayer.new()
	_pointers_layer.name = "Pointers"
	add_child(_pointers_layer)

	for index in pool_size:
		var label := Label3D.new()
		label.name = "Marker%d" % index
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = true
		# Must stay false: depth testing is what lets a body eat its own label.
		label.no_depth_test = false
		label.font_size = font_size
		label.outline_size = 8
		label.outline_modulate = Color(0.0, 0.0, 0.0, 0.9)
		label.modulate = Color(0.85, 0.92, 1.0)
		label.visible = false
		add_child(label)
		_labels.append(label)

		var pointer := Label.new()
		pointer.name = "Pointer%d" % index
		pointer.add_theme_font_size_override("font_size", font_size - 3)
		pointer.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0))
		pointer.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
		pointer.add_theme_constant_override("outline_size", 6)
		pointer.visible = false
		_pointers_layer.add_child(pointer)
		_pointers.append(pointer)


## Rebuild the marker set and draw it. Call once a frame.
func refresh(camera: Camera3D) -> void:
	if camera == null or _labels.is_empty():
		return

	var entries := choose(_candidates(camera.global_position), pool_size)
	var viewport_size := camera.get_viewport().get_visible_rect().size

	for index in _labels.size():
		var label := _labels[index]
		var pointer := _pointers[index]
		if index >= entries.size():
			label.visible = false
			pointer.visible = false
			continue
		_place(entries[index], label, pointer, camera, viewport_size)


## One marker: at the object when it is on screen, on the viewport edge when it is not.
func _place(
	entry: Dictionary, label: Label3D, pointer: Label, camera: Camera3D, viewport_size: Vector2
) -> void:
	var target: Node3D = entry["node"]
	var at: Vector3 = target.global_position
	var text := "%s  %s" % [target.name, format_distance(entry["distance"])]

	# unproject_position mirrors for anything behind the camera, so that case is computed from
	# the camera's own transform instead.
	if camera.is_position_behind(at):
		label.visible = false
		var behind := viewport_size * 0.5 + screen_direction(camera, at) * 1.0e6
		_show_pointer(pointer, text, clamp_to_edge(behind, viewport_size, margin))
		return

	var projected := camera.unproject_position(at)
	if _inside_margin(projected, viewport_size):
		label.text = text
		label.global_position = at
		label.visible = true
		pointer.visible = false
	else:
		label.visible = false
		_show_pointer(pointer, text, clamp_to_edge(projected, viewport_size, margin))


func _inside_margin(projected: Vector2, viewport_size: Vector2) -> bool:
	return (
		projected.x >= margin
		and projected.x <= viewport_size.x - margin
		and projected.y >= margin
		and projected.y <= viewport_size.y - margin
	)


func _show_pointer(pointer: Label, text: String, at: Vector2) -> void:
	pointer.text = text
	pointer.size = pointer.get_minimum_size()
	pointer.position = at - pointer.size * 0.5
	pointer.visible = true


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


## Clamp a viewport point onto the edge of `size`, inset by `margin`. A point far outside the
## rectangle lands on the nearest edge, which is the smallest turn that would bring it into view.
static func clamp_to_edge(point: Vector2, size: Vector2, margin: float) -> Vector2:
	var centre := size * 0.5
	var half := Vector2(maxf(centre.x - margin, 1.0), maxf(centre.y - margin, 1.0))
	var delta := point - centre
	var scale := 1.0
	if absf(delta.x) > 0.0001:
		scale = minf(scale, half.x / absf(delta.x))
	if absf(delta.y) > 0.0001:
		scale = minf(scale, half.y / absf(delta.y))
	return centre + delta * scale


## Direction in viewport space towards a target, valid even when the target is behind the camera
## — which is the case unproject_position gets wrong.
static func screen_direction(camera: Camera3D, target: Vector3) -> Vector2:
	var local := camera.global_transform.affine_inverse() * target
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
