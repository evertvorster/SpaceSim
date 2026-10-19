extends RefCounted
## The patch quadtree: refinement where the eye is, coarse elsewhere, and a budget that holds.
##
## **This is the mechanism the whole LOD story was missing** — `SpacesimIcosphere` draws a body at one
## level for the whole sphere, so approaching it refines everything equally. Evert's report, 2026-10-17:
## *"it suddenly switches to a higher density of triangles, but once only, and for the whole sphere."*
##
## Nothing here needs a GPU or a scene: `select()` is a pure function of (distance, camera direction,
## radius, pixel angle, epsilon), and `build()` is arrays. So the properties that matter are checkable
## as numbers — that the triangles are on the sphere, that the eye's side is finer than the far side,
## that the walk is monotone in distance, that the horizon is exact, and that the budget holds.

const EARTH_RADIUS := 6.371e6
## A 1080-line frame at 70 degrees vertical, which is the number `SpacesimLod` works in.
const PIXEL_ANGLE := 1.2967e-3


func run(h, root: Node) -> void:
	print("  patches")
	_test_the_roots(h)
	_test_the_eye_side_is_finer(h)
	_test_it_is_monotone_in_distance(h)
	_test_the_horizon_is_exact(h)
	_test_the_budget_holds(h)
	_test_the_mesh(h)


## Far enough out that every face is one triangle: the tree's roots, and the same triangles the level
## meshes are built from.
func _test_the_roots(h) -> void:
	# **Not all twenty**: the walk culls over the limb, and from 1e9 m nearly a hemisphere is behind it, so
	# a root or two goes. What the test is for is that the tree IS its roots and not a subdivision.
	var leaves := SpacesimPatches.select(
		1.0e9, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 4.0
	)
	h.check(leaves.size() <= 20 and leaves.size() >= 15,
		"from far enough out the tree is its twenty roots, less the limb (%d)" % leaves.size())
	var area := 0.0
	var unit := true
	for leaf in leaves:
		for point in leaf:
			if absf((point as Vector3).length() - 1.0) > 1.0e-9:
				unit = false
		area += _solid_angle(leaf[0], leaf[1], leaf[2])
	h.check(unit, "and every patch corner is a unit vector")
	# The faces tile the sphere, and the visible ones are most of it from far away: 4 pi is the ceiling and
	# a hemisphere the floor, so anything in that band means "roots, covering the body, no holes doubled".
	h.check(area <= 4.0 * PI + 1.0e-9 and area > 1.8 * PI,
		"and they cover the body rather than a corner of it (%.2f of 4 pi)" % (area / (4.0 * PI)))


## **The whole point.** The same body, the same frame, the same budget: the patches facing the camera
## must be finer than the ones on the far side — which cannot happen to a whole-sphere level.
func _test_the_eye_side_is_finer(h) -> void:
	var distance := EARTH_RADIUS + 2.0e5
	var leaves := SpacesimPatches.select(distance, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 1.0)
	var horizon := acos(EARTH_RADIUS / distance)
	var near_edge := 0.0
	var limb_edge := 0.0
	var limb_patches := 0
	for leaf in leaves:
		var centre: Vector3 = (leaf[0] + leaf[1] + leaf[2]).normalized()
		var edge: float = maxf(
			(leaf[0] as Vector3).angle_to(leaf[1]),
			maxf((leaf[1] as Vector3).angle_to(leaf[2]), (leaf[2] as Vector3).angle_to(leaf[0]))
		)
		# **Angles on both sides of the comparison**: `horizon` is an angle in radians and `dot` is a
		# cosine, and comparing them directly was the first version of this test.
		var from_eye := acos(clampf(centre.dot(Vector3.UP), -1.0, 1.0))
		if from_eye < 0.1:
			near_edge = maxf(near_edge, edge)
		elif from_eye > horizon - 0.05:
			# Toward the limb, where a patch is compressed to almost nothing on screen and the budget says
			# nothing is worth drawing.
			limb_edge = maxf(limb_edge, edge)
			limb_patches += 1
	h.check(near_edge > 0.0 and limb_patches > 0,
		"the walk produced patches under the eye and at the limb (%d at the limb)" % limb_patches)
	h.check(near_edge < limb_edge,
		"and the eye's side is finer than the limb (%.5f rad against %.5f)" % [near_edge, limb_edge])


## Closing in can only add triangles: the budget is per patch, and each one refines on its own error.
func _test_it_is_monotone_in_distance(h) -> void:
	# **The finest triangle under the eye, not the total count.** Closing in *culls* more of the sphere
	# (the horizon tightens) while refining what remains, so the count can fall while the detail rises —
	# the count is the wrong quantity to be monotone, and asserting on it failed for exactly that reason.
	var previous := 1.0
	var monotone := true
	for altitude: float in [1.0e8, 1.0e7, 1.0e6, 1.0e5]:
		var finest := 1.0
		for leaf in SpacesimPatches.select(
			EARTH_RADIUS + altitude, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 2.0
		):
			var centre: Vector3 = (leaf[0] + leaf[1] + leaf[2]).normalized()
			if acos(clampf(centre.dot(Vector3.UP), -1.0, 1.0)) < 0.2:
				finest = minf(finest, maxf(
					(leaf[0] as Vector3).angle_to(leaf[1]),
					maxf((leaf[1] as Vector3).angle_to(leaf[2]), (leaf[2] as Vector3).angle_to(leaf[0]))
				))
		if finest > previous + 1.0e-9:
			monotone = false
		previous = finest
	h.check(monotone, "and the triangles under the eye only get finer as it closes in "
		+ "(%.6f rad at the end)" % previous)


## **The horizon is exact, not approximate**: `dot(u, v) >= R/d` is the limb, and a patch centre below it
## is over the edge of the world. From just above the ground most of the sphere is not visible at all.
func _test_the_horizon_is_exact(h) -> void:
	var distance := EARTH_RADIUS + 1.0e4
	var leaves := SpacesimPatches.select(distance, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 2.0)
	var horizon := acos(EARTH_RADIUS / distance)
	var over_the_limb := 0
	for leaf in leaves:
		var centre: Vector3 = (leaf[0] + leaf[1] + leaf[2]).normalized()
		var extent: float = maxf(
			(leaf[0] as Vector3).angle_to(leaf[1]),
			maxf((leaf[1] as Vector3).angle_to(leaf[2]), (leaf[2] as Vector3).angle_to(leaf[0]))
		)
		# **Widened by the patch's own size**, because the walk is allowed to keep a patch that only
		# straddles the limb: culling to the exact horizon would delete the ground under the camera, and at
		# 10 km a root face is 25 times the whole visible cap.
		if centre.dot(Vector3.UP) < cos(horizon + extent) - 1.0e-9:
			over_the_limb += 1
	h.check(over_the_limb == 0, "at 10 km nothing fully behind the limb is drawn (%d were)" % over_the_limb)
	# A whole-sphere subdivision at this budget would be thousands; the cap is a few hundred. The bound is
	# loose on purpose — what it must catch is the far side coming back, not a tuning change.
	h.check(leaves.size() > 0 and leaves.size() < 2000,
		"and the far side really is gone rather than merely coarse (%d patches)" % leaves.size())


## The budget is what stops "the eye is on the ground" from asking for a million triangles.
func _test_the_budget_holds(h) -> void:
	# At 100 km, which is where the budget is a real constraint: down at 1 m the visible cap is a few
	# square kilometres and the walk never wants many triangles at all.
	var budget := 500
	var leaves := SpacesimPatches.select(
		EARTH_RADIUS + 1.0e5, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 0.5, budget
	)
	h.check(leaves.size() <= budget, "a tight budget is honoured (%d of %d)" % [leaves.size(), budget])
	h.check(leaves.size() > 20, "and it still refines as far as the budget allows (%d)" % leaves.size())


## The mesh, and the two properties a renderer needs: every triangle is on the sphere, and the winding is
## the same one the level meshes use — measured as a positive enclosed volume, which is the only thing
## about winding that can be seen without a picture.
func _test_the_mesh(h) -> void:
	var leaves := SpacesimPatches.select(
		EARTH_RADIUS + 5.0e4, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 2.0
	)
	var mesh := SpacesimPatches.build(leaves)
	var arrays := mesh.surface_get_arrays(0)
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	h.check(points.size() == leaves.size() * 3, "one triangle per leaf, unshared")
	h.check(indices.size() == leaves.size() * 3, "and three indices each")
	# **1e-6, not 1e-9**: an `ArrayMesh` stores vertices as 32-bit floats whatever the engine build is, so
	# a unit vector comes back at 1 ± 3e-8. At Earth's radius that is 0.2 m — no one is going to see it,
	# and asserting double precision here would be asserting something the renderer does not keep.
	var on_sphere := true
	for point in points:
		if absf(point.length() - 1.0) > 1.0e-6:
			on_sphere = false
	h.check(on_sphere, "every vertex is on the unit sphere")
	# **The winding as an outward normal per triangle**, not a signed volume: the mesh is an open shell
	# (the far side is culled), so the divergence sum over it is not an enclosed volume and its sign means
	# nothing. Whether a triangle faces away from the centre is exactly the property `cull_back` depends on.
	# **Measured against the level meshes rather than reasoned about.** Godot's front face is clockwise seen
	# from outside, so the *geometric* normal of a correctly wound triangle points at the centre — which is
	# the opposite of the intuitive test, and the reason `_build` documents its single flip. Comparing signs
	# with a known-good mesh cannot be argued with.
	var patch_side := _winding_side(points, indices)
	var level: ArrayMesh = SpacesimIcosphere.mesh_at(1)
	var level_points: PackedVector3Array = level.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var level_indices: PackedInt32Array = level.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	var level_side := _winding_side(level_points, level_indices)
	h.check(absf(patch_side - level_side) < 1.0e-3,
		"and every triangle is wound the way the level meshes are (%.3f against %.3f)"
			% [patch_side, level_side])
	# **No skirts.** Evert, 2026-10-17: *"the cracks should be so far away that they would not be visible
	# to the camera"* — the step between neighbours is bounded by their two sagittas, each already inside
	# ε, so a skirt is geometry on top of a problem the budget has already bounded.
	h.check(points.size() == leaves.size() * 3,
		"and there is no skirt geometry — three vertices a leaf, nothing else")
	var lines := SpacesimPatches.build_lines(leaves)
	h.check(lines.surface_get_primitive_type(0) == Mesh.PRIMITIVE_LINES,
		"while the wireframe view is lines")
	var segments: PackedVector3Array = lines.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	h.check(segments.size() == leaves.size() * 6, "with three edges per leaf")


## The mean of `normal · centroid` over a mesh — positive when the geometric normals point outward,
## negative when they point inward. One number, comparable between two meshes.
static func _winding_side(points: PackedVector3Array, indices: PackedInt32Array) -> float:
	var total := 0.0
	for i in range(0, indices.size(), 3):
		var a := points[indices[i]]
		var b := points[indices[i + 1]]
		var c := points[indices[i + 2]]
		total += (b - a).cross(c - a).normalized().dot(((a + b + c) / 3.0).normalized())
	return total / maxf(1.0, float(indices.size() / 3))


## The solid angle of a spherical triangle: the l'Huilier form of the spherical excess.
static func _solid_angle(a: Vector3, b: Vector3, c: Vector3) -> float:
	var side_a := b.angle_to(c)
	var side_b := c.angle_to(a)
	var side_c := a.angle_to(b)
	var half_sum := (side_a + side_b + side_c) * 0.5
	var product := tan(half_sum * 0.5) * tan((half_sum - side_a) * 0.5) \
		* tan((half_sum - side_b) * 0.5) * tan((half_sum - side_c) * 0.5)
	return 4.0 * atan(sqrt(maxf(product, 0.0)))
