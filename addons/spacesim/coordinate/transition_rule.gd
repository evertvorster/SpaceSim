class_name SpacesimTransitionRule
extends RefCounted
## A distance threshold that moves an observer between two coordinate frames.
##
## Rules are one-way and single-shot: an `ENTER` rule fires when the observer reaches its
## threshold altitude *and* is currently in `from_frame`. Getting back out is a separate `EXIT`
## rule with a different threshold, so hysteresis (no flicker at the boundary) is expressed as
## data rather than special-cased in code.


enum Direction {
	ENTER, ## fires at or below the threshold altitude
	EXIT, ## fires at or above the threshold altitude
}

var from_frame: SpacesimFrame
var to_frame: SpacesimFrame

## Body the altitude is measured from.
var reference: Node3D
## Radius of the reference body, in metres.
var reference_radius: float
## Threshold altitude above the reference body's surface, in metres.
var altitude: float
var direction: Direction = Direction.ENTER


func _init(
	p_from_frame: SpacesimFrame,
	p_to_frame: SpacesimFrame,
	p_reference: Node3D,
	p_reference_radius: float,
	p_altitude: float,
	p_direction: Direction = Direction.ENTER
) -> void:
	from_frame = p_from_frame
	to_frame = p_to_frame
	reference = p_reference
	reference_radius = p_reference_radius
	altitude = p_altitude
	direction = p_direction


## Altitude of a position in the outermost coordinate space, above the reference body's surface.
## Negative inside the body.
func altitude_of(outer_position: Vector3) -> float:
	return reference.global_position.distance_to(outer_position) - reference_radius


## Whether this rule wants the observer moved out of `from_frame` right now.
func matches(outer_position: Vector3) -> bool:
	var current_altitude := altitude_of(outer_position)
	if direction == Direction.ENTER:
		return current_altitude <= altitude
	return current_altitude >= altitude
