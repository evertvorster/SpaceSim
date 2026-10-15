extends RefCounted
## The icosphere: levels built once, closed, and measured against the sphere they approximate —
## including its WINDING, which is the one property that fails invisibly.
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

	# **The measurement phase 4 exists for: the law's constant, taken from the geometry.**
	# A level's relative sagitta times its triangle count is what turns `N ~ c * r_px / epsilon` into
	# "the error at the chosen level is `epsilon`": error in pixels is `sagitta * r_px`, so choosing the
	# level whose `N` reaches `c * r_px / epsilon` gives an error of `sagitta * N / c * epsilon`, and
	# that is `epsilon` exactly when `c` is this product. It converges as the levels refine — 5.68 at
	# level 2, 5.833 at level 5 — so the fine levels are what the constant is read from.
	var product := SpacesimIcosphere.relative_sagitta(6) * SpacesimLod.triangles_at(6)
	h.check_near(product, SpacesimLod.TRIANGLES_PER_SCREEN_RADIUS,
		"the law's constant is the geometry's own: sagitta x triangles = %.4f" % product, 0.01)

	# **And the budget is honoured EVERYWHERE in a level's range, not just at its edges.** The range runs
	# from `level_exit(level) / 4` — where the level is taken up and its error is at its smallest — up to
	# `level_exit(level)`, where the next level takes over and its error is at its largest, which is the
	# budget itself. So the error lies in `[epsilon / 4, epsilon]` and **never exceeds the budget**, which is
	# what makes `epsilon` mean what it says. Sampled across the range, because a pair of endpoints is not
	# an interval. (An earlier version of this comment claimed the error reached four times the budget,
	# which had the range inside out.)
	var worst_ratio := 0.0
	var lines := []
	for level in 6:
		var exit_px := SpacesimLod.level_exit(level, EPSILON)
		var entry_px := exit_px / 4.0
		var sagitta := SpacesimIcosphere.relative_sagitta(level)
		for step in 33:
			var radius := lerpf(entry_px, exit_px, float(step) / 32.0)
			if SpacesimLod.level_for_screen_radius(radius, EPSILON) != level:
				continue
			worst_ratio = maxf(worst_ratio, sagitta * radius / EPSILON)
		lines.append("level %d: taken up %8.1f px (error %.2f), left %8.1f px (error %.2f)"
			% [level, entry_px, sagitta * entry_px, exit_px, sagitta * exit_px])
	print("    ---- silhouette error across each level's range, budget %.1f px ----" % EPSILON)
	for line in lines:
		print("      ", line)
	h.check(worst_ratio <= 1.0,
		"and every level stays INSIDE the budget for the whole range it is used over — the worst is "
			+ "%.3f of it" % worst_ratio)
	h.check(worst_ratio > 0.95,
		"and reaches it, as a calibrated budget should, rather than sitting wastefully under it (%.3f)"
			% worst_ratio)


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
