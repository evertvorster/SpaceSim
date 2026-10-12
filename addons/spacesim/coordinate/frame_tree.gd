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

var _rules: Array[SpacesimTransitionRule] = []


func add_rule(rule: SpacesimTransitionRule) -> void:
	_rules.append(rule)


## Move the observer into `frame` without consulting any rule. Used for the initial placement.
func enter_frame(frame: SpacesimFrame) -> void:
	var previous := active_frame
	if observer != null:
		if observer.get_parent() == null:
			frame.add_child(observer)
		elif observer.get_parent() != frame:
			# keep_global_transform: the observer does not move when its coordinate space changes.
			observer.reparent(frame, true)
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
