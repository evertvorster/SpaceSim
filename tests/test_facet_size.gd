extends RefCounted
## **The apparent size of a facet**, which is the subdivision's own criterion now.
##
## The sagitta law bounds *curvature* — an error the eye cannot resolve near the ground — so close in it permits
## enormous facets: at 1 km altitude and ε 0.5 it allows one 5.8 km across, which on screen is ~17,700 pixels. That is
## Evert's *"when I am really close each triangle in view is pretty big"*, and his ask is the opposite property:
## **visible triangles roughly the same apparent size**, heavily subdivided near the camera, the same on screen as
## something far away.
##
## So the walk takes the SMALLER of the sagitta limit and an apparent-size limit, and this pins the property:
##  * the finest facet subtends about `FACET_ANGLE` at 1 km and at 100 km alike;
##  * near the ground it subdivides far harder than the sagitta law alone would;
##  * and far away the sagitta limit still wins, which is what keeps a distant body's silhouette.
##
## **It is a constant, not a setting** — Evert, 2026-10-28: *"this subdivision code is also something that is a defining
## feature of the game, it does not need a setting, it must always be on."*

const RADIUS := 6.371e6
const FOV := 70.0
const HEIGHT := 1080.0
const EPSILON := 0.5
## 2 degrees at 1080p and 70 degrees of field, for the comparisons below.
const FACET_ANGLE_PX := 27.0


func run(h, _root: Node) -> void:
	print("  facet size")

	var pixel := SpacesimLod.pixel_angle(FOV, HEIGHT)
	# The constant, in pixels at this screen — about 27 at 1080p and 70° of field.
	var facet_px := SpacesimPatches.FACET_ANGLE / pixel
	# **The root face's edge on the unit sphere**, which every level halves — the walk's own geometry, so the test
	# measures the mesh the walk actually selects rather than a formula beside it.
	var root_edge := SpacesimIcosphere.VERTICES[SpacesimIcosphere.FACES[0][0]].normalized().distance_to(
		SpacesimIcosphere.VERTICES[SpacesimIcosphere.FACES[0][1]].normalized()
	)

	h.check_near(facet_px, 26.9,
		"2 degrees is about 27 pixels at 1080p and 70 degrees of field", 0.5)

	# --- on, close in: the finest facet is about N pixels ----------------------------------
	var near := RADIUS + 1000.0
	var near_chunks := SpacesimPatches.select(near, Vector3.UP, RADIUS, pixel, EPSILON)
	var near_px := _finest_pixels(near_chunks, root_edge, 1000.0, pixel)
	# **The count is what a judge needs** — the walk has no budget any more, so this is the whole answer for this eye.
	# It was 88 chunks at this viewpoint under the curvature law alone, which permitted facets ~17,700 px across.
	h.check(near_chunks.size() > 1000,
		"at 1 km the apparent-size limit subdivides hard (%d chunks, %d triangles)"
			% [near_chunks.size(), near_chunks.size() * SpacesimPatches.CHUNK_TRIANGLES])
	h.check(
		near_px <= FACET_ANGLE_PX * 2.0,
		"and the finest facet subtends about %d pixels, not thousands (%.1f px)" % [int(FACET_ANGLE_PX), near_px]
	)

	# --- on, far out: still about N pixels, which is the whole point ------------------------
	var far := RADIUS + 100000.0
	var far_chunks := SpacesimPatches.select(far, Vector3.UP, RADIUS, pixel, EPSILON)
	var far_px := _finest_pixels(far_chunks, root_edge, 100000.0, pixel)
	h.check(
		far_px <= FACET_ANGLE_PX * 2.0,
		"at 100 km the finest facet is the same apparent size (%.1f px)" % far_px
	)
	# **The same apparent size at both ends** is the property; the ratio says how close it holds.
	var ratio := maxf(near_px, far_px) / maxf(minf(near_px, far_px), 1.0e-6)
	h.check(ratio <= 3.0,
		"so the two are within a factor of three of each other (%.2f)" % ratio)

	# --- and far away the sagitta still wins -----------------------------------------------
	# **The two limits cross at `8·ε·R / (N²·p)`**, which for these numbers is about 27,000 km — so the sagitta term only
	# takes over from there out, and past it the walk is the one it always was. That is what keeps a distant body's
	# silhouette instead of coarsening it to a handful of triangles.
	# **From far enough out the sagitta is the binding limit** — the crossover is `8·ε·R / A` metres, about 1.6 Gm for
	# these numbers — so the walk past it is the curvature law alone, which is what a distant body's silhouette needs.
	var angular := SpacesimPatches.FACET_ANGLE * 1.0e9 / RADIUS
	var sagitta := SpacesimPatches.finest_edge_angle(RADIUS + 1.0e9, pixel, EPSILON, RADIUS)
	h.check(sagitta < angular,
		"from 1 Gm the sagitta limit is the smaller one (%s against %s)"
			% [str(sagitta), str(angular)])

	# --- the floor: a triangle is never smaller than a metre on the ground -------------------
	# **`MIN_FACET_METRES` is a distance, derived per body from its radius**, so the ceiling is a metre the eye can see
	# rather than a level number — Evert, 2026-10-28: *"lets make the minimum size for a triangle 1m on the sides."*
	var low := RADIUS + 50.0
	var low_chunks := SpacesimPatches.select(low, Vector3.UP, RADIUS, pixel, EPSILON)
	var deepest_low := 0
	for chunk in low_chunks:
		deepest_low = maxi(deepest_low, int(chunk[2]))
	var finest_metres := (
		RADIUS * root_edge / pow(2.0, float(deepest_low))
		/ float(1 << SpacesimPatches.CHUNK_SUBDIVISIONS)
	)
	h.check(finest_metres >= SpacesimPatches.MIN_FACET_METRES,
		"no triangle is smaller than the metre floor (%.2f m at depth %d)" % [finest_metres, deepest_low])
	h.check(finest_metres < SpacesimPatches.MIN_FACET_METRES * 2.0,
		"and the floor is where the tree stops, not two levels short (%.2f m)" % finest_metres)
	h.check(deepest_low == SpacesimPatches.depth_ceiling_for(RADIUS),
		"which is the ceiling the body's own radius gives (%d)" % deepest_low)
	# **A smaller body gets its own ceiling**, because the floor is a distance: the Moon stops shallower than Earth.
	h.check(SpacesimPatches.depth_ceiling_for(1.7374e6) < deepest_low,
		"a moon stops at a shallower level than a planet (%d against %d)"
			% [SpacesimPatches.depth_ceiling_for(1.7374e6), deepest_low])

	# --- the law itself: a constant projected size where the screen term binds --------------
	# **Above the altitude where the floor binds**, which for 1.6 m triangles and 2 degrees is about 46 m — below that
	# the tree cannot go finer, so the facets grow with the screen and the flatness is honestly over.
	var constant := true
	var first := 0.0
	for altitude in [100.0, 1000.0, 10000.0, 100000.0]:
		var angle := SpacesimPatches.finest_edge_angle(RADIUS + altitude, pixel, EPSILON, RADIUS)
		var projected: float = RADIUS * angle / (altitude * pixel)
		if first == 0.0:
			first = projected
		elif absf(projected - first) > first * 0.35:
			constant = false
	h.check(constant,
		"and where the screen term binds, the projected size is flat across four altitudes (%.1f px)"
			% first)
	# **And below the floor's altitude the facets grow, which is the floor doing its job**: at 10 m the finest
	# triangle is the same 1.6 m, so it subtends many more pixels rather than the tree growing finer.
	var at_ten := SpacesimPatches.finest_edge_angle(RADIUS + 10.0, pixel, EPSILON, RADIUS)
	var ten_metres: float = RADIUS * at_ten / (10.0 * pixel)
	h.check(ten_metres > first * 4.0,
		"and below the floor's altitude the facets grow with the screen instead (%.0f px at 10 m, %.1f above)"
			% [ten_metres, first])


## The finest facet a selection holds, in pixels — the deepest chunk's edge, projected at `ground_distance`.
## What the finest **triangle** in the selection projects to, in pixels.
##
## A chunk's interior is `4^CHUNK_SUBDIVISIONS` triangles, so a triangle's edge is `2^CHUNK_SUBDIVISIONS` times the
## chunk's — measuring the chunk instead would overstate the apparent size by that factor and make every bound here
## that much too loose. Derived from the constant, because it was 4 hard-coded here and that is only true at `s = 2`.
func _finest_pixels(chunks: Array, root_edge: float, ground_distance: float, pixel: float) -> float:
	var deepest := 0
	for chunk in chunks:
		deepest = maxi(deepest, int(chunk[2]))
	var edge := root_edge / pow(2.0, float(deepest)) / float(1 << SpacesimPatches.CHUNK_SUBDIVISIONS)
	return RADIUS * edge / (ground_distance * pixel)
