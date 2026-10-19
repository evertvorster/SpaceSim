class_name SpacesimPatches
extends RefCounted
## **The body surface as a quadtree of triangle patches**, refined where the eye is looking.
##
## `SpacesimIcosphere` draws a whole sphere at one level, which is what the level policy was built for:
## one decision per body, one shared mesh per level. That is a *uniform* tessellation, so closing in gives
## every part of the planet the same triangles — Evert's report, 2026-10-17: *"it suddenly switches to a
## higher density of triangles, but once only, and for the whole sphere."* This is the mechanism that
## replaces it, and it is the thing the icosphere's hierarchical address was chosen for.
##
## ## A chunk is sixteen triangles
##
## The twenty icosahedron faces are the roots. A patch is a spherical triangle and refining it splits it
## into four by its edge midpoints, so the quadtree is over *area* — but **the walk emits CHUNKS, not
## single triangles**: a selection is ~100 chunk references, and each chunk is its own `4^s`-triangle
## mesh, built once and kept. The law is unchanged, loosened by exactly the refinement a chunk carries
## internally:
##
##     sagitta = R * phi² / 8        phi = the patch's largest edge, in radians
##     error_px = sagitta / distance / pixel_angle
##     draw the chunk when sagitta(chunk) <= 4^s · ε · pixel · d
##
## so its own triangles land back on ε. A chunk is emitted when the *chunk* is inside that budget — and
## the chunk is drawn regardless of what its four children wanted, which is the point: the walk is 16x
## smaller than the leaf walk and a rebuild is cache lookups rather than geometry.
##
## **The measured cost, at ε 4/1/0.25 and altitudes 1e8 → 10 m:** `select()` 0.73–11.0 ms before,
## **0.02–1.13 ms** after; a warm `build()` 0.12–3.0 ms; triangles 0.58–1.61x the old leaf count at the
## far end and 8–13x below 10 km, which Evert accepted: *"Triangle count should go up, there will be more
## triangles in the scene."*
##
## ## What is deliberately not here yet
##
## - **The tree is walked fresh whenever the answer could have changed**, not held between frames. It is a
##   pure function of (distance, camera direction, ε), so it cannot go stale — and `walk_is_due` is what
##   keeps a sub-millisecond walk off the frame when none of those have moved.
## - **The walk refines all the way down, and getting there took three corrections** (all measured, all
##   in `select`): the law's distance must be the distance to the *patch*, not to the body's centre; and
##   it must be the distance to the patch's nearest **corner**, not its centre, because the camera sits
##   over an icosahedron vertex so every patch beneath it has its centre two thirds of a patch away. With
##   either mistake the recursion reaches a fixed point and stops: 458 km facets from 20 m up, then 7.8 km
##   from 1 m. It now gives 0.5 km at 10 m and 0.1 km at 1 m, for ~130 leaves and a 0.3 ms walk.
## - **The only decision is "small enough"**, plus the visibility test below. There is no frustum culling
##   of patches outside the field of view yet: the horizon test removes the far side of the body, which is
##   most of it, and the rest of the frame's worth is not worth the bookkeeping until something measures it.
## - **No skirts, and no stitching.** A patch beside a shallower neighbour leaves a T-junction, and the
##   gap it opens is at most the sum of the two neighbours' sagittas — **each of which the walk has
##   already bounded by ε**. So the step is ≤ 2ε pixels by construction: at ε = 1 that is a 2-pixel
##   sliver, and the honest fix if it ever shows is the standard *balance* rule (neighbours never differ
##   by more than one level, halving it again), not a wall of skirt geometry you can see in wireframe.

## How deep the tree may go, before a triangle budget stops it. Each level splits a patch into four, so
## this is the hard ceiling on the finest triangle: 2^-12 of an icosahedron face, which at Earth's radius
## is about 5 m. The budget is what actually stops the walk.
## 2^-20 of a face is about 2 m at Earth's radius, which is the finest a walk from 20 m altitude asks for
## (a 1.3e-4 rad facet) — the budget is what actually stops it.
const MAX_DEPTH := 20

## **How many times a chunk is subdivided internally**, and the one number that trades walk cost against
## over-refinement. `s = 2` was measured, not chosen: the walk is then 16x smaller than the leaf walk
## (already 5–30x on the clock) and each further step would double the over-refinement.
const CHUNK_SUBDIVISIONS := 2

## Triangles in one chunk — `4^s`, and the unit the budget counts in.
const CHUNK_TRIANGLES := 1 << (2 * CHUNK_SUBDIVISIONS)

## **Chunks the cache may hold before it is dropped wholesale.** A cap rather than an LRU, because a chunk
## is cheap to rebuild and the point of the cache is to be off the frame's critical path: `4096` chunks is
## 65k triangles of shared geometry, and a long flight visits many.
const CHUNK_CACHE_LIMIT := 4096

## Triangles of geometry the mesh may carry — the thing that stops "the eye is on the ground" from
## asking for a million. A chunk contributes `CHUNK_TRIANGLES`.
const TRIANGLE_BUDGET := 60000

## The cosines and vertices of the twenty root faces, from the icosphere's own construction — so the
## roots are the same triangles at the same places, and a patch cannot drift from the level meshes.
const ROOT_FACES := SpacesimIcosphere.FACES

## `log(1.1)`: a tenth, as the loose end the plan measured. A change smaller than this cannot move a chunk
## boundary, because the selection is quantised by the tree.
const LOG_TENTH := 0.09531017980432486

## The floor on the eye's altitude, the same one the walk's own distance floor uses — so a descent to the
## ground cannot make the ratio infinite.
const ALTITUDE_FLOOR := 1.0e-3

## **The chunk cache, shared by every body**: chunk geometry is on the unit sphere, so one entry serves a
## moon and a gas giant. Static, and therefore guarded — a rebuild may be on a worker thread.
static var _chunk_cache: Dictionary = {}
static var _chunk_cache_lock := Mutex.new()


## **The chunks for one body**: an array of `[face, path, depth]`, one per drawn chunk.
##
## `face` indexes the twenty roots, `path` is the base-4 digit route down the tree (`""` is the root), and
## together they name a chunk's place — which is all its geometry needs, because chunk geometry is on the
## **unit sphere** and one cached chunk serves every body.
##
## `camera_direction` is the unit vector from the body's centre toward the camera, `distance` is how far
## the camera is from that centre, and `radius` is the body's. Everything about the camera's *view
## direction* is deliberately absent: the patches are chosen by what is resolvable and visible on the
## sphere, and the frame's own frustum culls the rest for free once they are drawn.
static func select(
	distance: float, camera_direction: Vector3, radius: float,
	pixel_angle: float, epsilon: float, budget: int = TRIANGLE_BUDGET
) -> Array:
	var chunks: Array = []
	if radius <= 0.0 or distance <= radius or pixel_angle <= 0.0 or epsilon <= 0.0:
		return chunks
	# **The horizon, exactly**: a point at unit direction `u` on the sphere is visible from `distance`
	# along `v` if and only if `dot(u, v) >= R / d`. Anything below that is over the limb and is not
	# drawn — which removes most of the sphere at close range.
	#
	# **Widened by each patch's own angular size**, and that widening is load-bearing twice: a root face
	# is 60 degrees across, so its centre is well over the limb while part of it is plainly visible, and
	# at 10 m altitude the *entire* visible cap is a fraction of one face. Culling on the centre alone
	# deleted the ground under the camera.
	var horizon := acos(clampf(radius / distance, -1.0, 1.0))
	# The stack holds `[a, b, c, depth, face, path]`; popping from the end keeps it a depth-first walk, so
	# the budget stops the *deepest* work first rather than a whole side of the planet.
	var stack: Array = []
	for index in ROOT_FACES.size():
		var face: Array = ROOT_FACES[index]
		stack.append([
			SpacesimIcosphere.VERTICES[int(face[0])].normalized(),
			SpacesimIcosphere.VERTICES[int(face[1])].normalized(),
			SpacesimIcosphere.VERTICES[int(face[2])].normalized(),
			0, index, ""
		])
	# **The patch's OWN distance, per patch.** The law is `sagitta / (distance to the patch) / pixel`, and
	# using the distance to the body's centre is what stopped the refinement dead: from 20 m up, the patch
	# under the camera is 20 m away and the body is 6,371 km away, so the budget thought a 458 km-wide facet
	# was inside half a pixel. It was 159,000 pixels out.
	var camera := camera_direction * distance
	# The eye's height above the surface, and **the floor for any patch's distance**. The eye is outside the
	# body, so no part of the sphere is nearer than this — which is what stops the walk converging: a
	# patch's *centre* is never under the camera (the camera sits over an icosahedron vertex, so every
	# patch centre is at least two thirds of a patch away), so a centre-to-eye distance alone settles at
	# `phi ~ 5.4 epsilon p` and then refines no further, whatever the altitude. Measured: 15.6 km facets
	# from 1 m up.
	var altitude := maxf(distance - radius, ALTITUDE_FLOOR)
	# **The loosened budget that makes a chunk legal**: its own triangles are `4^s` finer than the chunk, so
	# a chunk may be `4^s` times larger than a leaf and its interior still lands on ε.
	var loosen := float(CHUNK_TRIANGLES)
	# A chunk at depth `d` carries triangles at depth `d + s`, so the ceiling moves up by `s` to keep the
	# finest triangle where it was.
	var depth_ceiling := MAX_DEPTH - CHUNK_SUBDIVISIONS
	while not stack.is_empty():
		var patch: Array = stack.pop_back()
		var a: Vector3 = patch[0]
		var b: Vector3 = patch[1]
		var c: Vector3 = patch[2]
		var edge_squared := maxf(
			a.distance_squared_to(b), maxf(b.distance_squared_to(c), c.distance_squared_to(a))
		)
		# The patch's angular size, from its own chord — the same small-angle identity the budget uses.
		var extent := sqrt(edge_squared)
		var centre := (a + b + c).normalized()
		# **How far the eye is from THIS patch — its nearest CORNER, not its centre.** The centre is the wrong
		# point whenever the eye is over the patch: the camera sits above an icosahedron vertex, so every
		# patch under it has its centre two thirds of a patch away, and a centre-to-eye distance settles at
		# `phi ~ 3 epsilon p` and refines no further (measured: 7.8 km facets from 1 m up). The nearest corner
		# of the patch below the eye *is* the point below the eye, so its distance is the altitude.
		var nearest_corner := minf(
			(camera - a * radius).length_squared(),
			minf((camera - b * radius).length_squared(), (camera - c * radius).length_squared())
		)
		var to_patch := maxf(sqrt(nearest_corner), altitude)
		var minimum_edge_squared := loosen * _edge_limit_squared(to_patch, pixel_angle, epsilon, radius)
		# **The budget counts TRIANGLES, not entries.** A selection is a hundred references, so comparing the
		# entry count against a triangle budget would let a walk through at 16x its cost.
		if centre.dot(camera_direction) < cos(minf(horizon + extent, PI)) \
				or (chunks.size() + stack.size()) * CHUNK_TRIANGLES >= budget:
			continue
		if int(patch[3]) >= depth_ceiling or edge_squared <= minimum_edge_squared:
			chunks.append([int(patch[4]), String(patch[5]), int(patch[3])])
			continue
		_children(patch, stack)
	return chunks


## **Whether the walk has to run again at all** — the gate that keeps even a sub-millisecond walk off the
## frame when nothing about its answer has moved.
##
## The answer is a pure function of three things: the distance, the eye's direction, and ε (plus the
## wireframe flag, which changes the mesh rather than the selection). So it needs recomputing when the
## distance has moved by a tenth, or when the eye has swung by half the finest patch it is asking for —
## and `finest_edge_angle` is that patch, from the walk's own law.
static func walk_is_due(
	last_distance: float, last_direction: Vector3,
	distance: float, direction: Vector3,
	pixel_angle: float, epsilon: float, radius: float, last_epsilon: float
) -> bool:
	if last_distance <= 0.0 or last_direction.is_zero_approx():
		return true
	if not is_equal_approx(epsilon, last_epsilon):
		return true
	# A tenth is the loose end the plan measured: the selection is quantised by the tree, so a change
	# smaller than this cannot move a chunk boundary.
	if absf(log(distance / last_distance)) > LOG_TENTH:
		return true
	# **And the ALTITUDE separately, which is not the same quantity and cannot be inferred from the
	# distance.** Near the ground `log(d / R)` is flat — a 2.5% change in distance is a 500x change in
	# altitude — while the law's floor is the altitude, so a gate on the distance alone says "nothing has
	# moved" through the entire descent. That is the trap that was already paid for once with a rebuild key
	# bucketed on `log(d/R)`; this is the same mistake one layer up, and it is why both are tested.
	var last_altitude := maxf(last_distance - radius, ALTITUDE_FLOOR)
	var altitude := maxf(distance - radius, ALTITUDE_FLOOR)
	if absf(log(altitude / last_altitude)) > LOG_TENTH:
		return true
	return last_direction.angle_to(direction) > 0.5 * finest_edge_angle(
		distance, pixel_angle, epsilon, radius
	)


## **The smallest patch the eye is asking for, in radians** — the angle the walk's own law converges to.
## Half of it is how far the eye may swing before the chunk under it changes.
static func finest_edge_angle(
	distance: float, pixel_angle: float, epsilon: float, radius: float
) -> float:
	return sqrt(_edge_limit_squared(maxf(distance - radius, ALTITUDE_FLOOR), pixel_angle, epsilon, radius))


## **The cached geometry for one chunk**: `[vertices, normals]` on the **unit sphere**, so one cached
## chunk serves every body. Thread safe: the lock is taken for the lookup and the store, **not** while the
## geometry is generated — two threads that miss the same chunk twice do the same work and store the same
## answer, whereas holding the lock through the build would serialise every body behind one.
static func chunk_arrays(chunk: Array) -> Array:
	var key := "%d/%s" % [int(chunk[0]), String(chunk[1])]
	_chunk_cache_lock.lock()
	var cached: Array = _chunk_cache.get(key, [])
	_chunk_cache_lock.unlock()
	if not cached.is_empty():
		return cached
	var arrays := _chunk_arrays_for(chunk)
	_chunk_cache_lock.lock()
	if _chunk_cache.size() >= CHUNK_CACHE_LIMIT:
		_chunk_cache.clear()
	_chunk_cache[key] = arrays
	_chunk_cache_lock.unlock()
	return arrays


## How many chunks are cached — the instrument that says a rebuild is cache lookups and not geometry.
static func cached_chunks() -> int:
	_chunk_cache_lock.lock()
	var count := _chunk_cache.size()
	_chunk_cache_lock.unlock()
	return count


static func clear_cache() -> void:
	_chunk_cache_lock.lock()
	_chunk_cache.clear()
	_chunk_cache_lock.unlock()


## One chunk's triangles, in the mesh's own winding, on the unit sphere.
static func _chunk_arrays_for(chunk: Array) -> Array:
	var face: Array = ROOT_FACES[int(chunk[0])]
	var a: Vector3 = SpacesimIcosphere.VERTICES[int(face[0])].normalized()
	var b: Vector3 = SpacesimIcosphere.VERTICES[int(face[1])].normalized()
	var c: Vector3 = SpacesimIcosphere.VERTICES[int(face[2])].normalized()
	# **The same child order the walk uses**, so a chunk's geometry cannot disagree with the tree that
	# selected it.
	var route := String(chunk[1])
	for index in route.length():
		var kids := _child_triangles(a, b, c)
		var kid: Array = kids[int(route[index])]
		a = kid[0]
		b = kid[1]
		c = kid[2]
	var leaves: Array = []
	var stack: Array = [[a, b, c, 0]]
	while not stack.is_empty():
		var patch: Array = stack.pop_back()
		if int(patch[3]) >= CHUNK_SUBDIVISIONS:
			leaves.append(patch)
			continue
		for kid in _child_triangles(patch[0], patch[1], patch[2]):
			stack.append([kid[0], kid[1], kid[2], int(patch[3]) + 1])
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	vertices.resize(leaves.size() * 3)
	normals.resize(leaves.size() * 3)
	var at := 0
	for leaf in leaves:
		# **Reversed**, because Godot's front face is clockwise seen from outside and the face list is the
		# standard counter-clockwise one — the same single flip `SpacesimIcosphere._build` makes.
		for point in [leaf[0], leaf[2], leaf[1]]:
			vertices[at] = point
			# On a unit sphere the position IS the normal — the same reason the level meshes carry no
			# extra data, and why a coarse patch still shades smoothly.
			normals[at] = point
			at += 1
	return [vertices, normals]


## **A selection as one set of arrays** — the merged vertices and normals for the whole body, and the one
## expensive step in a rebuild. Pure and safe on a worker thread: it reads the chunk cache (which locks)
## and touches no node.
static func arrays_of(chunks: Array) -> Array:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	for chunk in chunks:
		var arrays := chunk_arrays(chunk)
		vertices.append_array(arrays[0])
		normals.append_array(arrays[1])
	return [vertices, normals]


## The same selection as line segments, for the wireframe view — one segment per triangle edge.
static func lines_of(chunks: Array) -> Array:
	var segments := PackedVector3Array()
	for chunk in chunks:
		var vertices: PackedVector3Array = chunk_arrays(chunk)[0]
		var index := 0
		while index + 2 < vertices.size():
			var a := vertices[index]
			var c := vertices[index + 1]
			var b := vertices[index + 2]
			segments.append(a)
			segments.append(b)
			segments.append(b)
			segments.append(c)
			segments.append(c)
			segments.append(a)
			index += 3
	return [segments]


## **One surface, so a body is one draw call however many chunks it took** — and every vertex on the unit
## sphere, scaled by the node as the level meshes are.
##
## **Non-indexed on purpose.** Every triangle already carries its own three vertices, so an index array
## would be the identity range — and building that for sixty thousand triangles in GDScript is the very
## cost chunking exists to remove.
static func mesh_from(arrays: Array) -> ArrayMesh:
	var surface := []
	surface.resize(Mesh.ARRAY_MAX)
	surface[Mesh.ARRAY_VERTEX] = arrays[0]
	surface[Mesh.ARRAY_NORMAL] = arrays[1]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface)
	return mesh


static func lines_mesh_from(arrays: Array) -> ArrayMesh:
	var surface := []
	surface.resize(Mesh.ARRAY_MAX)
	surface[Mesh.ARRAY_VERTEX] = arrays[0]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, surface)
	return mesh


## **A selection expanded to flat triangles**, for the tests and probes — so the geometric assertions keep
## their intent without reading chunk internals.
static func triangles_of(chunks: Array) -> Array:
	var triangles: Array = []
	for chunk in chunks:
		var vertices: PackedVector3Array = chunk_arrays(chunk)[0]
		var index := 0
		while index + 2 < vertices.size():
			# The mesh winding is reversed; the tree's own is (a, b, c).
			triangles.append([vertices[index], vertices[index + 2], vertices[index + 1]])
			index += 3
	return triangles


## How many triangles a selection draws — the number the budget is spent in.
static func triangle_count(chunks: Array) -> int:
	return chunks.size() * CHUNK_TRIANGLES


## **The largest edge a patch may have and still be inside the budget**, squared, inverted from the law
## so the per-patch test is a comparison and no trigonometry.
##
## `sagitta = R phi²/8` and the budget is `sagitta_max = epsilon * pixel_angle * patch_distance`, so
## `phi² = 8 epsilon pixel_angle patch_distance / R`. A patch's largest edge *chord* is `4 sin²(phi/2)`,
## which is `phi²` to within 1% for the angles a patch ever has, so the squared chord is compared
## directly.
##
## **`patch_distance`, not the distance to the body's centre.** That distinction is the difference between
## a mechanism and a decoration: see [method select].
static func _edge_limit_squared(
	distance: float, pixel_angle: float, epsilon: float, radius: float
) -> float:
	return 8.0 * epsilon * pixel_angle * distance / radius


## **The one definition of the child order**, used by the walk and by the chunk mesh, so a chunk's
## triangles cannot disagree with the tree that selected it.
##
## **The midpoints are renormalised**, so every patch corner ever produced is a unit vector and the sphere
## is the only approximation in the pipeline.
static func _child_triangles(a: Vector3, b: Vector3, c: Vector3) -> Array:
	var ab := (a + b).normalized()
	var bc := (b + c).normalized()
	var ca := (c + a).normalized()
	return [[a, ab, ca], [ab, b, bc], [ca, bc, c], [ab, bc, ca]]


## The four children of a patch, pushed for the walk — each carrying its face, its route and its depth.
static func _children(patch: Array, stack: Array) -> void:
	var depth := int(patch[3]) + 1
	var face: int = patch[4]
	var path: String = patch[5]
	var kids := _child_triangles(patch[0], patch[1], patch[2])
	for digit in kids.size():
		var kid: Array = kids[digit]
		stack.append([kid[0], kid[1], kid[2], depth, face, path + str(digit)])


static func _push(vertices: PackedVector3Array, normals: PackedVector3Array, at: int, point: Vector3) -> int:
	vertices[at] = point
	# On a unit sphere the position IS the normal — the same reason the level meshes carry no extra data,
	# and why a coarse patch still shades smoothly.
	normals[at] = point
	return at + 1
