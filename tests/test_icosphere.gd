extends RefCounted
## The icosphere: levels built once, closed, outward-wound, and measured against the sphere they
## approximate.
##
## **The point of testing this headlessly is that the law can then be checked against real geometry.**
## `test_lod.gd` asserts the arithmetic; this asserts what the arithmetic was for — that a level's
## actual silhouette error in pixels is inside the budget it was chosen by, and by how much. That ratio
## is the number phase 5 calibrates `epsilon` against, and it is a measurement rather than a prediction.

const EPSILON := 4.0 ## The budget `lod.error_budget` starts at


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
	var outward := true
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
			if a.dot((b - a).cross(c - a)) <= 0.0:
				outward = false

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
	h.check(outward,
		"with every face wound counter-clockwise seen from outside, so nothing is inside out")

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

	# **The measurement phase 4 exists for: the law's constant, taken from the geometry.**
	# A level's relative sagitta times its triangle count is what turns `N ~ c * r_px / epsilon` into
	# "the error at the chosen level is `epsilon`": error in pixels is `sagitta * r_px`, so choosing the
	# level whose `N` reaches `c * r_px / epsilon` gives an error of `sagitta * N / c * epsilon`, and
	# that is `epsilon` exactly when `c` is this product. It converges as the levels refine — 5.68 at
	# level 2, 5.833 at level 5 — so the fine levels are what the constant is read from.
	var product := SpacesimIcosphere.relative_sagitta(6) * SpacesimLod.triangles_at(6)
	h.check_near(product, SpacesimLod.TRIANGLES_PER_SCREEN_RADIUS,
		"the law's constant is the geometry's own: sagitta x triangles = %.4f" % product, 0.01)

	# **And so every level honours the budget it was chosen by.** The error is maximal just before a
	# switch and minimal just after one, so the entry point is where it should come to `epsilon` — and
	# the top of a level's range is where it is worst, at four times that, because a level spans a 4x
	# range of screen radius and only a 4x range of triangles. That 4x is inherent to quantisation, not
	# a fault, and it is printed rather than hidden.
	var worst_ratio := 0.0
	var lines := []
	for level in 6:
		var entry_px := float(SpacesimLod.triangles_at(level)) * EPSILON \
			/ SpacesimLod.TRIANGLES_PER_SCREEN_RADIUS
		var top_px := entry_px * 4.0
		var sagitta := SpacesimIcosphere.relative_sagitta(level)
		var error_px := sagitta * entry_px
		worst_ratio = maxf(worst_ratio, error_px / EPSILON)
		lines.append("level %d: s=%.9f at %8.1f px -> error %.2f px (%.2f at the top of its range)"
			% [level, sagitta, entry_px, error_px, sagitta * top_px])
	print("    ---- silhouette error at each level's entry point, budget %.1f px ----" % EPSILON)
	for line in lines:
		print("      ", line)
	h.check(worst_ratio <= 1.0,
		"and every level is INSIDE the budget at the screen radius that chooses it — the worst is "
			+ "%.3f of it" % worst_ratio)
	h.check(worst_ratio > 0.95,
		"and not wastefully so: the constant is calibrated, so the error reaches the budget rather than "
			+ "sitting under it (%.3f)" % worst_ratio)
