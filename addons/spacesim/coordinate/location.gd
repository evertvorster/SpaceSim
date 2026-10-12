class_name SpacesimLocation
extends RefCounted
## Where something is: a frame, and a position in it.
##
## A frame that moves carries whatever is in it, so "on a planet" and "carried by a planet" need no
## update code — that is what being parented into a moving frame means (see `Coordinate and Spatial
## Scale`). A thing flying in space is in the system frame with an absolute position.
##
## Turned into words by [method SpacesimWorld.describe], because saying "landed on Nix" needs the
## world's names and the player's assets — and `coordinate/` should not depend on either.

const FIELD_FRAME := "frame"
const FIELD_POSITION := "position"

var frame_id: String
var position: Vector3


func _init(location_frame := "", location_position := Vector3.ZERO) -> void:
	frame_id = location_frame
	position = location_position


func is_set() -> bool:
	return not frame_id.is_empty()


func to_dictionary() -> Dictionary:
	return {FIELD_FRAME: frame_id, FIELD_POSITION: [position.x, position.y, position.z]}


## A location from stored data. Anything unreadable comes back as an unset location rather than an
## error, because a save is not the place to discover that a world moved on.
static func from_dictionary(data: Dictionary) -> SpacesimLocation:
	var coordinates: Array = data.get(FIELD_POSITION, [])
	var position := Vector3.ZERO
	if coordinates.size() >= 3:
		position = Vector3(float(coordinates[0]), float(coordinates[1]), float(coordinates[2]))
	return SpacesimLocation.new(String(data.get(FIELD_FRAME, "")), position)
