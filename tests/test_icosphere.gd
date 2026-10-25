extends RefCounted
## The icosphere: levels built once, closed, and measured against the sphere they approximate —
## including its WINDING, which is the one property that fails invisibly.
##
## **The point of testing this headlessly is that the geometry can be measured rather than predicted.**
## A level's relative sagitta times its triangle count is a fact about the built mesh, and the product
## is what the pixel error budget was ever derived from. The per-body law that read it is gone
## (2026-10-25); the relation it stood on is still the thing worth pinning.


func run(h, root: Node) -> void:
	print("  icosphere")

	var meshes := []
	for level in 6:
		meshes.append(SpacesimIcosphere.mesh_at(level))

	# --- built once, and the same object every time ------------------------------------------------
	# A level change has to be a pointer assignment. `SphereMesh` regenerates on a property change,
	# which is what would make adaptive detail cost a rebuild per body per crossing.
	h.check(SpacesimIcosphere.mesh_at(3) == meshes[3],
		"asking for a level twice returns the SAME mesh, so a level change is a pointer assignment")
	h.check(meshes[5] != null and meshes[0] != meshes[5], "and two levels are two meshes")
	h.check(SpacesimIcosphere.built_levels() >= 6, "six levels are built")
	h.check(SpacesimIcosphere.mesh_at(99) == SpacesimIcosphere.mesh_at(SpacesimLod.MAX_LEVEL),
		"and a level past the last is clamped to the headroom level rather than built unbounded")

	# --- the counts, against the law, and against Euler --------------------------------------------
	var vertex_counts := []
	var closed := true
	var on_sphere := true
	var consistent := true
	var counts_match := true
	for level in 6:
		var mesh: ArrayMesh = meshes[level]
		var arrays := mesh.surface_get_arrays(0)
		var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var faces := indices.size() / 3
		vertex_counts.append(points.size())

		if faces != SpacesimLod.triangles_at(level):
			counts_match = false

		for point in points:
			if absf(point.length() - 1.0) > 1.0e-6:
				on_sphere = false

		# **Watertight, and this is the check the midpoint cache exists for.** Every edge of a closed
		# triangulated sphere belongs to exactly two triangles; a duplicated midpoint would leave edges
		# used once, which is a crack at the silhouette.
		var edges := {}
		for i in range(0, indices.size(), 3):
			for k in 3:
				var a := indices[i + k]
				var b := indices[i + (k + 1) % 3]
				var key := Vector2i(mini(a, b), maxi(a, b))
				edges[key] = int(edges.get(key, 0)) + 1
		for key in edges:
			if edges[key] != 2:
				closed = false

		for i in range(0, indices.size(), 3):
			var a := points[indices[i]]
			var b := points[indices[i + 1]]
			var c := points[indices[i + 2]]
			# **All faces the SAME way round, whichever way that is** — the sign itself is not the
			# invariant, because Godot's front face is clockwise and the standard icosahedron is not.
			# Which way it lands is measured against `SphereMesh` below, since that is the mesh every
			# material here was written for; this check is only that no triangle disagrees with its
			# neighbours.
			if signf(a.dot((b - a).cross(c - a))) != signf(points[indices[0]].dot(
					(points[indices[1]] - points[indices[0]]).cross(
						points[indices[2]] - points[indices[0]]))):
				consistent = false

	var wanted_counts := []
	for level in 6:
		wanted_counts.append(SpacesimLod.triangles_at(level))
	h.check(counts_match, "every level has exactly the law's triangle count: %s" % [wanted_counts])
	h.check(vertex_counts == [12, 42, 162, 642, 2562, 10242],
		"and Euler's `V = F/2 + 2` vertex counts, so no vertex is duplicated: %s" % [vertex_counts])
	h.check(on_sphere, "every vertex is on the unit sphere to 1e-6 — the midpoints are projected")
	h.check(closed,
		"and every edge belongs to exactly two triangles, so the surface is CLOSED — no seam, no crack, "
		+ "which is what the midpoint cache is for")
	h.check(consistent,
		"with every face wound the same way round, so no triangle is inside out relative to its neighbours")

	# --- the winding, against the mesh every material here was written for ---------------------------
	# **`body_surface` culls back faces and `body_atmosphere` culls front ones**, and both were written
	# against Godot's own `SphereMesh`. A mesh wound the other way renders inside out — and a sphere seen
	# inside out still looks like a disc, so the symptom does not announce itself. Measured by comparing
	# the sign of the enclosed volume, because that is the one thing about winding that is measurable
	# without a render.
	var reference := SphereMesh.new()
	reference.radius = 1.0
	reference.height = 2.0
	reference.radial_segments = 16
	reference.rings = 8
	var theirs := signed_volume(reference)
	var ours := signed_volume(meshes[1])
	print("    ---- winding: SphereMesh %.4f against icosphere %.4f ----" % [theirs, ours])
	h.check(signf(theirs) == signf(ours),
		"the icosphere is wound the SAME way as SphereMesh, which is the convention the materials assume")

	# --- the approximation, measured -----------------------------------------------------------------
	# The sagitta has to fall as the square of the facet width, which is what makes the whole law work:
	# error falls as `phi^2` while the triangle count rises as `1/phi^2`. Four triangles per parent
	# means half the facet width, so a quarter of the deviation. **Checked for the levels where the law
	# applies**: the ratio is 4 to within 1% from level 2 up, but an icosahedron's own 20 facets are not
	# equal in solid angle to their children, so the coarse end does not obey it — 0 to 1 measures 3.12.
	# That is a property of the primitive, not a fault, and it is why the constant below is taken from
	# the fine levels rather than from the icosahedron.
	var ratios := []
	var monotone := true
	for level in 5:
		var fine := SpacesimIcosphere.relative_sagitta(level + 1)
		var coarse := SpacesimIcosphere.relative_sagitta(level)
		if fine <= 0.0 or coarse <= fine:
			monotone = false
		ratios.append(coarse / fine if fine > 0.0 else 0.0)
	h.check(monotone, "each level is genuinely finer than the one before")
	var asymptotic := true
	for i in range(3, 5):
		if absf(ratios[i] - 4.0) > 0.03:
			asymptotic = false
	h.check(asymptotic,
		"and its deviation is a QUARTER of the level above, so error falls as phi^2 where the law "
			+ "applies: %s" % [ratios.map(func(r): return snappedf(r, 0.001))])

	# **The geometry's own constant.** Error in pixels is `sagitta * r_px`, so a level chosen where `N`
	# reaches `c * r_px / epsilon` has an error of `sagitta * N / c * epsilon` — exactly `epsilon` when
	# `c` is this product. It converges as the levels refine (5.68 at level 2, 5.833 at level 5), so the
	# fine levels are what it is read from, and the check is against the mesh rather than against the
	# number, so the two cannot drift.
	var product := SpacesimIcosphere.relative_sagitta(6) * SpacesimLod.triangles_at(6)
	h.check_near(product, SpacesimLod.TRIANGLES_PER_SCREEN_RADIUS,
		"the law's constant is the geometry's own: sagitta x triangles = %.4f" % product, 0.01)

	_test_the_line_mesh(h)


## **The wireframe view's mesh is the same level, as edges.** It exists to answer "where are the
## triangles", and it can only answer that if it is the triangles — so the check is that every edge of
## the triangle mesh appears and nothing else does, and that the vertex data holds no normals for an
## unshaded material to ignore.
func _test_the_line_mesh(h) -> void:
	for level in [1, 3]:
		var triangles := SpacesimIcosphere.mesh_at(level)
		var lines := SpacesimIcosphere.lines_at(level)
		h.check(lines != null, "level %d has a line mesh" % level)
		if lines == null:
			continue
		var primitives := lines.surface_get_primitive_type(0)
		h.check(primitives == Mesh.PRIMITIVE_LINES, "and it is drawn as LINES")
		var triangle_indices: PackedInt32Array = triangles.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
		var faces := triangle_indices.size() / 3
		var segments: PackedVector3Array = lines.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		h.check(segments.size() == faces * 6,
			"with three edges per triangle (%d segments for %d triangles)" % [segments.size() / 2, faces])
		# Every segment must be an actual edge of the triangle mesh: its two ends are vertices of it, and
		# the same triangle contains both. A wireframe that drew, say, face centroids would pass the count
		# above and show nothing recognisable.
		var arrays := triangles.surface_get_arrays(0)
		var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var real := {}
		for i in range(0, indices.size(), 3):
			for k in 3:
				real[_edge_key(points[indices[i + k]], points[indices[i + (k + 1) % 3]])] = true
		var missing := 0
		for i in range(0, segments.size(), 2):
			if not real.has(_edge_key(segments[i], segments[i + 1])):
				missing += 1
		h.check(missing == 0, "and every segment is a real edge of that level (%d unknown)" % missing)
		h.check(SpacesimIcosphere.lines_at(level) == lines,
			"a level's line mesh is built once, like its triangles")


## An edge that does not care which end it starts at, so a segment and its triangle agree.
static func _edge_key(a: Vector3, b: Vector3) -> String:
	var first := "%.6f,%.6f,%.6f" % [a.x, a.y, a.z]
	var second := "%.6f,%.6f,%.6f" % [b.x, b.y, b.z]
	return first + "|" + second if first < second else second + "|" + first


## The enclosed volume, signed by the triangles' winding. Positive for one convention, negative for the
## other — which is the only thing about winding that can be measured without rendering.
static func signed_volume(mesh: Mesh) -> float:
	var arrays := mesh.surface_get_arrays(0)
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var total := 0.0
	if indices.is_empty():
		for i in range(0, points.size(), 3):
			total += points[i].dot(points[i + 1].cross(points[i + 2]))
	else:
		for i in range(0, indices.size(), 3):
			total += points[indices[i]].dot(points[indices[i + 1]].cross(points[indices[i + 2]]))
	return total / 6.0
