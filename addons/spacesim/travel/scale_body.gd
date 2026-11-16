class_name SpacesimScaleBody
extends RefCounted
## Something whose proximity sets the local travel unit — a planet, a station, an asteroid.
##
## Which bodies count as significant is content's decision, and **a fragment of an asteroid population
## counts from the moment it exists**: in an empty belt a rock is the only thing there is, and slowing
## down is how you arrive somewhere instead of passing through it. That reverses the older rule here
## ("a pebble should not slow you down"), deliberately — Evert, 2026-11-04: *"the unit setters should
## be the fragments themselves, as soon as they exist ... the speed ramps down instantly."*
##
## **A node is not required.** A body's position is its node's, but a fragment 3 million km out has no
## node at all — it is arithmetic — so [member position] is where a scale body without one is.

## The node this follows, or null for something that has no node and only a [member position].
var node: Node3D
## Where it is in the system frame, when [member node] is null.
var position: Vector3 = Vector3.ZERO
## **How fast it is moving, in the system frame** — and therefore what a ship near it inherits.
##
## The ship's velocity is relative to the body it is nearest, so this is what makes a moving target
## reachable at all: it is carried along with its reference and only has to close the remaining distance.
## Fill it from whatever moves the body, in the same place and the same tick; **zero is correct for
## anything that stands still**, which is everything but a fragment at present.
var velocity: Vector3 = Vector3.ZERO
## What it is called in the readout, when [member node] is null.
var name: String = ""
## **Whether flying into it stops the ship.** A scale body sets the local travel unit either way — that is what
## makes a rock slow the ship as it is approached — but not everything is worth colliding with. A population's
## rock is the case: it sets the unit so the ship can crawl up to one, and there is no physics yet.
## Evert, 2026-11-15: *"I told you many times we are not doing physics yet, so no collisions."*
var solid := true
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
func surface_distance_to(where: Vector3) -> float:
	if node == null:
		return maxf(0.0, position.distance_to(where) - radius)
	return maxf(0.0, node.global_position.distance_to(where) - radius)


## **Height above this body's OWN surface** — the nearest vertex of its mesh, not a mean sphere.
##
## Evert, 2026-11-12: *"height above a rock should be measured to the nearest vertex."* One call a frame, for the
## body already known to be nearest, so the bin behind it is paid for once.
##
## **Beyond one radius the sphere is used**, and that is not laziness: the relief is a fixed number of metres, so
## at altitude it is a fraction of a percent, and the bin's rings would be walking out through empty space to
## reach a shell that is kilometres away. Where it matters — landing, hovering, the last kilometre — the mesh is
## asked.
func surface_distance_mesh(where: Vector3) -> float:
	# **A fragment has no mesh to ask**: it is a circle through the point it was made up at, so its own
	# radius is the honest answer and its relief is tens of metres at most.
	if node == null:
		return maxf(0.0, position.distance_to(where) - radius)
	var local := where - node.global_position
	if surface != null and local.length() <= surface.reach * 1.35:
		return surface.nearest_distance(local)
	return maxf(0.0, local.length() - radius)
