class_name SpacesimScaleBody
extends RefCounted
## Something whose proximity sets the local travel unit — a planet, a station, an asteroid.
##
## Which bodies count as significant is content's decision (a pebble should not slow you
## down). This type only does the geometry.

var node: Node3D
var radius: float
## **A body's own surface, when it has an irregular one** — the vertices of its mesh, binned for a per-tick query.
## Null for a body that really is a sphere. See [method surface_distance_mesh].
var surface: SpacesimSurfacePoints


func _init(p_node: Node3D, p_radius: float, p_surface: SpacesimSurfacePoints = null) -> void:
	node = p_node
	radius = p_radius
	surface = p_surface


## Distance from `position` to this body's surface, never negative. Distance is measured
## to the surface rather than the centre: a planet 6371 km in radius is not "far away"
## when you are standing on it.
##
## **This is the COMPARISON, and it stays a sphere on purpose.** It is asked once per body per tick to decide
## which body is nearest, and a relief of a few hundred metres does not change that answer — while asking the
## mesh of thirteen bodies would. The reported altitude is [method surface_distance_mesh].
func surface_distance_to(position: Vector3) -> float:
	if node == null:
		return INF
	return maxf(0.0, node.global_position.distance_to(position) - radius)


## **Height above this body's OWN surface** — the nearest vertex of its mesh, not a mean sphere.
##
## Evert, 2026-11-12: *"height above a rock should be measured to the nearest vertex."* One call a frame, for the
## body already known to be nearest, so the bin behind it is paid for once.
##
## **Beyond one radius the sphere is used**, and that is not laziness: the relief is a fixed number of metres, so
## at altitude it is a fraction of a percent, and the bin's rings would be walking out through empty space to
## reach a shell that is kilometres away. Where it matters — landing, hovering, the last kilometre — the mesh is
## asked.
func surface_distance_mesh(position: Vector3) -> float:
	if node == null:
		return INF
	var local := position - node.global_position
	if surface != null and local.length() <= surface.reach * 1.35:
		return surface.nearest_distance(local)
	return maxf(0.0, local.length() - radius)
