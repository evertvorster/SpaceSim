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

## **The ring search has no constant limit, and that constant is what broke the ship.**
##
## It used to stop at six rings. With a cell of `0.12 x radius` the body's own surface lies **eight** rings from the
## centre, so the search could not even reach it — every such query answered INF. And INF is not a quiet wrong
## number: `SpacesimTravelScale.local_length` reads a non-finite distance as the band's MAXIMUM, so the ship's speed
## became `1e13 / 10` m/s and one tick moved it 1.7e10 m. Evert, 2026-11-12: *"suddenly I was transported quite the
## distance away from the moons & mars"* — that was this, near the Martian moons, and again near Saturn.
const MAX_RING := 40

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
	# **Enough rings to reach the whole body from here.** Every vertex is within `from.length() + reach` of the
	# query, so that is the distance the search must be able to cover — derived from the geometry rather than a
	# number in a constant. The break below still stops it as soon as the nearest found is provably nearest, so a
	# query near the surface costs one or two rings and only a deep or a thin direction pays more.
	var limit := mini(int(ceil((from.length() + reach) / _cell)) + 1, MAX_RING)
	var best := INF
	for ring in limit:
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
	# **Never not-a-number.** A caller cannot tell a failed search from a real answer, and this one's caller turns
	# it into speed. The bounding sphere is the honest floor: wrong by the relief, and finite.
	return sqrt(best) if best < INF else maxf(0.0, from.length() - reach)


func _key(point: Vector3) -> Vector3i:
	return Vector3i((point / _cell).floor())
