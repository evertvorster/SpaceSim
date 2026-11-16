class_name SpacesimParticleCloud
extends RefCounted
## **A ring's particles, made once and never touched again.**
##
## **A belt and a ring are the same content type and different mechanisms**, and the difference is why
## there are two of these: a belt is 6 x 10^25 m^3 of nothing, so its fragments are made up around the
## observer, kept while they are near and forgotten when they leave. A ring is 4 x 10^16 m^2 of sheet that
## is *there*, whole, from any angle — so it is generated at build, in the planet's own frame, and stays.
##
## **That is also what makes the draw cheap**: nothing moves, so the instance transforms are written once,
## and the only per-frame work is a handful of uniforms.
##
## Positions are in the **parent body's frame with the ring's plane as x-y**: `z` is zero. A real ring is
## 10 to 100 m thick, which is 10^-8 of a pixel at every distance a ring is visible from, so the thickness
## is not modelled. It is named here rather than silently dropped.
##
## ## The index, and why it is two orderings
##
## The ship asks for the nearest spots among 300,000 particles, every tick, and a linear scan is tens of
## millions of distance tests a second. So the particles are indexed **by radius** and, inside each radius
## bucket, **by bearing**. A query walks radius buckets outward from the ship's own radius, and inside a
## bucket starts at the ship's bearing and walks both ways.
##
## **Both stops are exact**, not approximate:
##
## - every particle in a bucket is at least `gap` further out in radius than the query, so `gap² + z²` is a
##   true lower bound on all of them — the shell walk can stop the moment that exceeds the worst kept;
## - inside a bucket, two points at radii `r` and `r0` separated by `d` in bearing are
##   `(r-r0)² + 4·r·r0·sin²(d/2)` apart, and the first term is already bounded by the shell test, so
##   `4·r_min·r0·sin²(d/2)` alone can stop a direction.
##
## Evert, 2026-11-15: *"don't tell me you can't track which of 300,000 spots is the closest efficiently. We
## can use rough trigonometry far out, and limit the number you look at up close by sorting them into
## buckets or something."* Measured at 207,000 particles: **116 us** for the 25 nearest, against 563 us with
## the radius ordering alone (`rings/particles`, `becd1ec`).

## Radius buckets across the band. **A couple of hundred**, so a bucket holds a thousand particles and the
## bearing walk inside it reaches the answer in a few dozen.
const RADIUS_BUCKETS := 256

var positions: PackedVector3Array
## Each particle's radius in metres — half its diameter, as a body's is.
var radii: PackedFloat32Array

var _buckets: Array[PackedInt32Array] = []
var _angles: PackedFloat32Array = PackedFloat32Array()
var _inner := 0.0
var _bucket_width := 0.0
var _mean_radius := 0.0


## **Make a population's particles.** Uniform by *area* across the band, not by radius: the particles cover
## a surface, and sampling the radius uniformly would pile them at the inner edge and leave the outer one
## empty.
##
## Seeded from the population, so the same ring is the same ring every load — and two bands differ because
## their seeds do.
static func of(population: SpacesimPopulation) -> SpacesimParticleCloud:
	var cloud := SpacesimParticleCloud.new()
	if population == null or population.particle_count <= 0:
		return cloud
	var inner := population.semi_major_axis.x
	var outer := population.semi_major_axis.y
	if inner <= 0.0 or outer <= inner:
		return cloud

	var rng := RandomNumberGenerator.new()
	rng.seed = population.seed_value
	var count := population.particle_count
	cloud.positions.resize(count)
	cloud.radii.resize(count)
	var inner_squared := inner * inner
	var span := outer * outer - inner_squared
	var squared := 0.0
	for index in count:
		var radius := sqrt(inner_squared + rng.randf() * span)
		var angle := rng.randf() * TAU
		cloud.positions[index] = Vector3(radius * cos(angle), radius * sin(angle), 0.0)
		var diameter := SpacesimRingModel.diameter(
			rng.randf(), population.size_floor, population.size_ceiling, population.size_index
		)
		cloud.radii[index] = diameter * 0.5
		squared += cloud.radii[index] * cloud.radii[index]
	cloud._mean_radius = sqrt(squared / float(count))
	cloud._index(inner, outer)
	return cloud


## The mean radius — `sqrt(mean(r²))`, because a particle's flux goes as its area and the mean that matters
## is the area-weighted one.
func mean_radius() -> float:
	return _mean_radius


func size() -> int:
	return positions.size()


## **The nearest `count` particles to a point in the ring plane, no further than `reach`.**
##
## The one query the game makes: the nearest spot (to promote to a rock), and the next few (to mark on the
## HUD). `reach` bounds it in metres; `INF` means the whole band.
func nearest(where: Vector3, count := 1, reach := INF) -> Array[int]:
	var result: Array[int] = []
	if positions.is_empty() or count <= 0:
		return result
	if _buckets.is_empty() or _bucket_width <= 0.0:
		return result
	var own := sqrt(where.x * where.x + where.y * where.y)
	var start := clampi(int((own - _inner) / _bucket_width), 0, RADIUS_BUCKETS - 1)
	var bearing := atan2(where.y, where.x)
	var plane_squared := where.z * where.z
	var limit := reach * reach
	var best: Array[float] = []
	var best_index: Array[int] = []

	for step in RADIUS_BUCKETS:
		var closest := INF
		var opened := false
		for offset in ([0] if step == 0 else [-step, step]):
			var bucket: int = start + int(offset)
			if bucket < 0 or bucket >= RADIUS_BUCKETS:
				continue
			opened = true
			closest = minf(closest, _radial_gap(bucket, own))
		if not opened:
			break
		# **The shell stop**: the nearest thing left is further than the worst one already kept.
		var bound := limit if best.size() < count else best[best.size() - 1]
		if closest * closest + plane_squared > bound:
			break
		for offset in ([0] if step == 0 else [-step, step]):
			var bucket: int = start + int(offset)
			if bucket < 0 or bucket >= RADIUS_BUCKETS:
				continue
			_scan(bucket, where, bearing, best, best_index, count, limit, plane_squared)

	for index in best_index:
		result.append(index)
	return result


## **The closest point on the band to the ship** — a couple of trigonometry functions, which is all a band
## is. Clamp the ship's radius into `[inner, outer]` and keep its bearing.
##
## Evert, 2026-11-15: *"The ring is a geometric shape. You can locate any point on it that is the closest to
## the ship with a couple of trigonometry functions, and then look for the closest splat to that."* It is
## also why a search from a million kilometres costs the same as one from a hundred: it starts where the
## answer is, not where the ship is.
static func closest_point(where: Vector3, inner: float, outer: float) -> Vector3:
	var radial := Vector2(where.x, where.y)
	var length := radial.length()
	var bearing := radial / length if length > 0.0 else Vector2.RIGHT
	return Vector3(bearing.x, bearing.y, 0.0) * clampf(length, inner, outer)


## **One bucket, searched by bearing.** The list is sorted, so the walk starts at the ship's bearing and goes
## both ways; a direction stops as soon as `4·r_min·r0·sin²(d/2)` alone exceeds the worst kept.
func _scan(
	bucket: int, where: Vector3, bearing: float, best: Array[float], best_index: Array[int],
	count: int, limit: float, plane_squared: float
) -> void:
	var list := _buckets[bucket]
	var size := list.size()
	if size == 0:
		return
	var radius_floor := maxf(_bucket_inner(bucket), 1.0)
	var own := maxf(sqrt(where.x * where.x + where.y * where.y), 1.0)
	var middle := _bearing_position(list, bearing)
	# The two directions are walked separately because each has its own stop.
	for direction in [1, -1]:
		var at := middle if direction > 0 else middle - 1
		while at >= 0 and at < size:
			var index := list[at]
			var gap := absf(_angles[index] - bearing)
			if gap > PI:
				gap = TAU - gap
			var lateral := 2.0 * sqrt(radius_floor * own) * sin(gap * 0.5)
			var bound := limit if best.size() < count else best[best.size() - 1]
			if lateral * lateral + plane_squared > bound:
				break
			var distance := positions[index].distance_squared_to(where)
			if distance <= limit:
				_keep(best, best_index, distance, index, count)
			at += direction


## The first entry of a bucket whose bearing is at or after `bearing`.
func _bearing_position(list: PackedInt32Array, bearing: float) -> int:
	var low := 0
	var high := list.size()
	while low < high:
		var middle := (low + high) / 2
		if _angles[list[middle]] < bearing:
			low = middle + 1
		else:
			high = middle
	return low


## Keep the `count` smallest, in order. A handful of entries, so a linear insert costs nothing.
static func _keep(
	best: Array[float], best_index: Array[int], distance: float, index: int, count: int
) -> void:
	if best.size() >= count and distance >= best[best.size() - 1]:
		return
	var at := 0
	while at < best.size() and best[at] <= distance:
		at += 1
	best.insert(at, distance)
	best_index.insert(at, index)
	if best.size() > count:
		best.resize(count)
		best_index.resize(count)


## The two orderings, built once. See the class comment for why both are needed.
func _index(inner: float, outer: float) -> void:
	_inner = inner
	_bucket_width = maxf((outer - inner) / float(RADIUS_BUCKETS), 0.001)
	_angles.resize(positions.size())
	for index in positions.size():
		_angles[index] = atan2(positions[index].y, positions[index].x)
	_buckets.clear()
	for _bucket in RADIUS_BUCKETS:
		_buckets.append(PackedInt32Array())
	for index in positions.size():
		var local := positions[index]
		var radius := sqrt(local.x * local.x + local.y * local.y)
		var bucket := clampi(int((radius - inner) / _bucket_width), 0, RADIUS_BUCKETS - 1)
		_buckets[bucket].append(index)
	for bucket in RADIUS_BUCKETS:
		# A `PackedInt32Array` has no `sort_custom`, so the ordering goes through a plain Array and back.
		var list: Array = []
		for index in _buckets[bucket]:
			list.append(index)
		list.sort_custom(func(a: int, b: int) -> bool: return _angles[a] < _angles[b])
		var packed := PackedInt32Array()
		packed.resize(list.size())
		for i in list.size():
			packed[i] = list[i]
		_buckets[bucket] = packed


## How much closer a particle in this bucket could be in radius than the query.
func _radial_gap(bucket: int, own: float) -> float:
	var inner := _bucket_inner(bucket)
	var outer := inner + _bucket_width
	if own < inner:
		return inner - own
	if own > outer:
		return own - outer
	return 0.0


func _bucket_inner(bucket: int) -> float:
	return _inner + _bucket_width * float(bucket)
