class_name SpacesimScaleBody
extends RefCounted
## Something whose proximity sets the local travel unit — a planet, a station, an asteroid.
##
## Which bodies count as significant is content's decision (a pebble should not slow you
## down). This type only does the geometry.

var node: Node3D
var radius: float


func _init(p_node: Node3D, p_radius: float) -> void:
	node = p_node
	radius = p_radius


## Distance from `position` to this body's surface, never negative. Distance is measured
## to the surface rather than the centre: a planet 6371 km in radius is not "far away"
## when you are standing on it.
func surface_distance_to(position: Vector3) -> float:
	if node == null:
		return INF
	return maxf(0.0, node.global_position.distance_to(position) - radius)
