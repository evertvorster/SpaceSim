class_name SpacesimFrameTree
extends Node3D
## Owns the coordinate frames and moves an observer between them as it crosses thresholds.
##
## The frame hierarchy is the scene tree, so Godot resolves the transforms and a switch is a
## reparent that preserves the observer's pose. This node decides *when* a switch happens and which
## frame is current.

## Emitted after a switch, with the frames involved.
signal frame_changed(observer: Node3D, from_frame: SpacesimFrame, to_frame: SpacesimFrame)

## The node whose frame membership is tracked.
@export var observer: Node3D

## Evaluate on every physics tick. Turn off to drive the tree from elsewhere; `evaluate()` stays
## safe to call at any time either way.
@export var automatic: bool = true

## The frame the observer is currently in.
var active_frame: SpacesimFrame

## Frames by id, so a save that names one can find it again. Registered as frames are created — by
## the world for its own, and later by assets for their interiors.
var _frames: Dictionary = {}

var _rules: Array[SpacesimTransitionRule] = []


func register(frame: SpacesimFrame) -> void:
	if not frame.frame_id.is_empty():
		_frames[frame.frame_id] = frame


## The frame with this id, or null. Used when a save names a frame and the loader has to find it.
func frame_by_id(id: String) -> SpacesimFrame:
	return _frames.get(id)


## The frame this id names, or the nearest ancestor of it that exists, so
## `planet:terra/surface` falls back towards the system frame. **A save that names a frame the world
## no longer has is placed at the frame that remains, at its origin** — the stored position would
## mean something else in another frame, so it is not used.
func resolve_frame(id: String) -> SpacesimFrame:
	var candidate := id
	while not candidate.is_empty():
		var frame: SpacesimFrame = _frames.get(candidate)
		if frame != null:
			return frame
		var cut := candidate.rfind("/")
		if cut <= 0:
			break
		candidate = candidate.substr(0, cut)
	return _frames.get(SpacesimFrame.SYSTEM_ID)


func add_rule(rule: SpacesimTransitionRule) -> void:
	_rules.append(rule)


## Put a node into a frame at a position in that frame. Continuity is not wanted here: a save says
## where something is, so the transform is set from it rather than preserved — which is what
## [method enter_frame] does for the observer when it crosses a threshold.
func place_in_frame(subject: Node3D, frame: SpacesimFrame, position: Vector3) -> void:
	if subject == null or frame == null:
		return
	if subject.get_parent() != frame:
		if subject.get_parent() == null:
			frame.add_child(subject)
		else:
			subject.reparent(frame, false)
	subject.position = position
	# **A teleport, not motion.** A save says where something is, so without this the interpolator
	# would render it gliding in from wherever it used to be. Called *after* moving, which is the order
	# the engine asks for.
	subject.reset_physics_interpolation()


## Move the observer into `frame` without consulting any rule. Used for the initial placement.
func enter_frame(frame: SpacesimFrame) -> void:
	var previous := active_frame
	if observer != null:
		if observer.get_parent() == null:
			frame.add_child(observer)
		elif observer.get_parent() != frame:
			# keep_global_transform: the observer does not move when its coordinate space changes.
			observer.reparent(frame, true)
			# The pose is preserved, but the interpolator holds a *global* transform across the change
			# of parent, and `Node.reparent` warns that with `physics/common/physics_interpolation` on
			# a reparent can be rendered as a glide to the new position.
			observer.reset_physics_interpolation()
	active_frame = frame
	if previous != null and previous != frame:
		frame_changed.emit(observer, previous, frame)


## Switch frames if the observer has crossed a threshold. Safe to call every tick.
func evaluate() -> void:
	if observer == null or active_frame == null:
		return
	var outer_position := observer.global_position
	for rule in _rules:
		if rule.from_frame != active_frame:
			continue
		if rule.matches(outer_position):
			enter_frame(rule.to_frame)
			return


func _physics_process(_delta: float) -> void:
	if automatic:
		evaluate()
