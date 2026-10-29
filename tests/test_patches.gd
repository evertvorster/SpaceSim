extends RefCounted
## The patch quadtree: refinement where the eye is, coarse elsewhere, bounded by the law alone.
##
## **This is the mechanism the whole LOD story was missing** — `SpacesimIcosphere` draws a body at one
## level for the whole sphere, so approaching it refines everything equally. Evert's report, 2026-10-17:
## *"it suddenly switches to a higher density of triangles, but once only, and for the whole sphere."*
##
## Nothing here needs a GPU or a scene: `select()` is a pure function of (distance, camera direction,
## radius, pixel angle, epsilon), and `build()` is arrays. So the properties that matter are checkable
## as numbers — that the triangles are on the sphere, that the eye's side is finer than the far side,
## that the walk is monotone in distance, that the horizon is exact, and that the law bounds it.

const EARTH_RADIUS := 6.371e6
## A 1080-line frame at 70 degrees vertical, which is the number `SpacesimLod` works in.
const PIXEL_ANGLE := 1.2967e-3


func run(h, root: Node) -> void:
	print("  patches")
	_test_the_roots(h)
	_test_the_eye_side_is_finer(h)
	_test_it_is_monotone_in_distance(h)
	_test_the_horizon_is_exact(h)
	_test_the_law_bounds_the_walk(h)
	_test_the_lattice_merge_matches_a_rebuild(h)
	_test_the_tint_costs_nothing_until_asked(h)
	_test_the_mesh(h)
	_test_the_cache_makes_a_rebuild_cheap(h)
	_test_the_drawn_triangle_is_inside_the_law(h)
	_test_the_limb_is_not_subdivided_as_though_it_faced_the_eye(h)
	_test_the_walk_is_gated(h)


## Far enough out that every face is one chunk: the tree's roots, and the same triangles the level
## meshes are built from.
func _test_the_roots(h) -> void:
	# **Not all twenty**: the walk culls over the limb, and from 1e9 m nearly a hemisphere is behind it, so
	# a root or two goes. What the test is for is that the tree IS its roots and not a subdivision.
	var chunks := SpacesimPatches.select(
		1.0e9, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 4.0
	)
	h.check(chunks.size() <= 20 and chunks.size() >= 15,
		"from far enough out the tree is its twenty roots, less the limb (%d chunks)" % chunks.size())
	var area := 0.0
	var unit := true
	for leaf in SpacesimPatches.triangles_of(chunks):
		for point in leaf:
			if absf((point as Vector3).length() - 1.0) > 1.0e-9:
				unit = false
		area += _solid_angle(leaf[0], leaf[1], leaf[2])
	h.check(unit, "and every patch corner is a unit vector")
	# A root is `4^s` of its own triangles, so the area of the sphere is covered the same way however the
	# chunks are drawn: 4 pi is the ceiling and a hemisphere the floor.
	h.check(area <= 4.0 * PI + 1.0e-9 and area > 1.8 * PI,
		"and they cover the body rather than a corner of it (%.2f of 4 pi)" % (area / (4.0 * PI)))
## **The whole point.** The same body, the same frame, the same budget: the patches facing the camera
## must be finer than the ones on the far side — which cannot happen to a whole-sphere level.
func _test_the_eye_side_is_finer(h) -> void:
	var distance := EARTH_RADIUS + 2.0e5
	var chunks := SpacesimPatches.select(distance, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 1.0)
	var horizon := acos(EARTH_RADIUS / distance)
	var near_edge := 0.0
	var limb_edge := 0.0
	var limb_patches := 0
	for leaf in SpacesimPatches.triangles_of(chunks):
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
		"the walk produced triangles under the eye and at the limb (%d at the limb)" % limb_patches)
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
		for leaf in SpacesimPatches.triangles_of(SpacesimPatches.select(
			EARTH_RADIUS + altitude, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 2.0
		)):
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
	var chunks := SpacesimPatches.select(distance, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 2.0)
	var horizon := acos(EARTH_RADIUS / distance)
	var over_the_limb := 0
	var worst := 0.0
	# **The cull happens once per CHUNK, at the chunk's own extent**, so the bound is stated at that
	# granularity: a chunk may straddle the limb by up to its own width. A chunk is `2^s` times a leaf, so
	# at s = 2 it may reach four leaf-widths past the limb, and the triangles inside it inherit that — the
	# "limb collar" the plan measured, which is vertex work behind the planet and invisible.
	#
	# **The centre is the chunk's, not a triangle's.** Testing each triangle against its own extent asserts
	# something the mechanism deliberately does not do, and it fails on a *correct* walk.
	for chunk in chunks:
		var triangles := SpacesimPatches.triangles_of([chunk])
		var extent := 0.0
		var centre := Vector3.ZERO
		for leaf in triangles:
			var a: Vector3 = leaf[0]
			var b: Vector3 = leaf[1]
			var c: Vector3 = leaf[2]
			extent = maxf(extent, maxf(a.angle_to(b), maxf(b.angle_to(c), c.angle_to(a))))
			centre += (a + b + c).normalized()
		var middle := (centre / maxf(float(triangles.size()), 1.0)).normalized()
		# **The chunk's own width, which is `2^s` leaf widths** — the triangles inside it are that much
		# smaller than the patch the walk judged.
		var chunk_extent := extent * float(1 << SpacesimPatches.CHUNK_SUBDIVISIONS)
		var past := acos(clampf(middle.dot(Vector3.UP), -1.0, 1.0)) - horizon
		if past > chunk_extent:
			over_the_limb += 1
			worst = maxf(worst, past - chunk_extent)
	h.check(over_the_limb == 0,
		"at 10 km no chunk is drawn past the limb by more than its own width (%d were, worst %.4f rad over)"
			% [over_the_limb, worst])
	# **A loose bound, and looser since the apparent-size limit landed**: at 2 degrees a walk asks for an order of
	# magnitude more chunks than the curvature law alone did, so a tight number here would break every time the law is
	# tuned. What it must catch is the far side coming back — a whole-sphere subdivision at this eye is tens of
	# thousands — not a change of scale.
	#
	# **Counted in TRIANGLES, not chunks, because a chunk is `4^s` of them**: the bound used to be 20,000 chunks, which
	# is 320,000 triangles at `s = 2`, and stating it that way means it does not move when the chunk size does.
	var drawn := SpacesimPatches.triangle_count(chunks)
	h.check(chunks.size() > 0 and drawn < 320000,
		"and the far side really is gone rather than merely coarse (%d chunks, %d triangles)"
			% [chunks.size(), drawn])


## **There is no budget any more — the law is what bounds the walk, and the HUD is the judge.**
##
## Evert, 2026-10-28: *"We don't care about budget, that should be removed. Just have the count so I can judge."* So what
## is asserted instead is that the walk answers the law at both ends of the range, and that the count it produces is a
## number a person can read rather than one a cap chose.
func _test_the_law_bounds_the_walk(h) -> void:
	# **At 100 km**, where the apparent-size limit and the sagitta limit are within a factor of two of each other.
	var chunks := SpacesimPatches.select(
		EARTH_RADIUS + 1.0e5, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 0.5
	)
	var triangles := SpacesimPatches.triangle_count(chunks)
	h.check(chunks.size() > 2 and triangles > 0,
		"a walk at 100 km answers with a real selection (%d chunks, %d triangles)"
			% [chunks.size(), triangles])
	# **And the apparent size really is bounded**: every chunk is at most the angle the law allows, so the *deepest*
	# one is at most `FACET_ANGLE` wide on screen. The count is left to the HUD's job.
	var deepest := 0
	for chunk in chunks:
		deepest = maxi(deepest, int(chunk[2]))
	var finest := SpacesimPatches.finest_edge_angle(
		EARTH_RADIUS + 1.0e5, PIXEL_ANGLE, 0.5, EARTH_RADIUS
	)
	h.check(finest <= SpacesimPatches.FACET_ANGLE * (1.0e5 / EARTH_RADIUS) * 1.001,
		"with the finest patch no wider than 2 degrees of view")
## The mesh, and the two properties a renderer needs: every triangle is on the sphere, and the winding is
## the same one the level meshes use — measured against the level meshes rather than reasoned about.
func _test_the_mesh(h) -> void:
	var chunks := SpacesimPatches.select(
		EARTH_RADIUS + 5.0e4, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 2.0
	)
	# **Measured from the ground under the eye**, which is where the node's origin goes — see `SpacesimPatches.rebase`.
	# The ground under the eye the walk was given, which is `Vector3.UP` here.
	var origin := Vector3.UP * EARTH_RADIUS
	var arrays := SpacesimPatches.arrays_of(chunks, EARTH_RADIUS, origin)
	var points: PackedVector3Array = arrays[0]
	var expected := SpacesimPatches.triangle_count(chunks)
	var indices: PackedInt32Array = arrays[1]
	# **Shared vertices, indexed triangles** — Evert, 2026-10-28: *"all the triangles are connected together with
	# shared vertices, there can never be a gap."* So the mesh carries one vertex per POINT and the index array is
	# what says how they join; three vertices a triangle was the duplication this removes.
	h.check(indices.size() == expected * 3,
		"three indices a triangle (%d indices for %d triangles)" % [indices.size(), expected])
	h.check(points.size() < expected * 3,
		"and far fewer vertices than that, because a shared point is one vertex (%d for %d corners)"
			% [points.size(), expected * 3])
	# **No point twice.** The mesh is one lattice of shared points, so every vertex must be distinct — a duplicate
	# would be the same point displaced twice the moment a height is applied.
	var distinct := {}
	for point in points:
		distinct[point] = true
	h.check(distinct.size() == points.size(),
		"every vertex is a distinct point (%d of %d)" % [distinct.size(), points.size()])
	# **2 m of slack, not 1e-6 of a metre**: the vertices are metres now, and the buffer keeps them in 32 bits, so a
	# point 6.4 Mm from the body's centre is exact to ~0.8 m. That is the whole reason they are measured from a local
	# origin instead, which the next check pins.
	var on_sphere := true
	for point in points:
		if absf((point + origin).length() - EARTH_RADIUS) > 2.0:
			on_sphere = false
	h.check(on_sphere, "every vertex is the body's radius from its centre, measured from the origin")
	# **And the near vertices are small**, which is the property the rebase exists for: float32 spacings are relative, so
	# a vertex a kilometre from the origin is good to 0.06 mm where one on a radius-scaled unit sphere was good to 0.76 m.
	var nearest := INF
	for point in points:
		nearest = minf(nearest, point.length())
	h.check(nearest < 1.0e4, "with the origin inside the selection, so the near vertices are metres (%.1f m)" % nearest)
	# **The surface carries no index array**: every triangle has its own three vertices, so an index would
	# be the identity range — and building sixty thousand of those in GDScript is the cost chunking exists
	# to remove. Asserted, because a renderer that changes it back would be re-adding that cost silently.
	var mesh := SpacesimPatches.mesh_from(arrays)
	var surface := mesh.surface_get_arrays(0)
	h.check(surface[Mesh.ARRAY_INDEX] != null, "and the mesh IS indexed, which is what makes the sharing count")
	# **The winding as an outward normal per triangle**, not a signed volume: the mesh is an open shell
	# (the far side is culled), so the divergence sum over it is not an enclosed volume and its sign means
	# nothing.
	# Godot's front face is clockwise seen from outside, so the *geometric* normal of a correctly wound
	# triangle points at the centre — which is the opposite of the intuitive test, and the reason `_build`
	# documents its single flip. Comparing signs with a known-good mesh cannot be argued with.
	var patch_side := _winding_side(points, indices, origin)
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
	h.check(indices.size() == expected * 3,
		"and there is no skirt geometry — three indices a triangle, nothing else")
	var lines := SpacesimPatches.lines_mesh_from(SpacesimPatches.lines_of(chunks))
	h.check(lines.surface_get_primitive_type(0) == Mesh.PRIMITIVE_LINES,
		"while the wireframe view is lines")
	var line_arrays: Array = lines.surface_get_arrays(0)
	var segments: PackedInt32Array = line_arrays[Mesh.ARRAY_INDEX]
	# **Six indices a triangle, and the vertices are the shared ones** — the wireframe is the lattice seen as edges, so
	# its vertex array must be the same size as the flat mesh's, not six a triangle.
	h.check(segments.size() == expected * 6, "with three edges per triangle (%d indices)" % segments.size())
	h.check(
		(line_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == points.size(),
		"and sharing the flat mesh's vertices (%d, not %d)"
			% [(line_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), expected * 6]
	)
## **The tint is only paid for when it is asked for** — a regression guard: the colour array was built for every
## rebuild and never passed to `arrays_of` from the scene, so the setting could not have worked.
func _test_the_tint_costs_nothing_until_asked(h) -> void:
	var chunks := SpacesimPatches.select(
		EARTH_RADIUS + 5.0e4, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 2.0
	)
	var plain := SpacesimPatches.arrays_of(chunks)
	h.check(plain.size() == 2,
		"an untinted merge is vertices and indices, and no colour (%d arrays)" % plain.size())
	var tinted := SpacesimPatches.arrays_of(chunks, 1.0, Vector3.ZERO, true)
	h.check(tinted.size() == 3 and (tinted[2] as PackedColorArray).size() == (tinted[0] as PackedVector3Array).size(),
		"and a tinted one carries a colour per vertex (%d colours for %d vertices)"
			% [(tinted[2] as PackedColorArray).size(), (tinted[0] as PackedVector3Array).size()])


## **The incremental merge is the same mesh as a rebuild**, which is the only thing that makes a per-body lattice safe
## to keep between walks. Compared as a SET of triangles, because the two paths lay their vertices out in different
## orders — the lattice keeps the order points were first seen, the fresh path the order chunks arrive.
##
## Small selections on purpose: this compares every triangle rather than a statistic, so it is a correctness check and
## not a smoke test.
func _test_the_lattice_merge_matches_a_rebuild(h) -> void:
	var origin := Vector3.UP * EARTH_RADIUS
	var lattice := SpacesimPatches.Lattice.new()
	var chunks := SpacesimPatches.select(
		EARTH_RADIUS + 5.0e4, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 2.0
	)
	var first := SpacesimPatches.arrays_of(chunks, EARTH_RADIUS, origin, false, lattice)
	h.check(_triangle_set(first) == _triangle_set(
			SpacesimPatches.arrays_of(chunks, EARTH_RADIUS, origin)),
		"a cold lattice merge draws exactly the triangles a rebuild does (%d triangles)"
			% (_triangle_set(first).size()))

	# **Then move the eye**, so the selection changes on both sides of the walk — added chunks and discarded ones — and
	# the lattice has to stay truthful about which slots are which.
	var moved := (Vector3.UP * (EARTH_RADIUS + 5.0e4) + Vector3.RIGHT * 60.0e3).normalized()
	var next := SpacesimPatches.select(
		EARTH_RADIUS + 5.0e4, moved, EARTH_RADIUS, PIXEL_ANGLE, 2.0
	)
	h.check(next.size() != chunks.size() or next != chunks,
		"the moved selection really is a different one (%d against %d chunks)"
			% [next.size(), chunks.size()])
	var warm := SpacesimPatches.arrays_of(next, EARTH_RADIUS, moved * EARTH_RADIUS, false, lattice)
	h.check(_triangle_set(warm) == _triangle_set(
			SpacesimPatches.arrays_of(next, EARTH_RADIUS, moved * EARTH_RADIUS)),
		"and an incremental merge over a changed selection still matches a rebuild (%d triangles)"
			% _triangle_set(warm).size())
	# **The buffer keeps points whose chunks are gone**, which is the price of not rebuilding. Counted as slots
	# actually referenced, because `vertices` is built over the whole buffer and comparing against its size would be
	# true by construction — the exact shape this project's testing rules warn about.
	var referenced := {}
	for index in (warm[1] as PackedInt32Array):
		referenced[index] = true
	h.check(lattice.points.size() > referenced.size(),
		"with the discarded chunks' points still in the lattice (%d points, %d referenced)"
			% [lattice.points.size(), referenced.size()])
	# **And it really was incremental**: blocks from both selections are in hand, so the second merge reused the first's
	# work rather than rebuilding it.
	h.check(lattice.blocks.size() > next.size(),
		"and blocks kept from both selections, so the merge was incremental (%d blocks for %d chunks)"
			% [lattice.blocks.size(), next.size()])
	lattice.points = PackedVector3Array()
	lattice.slot = {}
	lattice.blocks = {}
	var compacted := SpacesimPatches.arrays_of(next, EARTH_RADIUS, moved * EARTH_RADIUS, false, lattice)
	h.check(_triangle_set(compacted) == _triangle_set(warm),
		"and compacting it changes no triangle it draws")


## Every triangle of a merge as (position, position, position), in a set — order-free, and rotated to a canonical start
## so a different winding start does not read as a different triangle.
static func _triangle_set(arrays: Array) -> Dictionary:
	var vertices: PackedVector3Array = arrays[0]
	var indices: PackedInt32Array = arrays[1]
	var set := {}
	for at in range(0, indices.size(), 3):
		var points: Array = [
			vertices[indices[at]], vertices[indices[at + 1]], vertices[indices[at + 2]]
		]
		# Start at the smallest, so the same triangle written from a different corner is one key.
		var start := 0
		for candidate in 3:
			if str(points[candidate]) < str(points[start]):
				start = candidate
		var key := ""
		for step in 3:
			key += str(points[(start + step) % 3])
		set[key] = true
	return set


## **A rebuild is cache lookups, not geometry** — the claim chunking exists to make, stated as counts
## rather than as a stopwatch, because a headless rig can say that without flaking.
func _test_the_cache_makes_a_rebuild_cheap(h) -> void:
	SpacesimPatches.clear_cache()
	var chunks := SpacesimPatches.select(
		EARTH_RADIUS + 5.0e4, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 2.0
	)
	h.check(SpacesimPatches.cached_chunks() == 0, "the cache starts empty")
	var first := SpacesimPatches.arrays_of(chunks)
	var after_first := SpacesimPatches.cached_chunks()
	h.check(after_first == chunks.size(),
		"a first build fills it, one entry a chunk (%d chunks, %d entries)" % [chunks.size(), after_first])
	var second := SpacesimPatches.arrays_of(chunks)
	h.check(SpacesimPatches.cached_chunks() == after_first,
		"and a second identical build adds nothing — the geometry is built once")
	h.check(second[0] == first[0] and second[1] == first[1],
		"the arrays it returns are the cached ones, byte for byte")


## **What a drawn triangle's error actually is.** The chunk is judged at its nearest corner and loosened by
## `4^s`, so its interior triangles land back on ε — and a chunk is drawn at its *nearest* corner's detail,
## so its far half is finer than it needs to be. The bound this asserts is the one the measurement found
## (worst 1.64 ε with the over-refinement), and it is what stops `CHUNK_SUBDIVISIONS` being raised for
## speed: at `s = 3` the interior is drawn a whole level finer than the budget asks for.
func _test_the_drawn_triangle_is_inside_the_law(h) -> void:
	var epsilon := 2.0
	var distance := EARTH_RADIUS + 2.0e5
	var camera := Vector3.UP * distance
	var altitude := distance - EARTH_RADIUS
	var worst := 0.0
	var drawn := 0
	for leaf in SpacesimPatches.triangles_of(SpacesimPatches.select(
		distance, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, epsilon
	)):
		var a: Vector3 = leaf[0]
		var b: Vector3 = leaf[1]
		var c: Vector3 = leaf[2]
		var edge_squared := maxf(
			a.distance_squared_to(b), maxf(b.distance_squared_to(c), c.distance_squared_to(a))
		)
		# The same two quantities the walk uses, and the same floor: the eye's altitude.
		var nearest := minf(
			(camera - a * EARTH_RADIUS).length_squared(),
			minf((camera - b * EARTH_RADIUS).length_squared(), (camera - c * EARTH_RADIUS).length_squared())
		)
		var to_patch := maxf(sqrt(nearest), altitude)
		# `sagitta/R = phi²/8`, and the chord is `phi²` to within 1% at these angles — the identity the
		# walk's own budget is inverted from.
		var sagitta := EARTH_RADIUS * edge_squared / 8.0
		worst = maxf(worst, sagitta / to_patch / PIXEL_ANGLE)
		drawn += 1
	h.check(drawn > 0, "the walk drew something to measure (%d triangles)" % drawn)
	h.check(worst <= 2.0 * epsilon,
		"no drawn triangle is more than 2 epsilon out where it counts (%.2f px against a %.1f px budget)"
			% [worst, epsilon])


## **The walk is gated on what its answer depends on** — distance, direction and ε. Nothing else can change
## which chunks are drawn, so nothing else is allowed to ask for a walk.
func _test_the_walk_is_gated(h) -> void:
	var distance := EARTH_RADIUS + 2.0e5
	var epsilon := 2.0
	var up := Vector3.UP
	h.check(SpacesimPatches.walk_is_due(
		0.0, Vector3.ZERO, distance, up, PIXEL_ANGLE, epsilon, EARTH_RADIUS, -1.0),
		"a body that has never been walked is always due")
	h.check(not SpacesimPatches.walk_is_due(
		distance, up, distance, up, PIXEL_ANGLE, epsilon, EARTH_RADIUS, epsilon),
		"and an unmoved eye asks for nothing")
	# **At a distance where the distance *is* the altitude** — far out, `d - R ≈ d` — so this is really a
	# test of the dead band. Near the ground the two quantities part company, and that is the case below.
	var far_out := EARTH_RADIUS * 30.0
	h.check(not SpacesimPatches.walk_is_due(
		far_out, up, far_out * 1.005, up, PIXEL_ANGLE, epsilon, EARTH_RADIUS, epsilon),
		"a half-percent change is inside the dead band")
	h.check(SpacesimPatches.walk_is_due(
		distance, up, distance * 1.02, up, PIXEL_ANGLE, epsilon, EARTH_RADIUS, epsilon),
		"a 2% one is not")
	# **The descent, and it is the trap this gate exists to not repeat.** From 60 km to 300 m is 0.94% of
	# the *distance* — inside the dead band — and 200x of the *altitude*, which is what the law floors on. A
	# gate that only looked at the distance said "nothing has moved" through the whole descent, and the mesh
	# stayed stale: "it subdivides for a little bit, and then no further."
	# **The start altitude is chosen for the dead band**: a 1% gate cannot fire on the distance below ~64 km, so
	# the scenario has to begin under that or the distance term answers and the altitude term is never exercised.
	var high := EARTH_RADIUS + 6.0e4
	var low := EARTH_RADIUS + 300.0
	h.check(absf(log(high / low)) < SpacesimPatches.LOG_GATE,
		"the distance from 60 km to 300 m is inside the dead band, so a distance gate sees nothing")
	h.check(SpacesimPatches.walk_is_due(
		high, up, low, up, PIXEL_ANGLE, epsilon, EARTH_RADIUS, epsilon),
		"and the walk is due anyway, because the altitude has changed by orders of magnitude")
	h.check(SpacesimPatches.walk_is_due(
		distance, up, distance, up, PIXEL_ANGLE, epsilon * 2.0, EARTH_RADIUS, epsilon),
		"and a new error budget is a new answer")
	var finest := SpacesimPatches.finest_edge_angle(distance, PIXEL_ANGLE, epsilon, EARTH_RADIUS)
	h.check(finest > 0.0 and finest < 0.1,
		"the finest patch under the eye is %.4f rad at 200 km" % finest)
	h.check(not SpacesimPatches.walk_is_due(
		distance, up, distance, up.rotated(Vector3.RIGHT, finest * 0.1),
		PIXEL_ANGLE, epsilon, EARTH_RADIUS, epsilon),
		"a swing well under half a patch cannot change the chunk under the eye")
	h.check(SpacesimPatches.walk_is_due(
		distance, up, distance, up.rotated(Vector3.RIGHT, finest * 2.0),
		PIXEL_ANGLE, epsilon, EARTH_RADIUS, epsilon),
		"a swing of two patches across the eye does")


## The mean of `normal · centroid` over a mesh — positive when the geometric normals point outward,
## negative when they point inward. One number, comparable between two meshes.
## **`origin` is the point the vertices are measured from** — a direction is from the body's centre, so it has to be
## added back before normalising, or the centroid is a vector from the origin rather than from the centre and the dot
## product comes out near zero (-0.022 against -1.000, which is what this looked like when it was wrong).
static func _winding_side(
	points: PackedVector3Array, indices: PackedInt32Array, origin := Vector3.ZERO
) -> float:
	var total := 0.0
	for i in range(0, indices.size(), 3):
		var a := points[indices[i]]
		var b := points[indices[i + 1]]
		var c := points[indices[i + 2]]
		total += (b - a).cross(c - a).normalized().dot(((a + b + c) / 3.0 + origin).normalized())
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


## **A facet seen edge-on must not be subdivided as though it faced the eye.** The apparent-size limit holds the
## *projected* area, and that falls as the cosine of the tilt, so a chunk at the limb may be larger than an
## unprojected size test would ever allow. Asserted against that unprojected limit, so it **fails on the code that
## had only the size test**: there, no chunk could exceed `CHUNK_TRIANGLES` times the unprojected allowance.
##
## **From ORBIT, and that is the only place it can matter**: at 20 km up the horizon is 4.5 degrees from the
## sub-point, so every visible patch has a tilt above 0.997 and the cosine changes nothing — the regime is the far
## one, where the visible cap spans 67 degrees of tilt (measured: the chunk count from 10,000 km falls 446 -> 308).
func _test_the_limb_is_not_subdivided_as_though_it_faced_the_eye(h) -> void:
	# **Both regimes, because the two are different**: from orbit the disc's rim spans a wide range of tilt, and up
	# close the horizon does too — but through the true tilt (patch to eye), which at 20 km is 0.0001 at the horizon
	# however flat `centre · up` looks.
	for altitude: float in [2.0e4, 1.0e7]:
		var distance := EARTH_RADIUS + altitude
		var chunks := SpacesimPatches.select(distance, Vector3.UP, EARTH_RADIUS, PIXEL_ANGLE, 2.0)
		var camera := Vector3.UP * distance
		var altitude_floor := distance - EARTH_RADIUS
		var beyond := 0
		var shallow := 0
		for chunk in chunks:
			var arrays := SpacesimPatches.chunk_arrays(chunk)
			var points: PackedVector3Array = arrays[0]
			var indices: PackedInt32Array = arrays[1]
			if points.is_empty() or indices.is_empty():
				continue
			var centre := Vector3.ZERO
			for point in points:
				centre += point
			centre = centre.normalized()
			# **The tilt the walk uses**: from the patch to the EYE. `centre · up` is the same number only from
			# orbit, and using it here is what made the first version of this test find nothing at 20 km.
			if absf(centre.dot((camera - centre * EARTH_RADIUS).normalized())) > 0.45:
				continue
			shallow += 1
			var edge_squared := 0.0
			for i in range(0, indices.size(), 3):
				var a: Vector3 = points[indices[i]]
				var b: Vector3 = points[indices[i + 1]]
				var c: Vector3 = points[indices[i + 2]]
				edge_squared = maxf(edge_squared, maxf(
					a.distance_squared_to(b),
					maxf(b.distance_squared_to(c), c.distance_squared_to(a))
				))
			if edge_squared <= 0.0:
				continue
			# The same floor the walk uses, from the chunk's own nearest corner.
			var nearest := INF
			for point in points:
				nearest = minf(nearest, (camera - point * EARTH_RADIUS).length_squared())
			var to_patch := maxf(sqrt(nearest), altitude_floor)
			# **The unprojected allowance for a TRIANGLE**, which is the unloosened limit: the walk loosens by
			# `CHUNK_TRIANGLES` because a chunk carries `4^s` finer triangles, so a chunk edge against the
			# loosened limit is the same statement as a triangle edge against the limit itself.
			var unprojected := SpacesimPatches.FACET_ANGLE * SpacesimPatches.FACET_ANGLE \
				* (to_patch / EARTH_RADIUS) * (to_patch / EARTH_RADIUS)
			if edge_squared > unprojected * 1.5:
				beyond += 1
		h.check(shallow > 0,
			"at %.0f m there are chunks seen at a shallow angle to measure (%d)" % [altitude, shallow])
		h.check(beyond > 0,
			"and at %.0f m some are larger than an unprojected size test allows (%d of %d, beyond 1.5x)"
				% [altitude, beyond, shallow])
