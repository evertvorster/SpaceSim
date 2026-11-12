class_name SpacesimSurfacePoints
extends RefCounted
## **The nearest point of a body's own mesh** — what "height above a rock" is measured to.
##
## Evert, 2026-11-12: *"height above a rock should be measured to the nearest vertex."* A mean radius is wrong by
## the whole relief: 830 m on Phobos, which is the difference between hovering and standing.
##
## **Binned, because the query is per tick.** A linear scan over a body's few thousand vertices would be half a
## millisecond every frame for one body; the bin is the body's own frame cut into cells, and a query walks outward
## a ring at a time and stops as soon as the nearest vertex found is closer than the next ring could possibly be.
## So the answer is the true nearest vertex and the work is a handful of cells.
##
## **What the caller does with it matters more than the structure** — see `SpacesimScaleBody`: the *comparison*
## between bodies stays a sphere (a few hundred metres does not change which body is nearest), and only the
## reported altitude uses this. That keeps the expensive path to one call a frame.

## How many cell rings to walk before giving up. Six cells out is already several body radii for any sane cell
## size, so a query that reaches this is a query that should have used the sphere.
const MAX_RING := 6

var _points: PackedVector3Array
## cell key -> the vertex indices in it
var _cells: Dictionary = {}
var _cell := 1.0
## The furthest vertex from the body's centre, in metres — what a caller needs to know before it asks.
var reach := 0.0


func _init(points: PackedVector3Array, cell_size: float) -> void:
	_points = points
	_cell = maxf(cell_size, 1.0e-3)
	var lists := {}
	for index in points.size():
		var key := _key(points[index])
		if not lists.has(key):
			lists[key] = []
		(lists[key] as Array).append(index)
	for key in lists:
		_cells[key] = PackedInt32Array(lists[key])
	for point in points:
		reach = maxf(reach, point.length())


## **Distance to the nearest vertex**, in the body's own frame (metres from its centre). INF for a body with no
## vertices, which is the honest answer for a shape nothing was built for.
func nearest_distance(from: Vector3) -> float:
	if _points.is_empty():
		return INF
	var here := _key(from)
	var best := INF
	for ring in MAX_RING + 1:
		for dx in range(-ring, ring + 1):
			for dy in range(-ring, ring + 1):
				for dz in range(-ring, ring + 1):
					# The shell only: the inner rings were walked already.
					if maxi(absi(dx), maxi(absi(dy), absi(dz))) != ring:
						continue
					var key := here + Vector3i(dx, dy, dz)
					if not _cells.has(key):
						continue
					for index in (_cells[key] as PackedInt32Array):
						best = minf(best, from.distance_squared_to(_points[index]))
		# **Provably nearest, not nearly nearest**: every cell still unlooked-at is at least `ring` cells away on
		# each axis, so once the best is inside that there is nothing closer left to find.
		if best < INF and float(ring) * _cell >= sqrt(best):
			break
	return sqrt(best) if best < INF else INF


func _key(point: Vector3) -> Vector3i:
	return Vector3i((point / _cell).floor())
