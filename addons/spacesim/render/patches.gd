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
## ## A patch is one triangle
##
## The twenty icosahedron faces are the roots. **A patch is a single spherical triangle**, and refining
## it means splitting it into four by its edge midpoints — so the quadtree is over *area*, and the mesh
## is the set of leaves. A leaf small enough that its sagitta projects to fewer than ε pixels is drawn;
## one that is not is subdivided. That is the same error law `SpacesimLod` uses for the whole sphere
## (§2 of the Mesh LOD Plan), applied to a patch instead of a body:
##
##     sagitta = R * phi² / 8        phi = the patch's largest edge, in radians
##     error_px = sagitta / distance / pixel_angle
##
## ## What is deliberately not here yet
##
## - **The tree is walked fresh every rebuild**, not held between frames. It is a pure function of
##   (distance, camera direction, ε), so it cannot go stale — and a walk of ~30 k leaves is cheaper than
##   reconciling two trees. Whether that holds at the triangle counts a real approach reaches is the
##   measurement this exists to make.
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

## Triangles of geometry the mesh may carry — the thing that stops "the eye is on the ground" from
## asking for a million. A leaf contributes one.
const TRIANGLE_BUDGET := 60000

## The cosines and vertices of the twenty root faces, from the icosphere's own construction — so the
## roots are the same triangles at the same places, and a patch cannot drift from the level meshes.
const ROOT_FACES := SpacesimIcosphere.FACES


## **The leaves for one body**: an array of `[a, b, c]` unit directions, one per drawn triangle, ordered
## counter-clockwise seen from outside (the same winding the icosahedron's face list uses).
##
## `camera_direction` is the unit vector from the body's centre toward the camera, `distance` is how far
## the camera is from that centre, and `radius` is the body's. Everything about the camera's *view
## direction* is deliberately absent: the patches are chosen by what is resolvable and visible on the
## sphere, and the frame's own frustum culls the rest for free once they are drawn.
static func select(
	distance: float, camera_direction: Vector3, radius: float,
	pixel_angle: float, epsilon: float, budget: int = TRIANGLE_BUDGET
) -> Array:
	var leaves: Array = []
	if radius <= 0.0 or distance <= radius or pixel_angle <= 0.0 or epsilon <= 0.0:
		return leaves
	# **The horizon, exactly**: a point at unit direction `u` on the sphere is visible from `distance`
	# along `v` if and only if `dot(u, v) >= R / d`. Anything below that is over the limb and is not
	# drawn — which removes most of the sphere at close range.
	#
	# **Widened by each patch's own angular size**, and that widening is load-bearing twice: a root face
	# is 60 degrees across, so its centre is well over the limb while part of it is plainly visible, and
	# at 10 m altitude the *entire* visible cap is a fraction of one face. Culling on the centre alone
	# deleted the ground under the camera.
	var horizon := acos(clampf(radius / distance, -1.0, 1.0))
	# The stack holds `[a, b, c, depth]`; popping from the end keeps it a depth-first walk, so the budget
	# stops the *deepest* work first rather than a whole side of the planet.
	var stack: Array = []
	for face in ROOT_FACES:
		var a: Vector3 = SpacesimIcosphere.VERTICES[int(face[0])]
		var b: Vector3 = SpacesimIcosphere.VERTICES[int(face[1])]
		var c: Vector3 = SpacesimIcosphere.VERTICES[int(face[2])]
		stack.append([a.normalized(), b.normalized(), c.normalized(), 0])
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
	var altitude := maxf(distance - radius, 1.0e-3)
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
		var minimum_edge_squared := _edge_limit_squared(to_patch, pixel_angle, epsilon, radius)
		if centre.dot(camera_direction) < cos(minf(horizon + extent, PI)) \
				or leaves.size() + stack.size() >= budget:
			continue
		if int(patch[3]) >= MAX_DEPTH or edge_squared <= minimum_edge_squared:
			leaves.append([a, b, c])
			continue
		_children(patch, stack)
	return leaves


## **Built from a selection into the mesh the renderer draws.** One surface, so a body is one draw call
## however many patches it took — and every vertex on the unit sphere, scaled by the node as the level
## meshes are, so the two share the double-precision story.
static func build(leaves: Array) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	vertices.resize(leaves.size() * 3)
	normals.resize(leaves.size() * 3)
	indices.resize(leaves.size() * 3)
	var vertex := 0
	var index := 0
	for leaf in leaves:
		var a: Vector3 = leaf[0]
		var b: Vector3 = leaf[1]
		var c: Vector3 = leaf[2]
		# The triangle, **reversed**, because Godot's front face is clockwise seen from outside and the
		# face list is the standard counter-clockwise one — the same single flip `SpacesimIcosphere._build`
		# makes, kept in one place per builder.
		vertex = _push(vertices, normals, vertex, a)
		vertex = _push(vertices, normals, vertex, c)
		vertex = _push(vertices, normals, vertex, b)
		indices[index] = vertex - 3
		indices[index + 1] = vertex - 2
		indices[index + 2] = vertex - 1
		index += 3
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## The same selection as LINES, for the wireframe view — one segment per triangle edge.
static func build_lines(leaves: Array) -> ArrayMesh:
	var segments := PackedVector3Array()
	segments.resize(leaves.size() * 6)
	var write := 0
	for leaf in leaves:
		var a: Vector3 = leaf[0]
		var b: Vector3 = leaf[1]
		var c: Vector3 = leaf[2]
		for pair in [[a, b], [b, c], [c, a]]:
			segments[write] = pair[0]
			segments[write + 1] = pair[1]
			write += 2
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = segments
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh



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


## The four children of a patch: its three corners halved with each other. **The midpoints are
## renormalised**, so every patch corner ever produced is a unit vector and the sphere is the only
## approximation in the pipeline.
static func _children(patch: Array, stack: Array) -> void:
	var a: Vector3 = patch[0]
	var b: Vector3 = patch[1]
	var c: Vector3 = patch[2]
	var depth := int(patch[3]) + 1
	var ab := (a + b).normalized()
	var bc := (b + c).normalized()
	var ca := (c + a).normalized()
	stack.append([a, ab, ca, depth])
	stack.append([ab, b, bc, depth])
	stack.append([ca, bc, c, depth])
	stack.append([ab, bc, ca, depth])


static func _push(vertices: PackedVector3Array, normals: PackedVector3Array, at: int, point: Vector3) -> int:
	vertices[at] = point
	# On a unit sphere the position IS the normal — the same reason the level meshes carry no extra data,
	# and why a coarse patch still shades smoothly.
	normals[at] = point
	return at + 1
