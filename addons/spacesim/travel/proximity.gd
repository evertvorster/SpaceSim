class_name SpacesimProximity
extends RefCounted
## How close the nearest significant thing is. The input to the local travel unit.


## The nearest significant body to `position`, or null when there is none.
static func nearest_body(position: Vector3, bodies: Array[SpacesimScaleBody]) -> SpacesimScaleBody:
	var nearest: SpacesimScaleBody = null
	var nearest_distance := INF
	for body in bodies:
		if body == null:
			continue
		var distance := body.surface_distance_to(position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = body
	return nearest


## Distance to the nearest significant surface, or INF when nothing is near enough to
## matter — deep space, which must read as "no limit" rather than "zero" or "infinite
## loop".
static func nearest_surface_distance(position: Vector3, bodies: Array[SpacesimScaleBody]) -> float:
	var nearest_distance := INF
	for body in bodies:
		if body == null:
			continue
		nearest_distance = minf(nearest_distance, body.surface_distance_to(position))
	return nearest_distance
