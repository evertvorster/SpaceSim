class_name SpacesimBlobShape
extends RefCounted
## **A body as an implicit field** — a few seeded balls fused with a smooth minimum, with the surface extracted
## from the field by surface nets.
##
## ## Why a field and not a surface
##
## Every earlier attempt started from a surface and moved it: an icosphere displaced, an ellipsoid with
## harmonics, an outline swept into a solid. All three are deformations of something, and a deformation has a
## habit — it bulges all the way round, or along one axis, and cannot make a lump that is only in one place.
##
## A field has no such habit. There is no surface here until one is extracted, so the body is whatever the
## field's isosurface turns out to be: lumpy where a ball is, fused where two are close, and able to be pinched
## into a **contact binary** or cut into with a **negative ball** (a crater, later) without any of that being a
## special case.
##
## ## What it is, exactly
##
## `BALLS` balls, seeded, each with a centre and a radius, the first at the origin and the rest placed to
## **overlap** an existing one — so the pile is connected before the smooth minimum rounds the joins. The field
## is the smooth-minimum of the balls' signed distances, so it is negative inside, positive outside, and roughly
## in body radii.
##
## `mesh()` samples it on a grid and extracts the isosurface with **surface nets**: one vertex per cell the
## surface passes through, placed at the mean of the cell's edge crossings, and a quad around every grid edge
## whose ends differ in sign. No lookup tables, and the topology follows the field rather than a mesh.
##
## ## What it costs, and where that was measured
##
## One field evaluation per grid corner, and the grid is `resolution + 1` cubed. `SMOOTH` and `BALLS` are the
## two numbers that decide the look; the resolution decides the triangles. **`tests/probe_blob_rock.gd` timings
## and pictures are the measurement**, and it exists because none of this is worth writing down as a guess.

## How many balls the pile is made of. Six gives a body with a few lobes and a chance of a pinch.
const BALLS := 6
## How much the fusion rounds a join, in body radii. Zero is a pile of welded spheres with creased seams; too
## much and the balls melt into something convex.
const SMOOTH := 0.25
## **The grid's margin, in body radii.** The balls are normalised so the furthest surface point is exactly 1.0,
## and the roughness below can push it out by `ROUGHNESS * 1.875` — so this must exceed that sum, and a surface
## that touches the grid's own boundary is a surface with a hole in it.
const MARGIN := 1.18

## **The shape is rough, not a smooth blob.** A smooth minimum of six spheres is C1 continuous: there is no
## crease anywhere, so the normals are smooth and the body reads as a melted thing however finely it is meshed.
## The relief is a fractal **subtracted from the field**, so it is a function of POSITION and not of the mesh —
## re-extracting at another resolution, or after a chunk is mined out, gives the same rock sampled differently
## rather than a different rock.
##
## In body radii, per octave, and the octaves are bounded by the grid (see `_octaves_for`): an octave finer than
## three cells aliases into the extraction rather than shaping it. 0.04 with a fractal gain of 0.5 sums to about
## 0.075 of the radius — 830 m on Phobos, which is the scale its real grooves and crater rims sit at.
const ROUGHNESS := 0.04
## The broadest roughness feature, in body radii — about two features across the body, before the octaves halve it.
const ROUGHNESS_WAVELENGTH := 0.45
## How many octaves the field may carry. The grid decides how many of them can be represented; this is the cap.
const ROUGHNESS_OCTAVES := 5
## The cube's twelve edges, as corner-index pairs. A corner's index is `dx + 2*dy + 4*dz`.
const EDGES := [
	Vector2i(0, 1), Vector2i(2, 3), Vector2i(4, 5), Vector2i(6, 7),
	Vector2i(0, 2), Vector2i(1, 3), Vector2i(4, 6), Vector2i(5, 7),
	Vector2i(0, 4), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
]


## **The body's own balls** — `[centre: Vector3, radius: float]` each, normalised so the shape's furthest point
## is 1.0 from the centre. Seeded, so the same body is the same rock every load, and two bodies are two rocks.
static func balls(seed_value: int) -> Array:
	var centres: Array = [Vector3.ZERO]
	var radii: Array = [lerpf(0.55, 0.72, _unit(seed_value, 1))]
	for index in BALLS - 1:
		var anchor := int(_unit(seed_value, 10 + index * 4) * float(centres.size())) % centres.size()
		var radius := lerpf(0.32, 0.58, _unit(seed_value, 11 + index * 4))
		# **Placed to OVERLAP, not to touch.** The smooth minimum only fuses what is already connected; two balls
		# that merely touch give a narrow neck that reads as a mistake rather than as a body.
		var reach := (float(radii[anchor]) + radius) * lerpf(0.35, 0.7, _unit(seed_value, 12 + index * 4))
		var angle := TAU * _unit(seed_value, 13 + index * 4)
		var lift := lerpf(-1.0, 1.0, _unit(seed_value, 14 + index * 4))
		var direction := Vector3(cos(angle), lift, sin(angle)).normalized()
		centres.append(centres[anchor] + direction * reach)
		radii.append(radius)
	# **Normalised to the body's own reach**: without this the body's size would be a consequence of which balls
	# the seed drew, and `radius` would mean something different for every rock.
	var extent := 0.0
	for index in centres.size():
		extent = maxf(extent, (centres[index] as Vector3).length() + float(radii[index]))
	var result: Array = []
	for index in centres.size():
		result.append([(centres[index] as Vector3) / extent, float(radii[index]) / extent])
	return result


## **The signed distance to the body's surface**, in body radii — negative inside, positive outside.
##
## Takes the balls and the noise rather than the seed because it is called once per grid corner: rebuilding either
## per sample would be most of the cost of the whole extraction.
##
## **`removals` is what mining changes.** Each entry is `[centre: Vector3, reach: float]` in body radii, and the
## field is cut by it — `max(field, reach - distance)`, which makes the inside of that ball OUTSIDE the body. That
## is the whole of "take a chunk out": the shape is the seed plus the removals, so the save holds a list of holes
## rather than a mesh, and `radius_at` follows the new surface with no second bookkeeping.
static func field(balls: Array, noise: FastNoiseLite, removals: Array, point: Vector3) -> float:
	var result := 1.0e9
	for ball in balls:
		result = _smooth_min(result, point.distance_to(ball[0]) - ball[1])
	if noise != null:
		result -= ROUGHNESS * noise.get_noise_3d(point.x, point.y, point.z)
	for removal in removals:
		result = maxf(result, float(removal[1]) - point.distance_to(removal[0]))
	return result


## **The surface's outward direction at a point** — the field's gradient, which is exact rather than differenced
## off triangles: three central differences, so six field evaluations.
static func normal(balls: Array, noise: FastNoiseLite, removals: Array, point: Vector3) -> Vector3:
	var step := 0.002
	var gradient := Vector3(
		field(balls, noise, removals, point + Vector3(step, 0.0, 0.0))
			- field(balls, noise, removals, point - Vector3(step, 0.0, 0.0)),
		field(balls, noise, removals, point + Vector3(0.0, step, 0.0))
			- field(balls, noise, removals, point - Vector3(0.0, step, 0.0)),
		field(balls, noise, removals, point + Vector3(0.0, 0.0, step))
			- field(balls, noise, removals, point - Vector3(0.0, 0.0, step))
	)
	return gradient.normalized()


## **The body as a mesh**, `resolution` cells across its bounding cube. Every vertex is on the field's isosurface
## because that is where the extraction puts it, so a finer grid is a finer sampling of the same body — which is
## the property subdivision needs.
##
## `removals` is the mined state — see [method field]. Empty is an unmined body.
static func mesh(seed_value: int, radius: float, resolution := 64, removals := []) -> ArrayMesh:
	return mesh_from(arrays(seed_value, radius, resolution, removals))


## **The extraction on its own, as plain arrays** — the half that a WORKER THREAD may do.
##
## `add_surface_from_arrays` is a `RenderingServer` call, so it has to happen on the main thread; the sampling and
## the net are arithmetic and do not. Splitting them is what lets a body be extracted while the frame keeps
## running, which is the only way a lazily-built rock can appear without the frame stalling for a second.
static func arrays(seed_value: int, radius: float, resolution := 64, removals := []) -> Array:
	var balls := balls(seed_value)
	var n := maxi(resolution, 8)
	var noise := noise_for(seed_value, n)
	var step := 2.0 * MARGIN / float(n)
	var side := n + 1
	var values := PackedFloat32Array()
	values.resize(side * side * side)
	for k in side:
		var z := -MARGIN + step * float(k)
		for j in side:
			var y := -MARGIN + step * float(j)
			for i in side:
				var x := -MARGIN + step * float(i)
				values[(k * side + j) * side + i] = field(balls, noise, removals, Vector3(x, y, z))

	# --- one vertex per cell the surface crosses -------------------------------------------------------
	var cell_vertex := PackedInt32Array()
	cell_vertex.resize(n * n * n)
	cell_vertex.fill(-1)
	var points := PackedVector3Array()
	var normals := PackedVector3Array()
	var corner_values := PackedFloat32Array()
	corner_values.resize(8)
	for k in n:
		for j in n:
			for i in n:
				var inside := 0
				for corner in 8:
					var di := corner & 1
					var dj := (corner >> 1) & 1
					var dk := (corner >> 2) & 1
					var value := values[((k + dk) * side + (j + dj)) * side + (i + di)]
					corner_values[corner] = value
					if value < 0.0:
						inside += 1
				if inside == 0 or inside == 8:
					continue
				# **The mean of the cell's edge crossings** — the vertex of a surface net, which is what makes the
				# surface smooth across a cell instead of staircasing along the grid.
				var total := Vector3.ZERO
				var crossings := 0
				for edge in EDGES:
					var a: int = edge.x
					var b: int = edge.y
					var va := corner_values[a]
					var vb := corner_values[b]
					if (va < 0.0) == (vb < 0.0):
						continue
					total += _corner(a).lerp(_corner(b), va / (va - vb))
					crossings += 1
				if crossings == 0:
					continue
				var local := total / float(crossings)
				var here := Vector3(
					-MARGIN + step * (float(i) + local.x),
					-MARGIN + step * (float(j) + local.y),
					-MARGIN + step * (float(k) + local.z)
				)
				cell_vertex[(k * n + j) * n + i] = points.size()
				points.append(here * radius)
				normals.append(normal(balls, noise, removals, here))

	# --- a quad around every grid edge whose ends differ in sign ----------------------------------------
	var indices := PackedInt32Array()
	for k in range(1, n):
		for j in range(1, n):
			for i in n:
				var low := values[(k * side + j) * side + i]
				var high := values[(k * side + j) * side + i + 1]
				if (low < 0.0) == (high < 0.0):
					continue
				_emit_quad(cell_vertex, n, points, normals, indices, [
					[i, j - 1, k - 1], [i, j, k - 1], [i, j, k], [i, j - 1, k],
				])
	for k in range(1, n):
		for j in n:
			for i in range(1, n):
				var low := values[(k * side + j) * side + i]
				var high := values[(k * side + j + 1) * side + i]
				if (low < 0.0) == (high < 0.0):
					continue
				_emit_quad(cell_vertex, n, points, normals, indices, [
					[i - 1, j, k - 1], [i, j, k - 1], [i, j, k], [i - 1, j, k],
				])
	for k in n:
		for j in range(1, n):
			for i in range(1, n):
				var low := values[(k * side + j) * side + i]
				var high := values[((k + 1) * side + j) * side + i]
				if (low < 0.0) == (high < 0.0):
					continue
				_emit_quad(cell_vertex, n, points, normals, indices, [
					[i - 1, j - 1, k], [i, j - 1, k], [i, j, k], [i - 1, j, k],
				])

	var surface := []
	surface.resize(Mesh.ARRAY_MAX)
	surface[Mesh.ARRAY_VERTEX] = points
	surface[Mesh.ARRAY_NORMAL] = normals
	surface[Mesh.ARRAY_INDEX] = indices
	return surface


## **The arrays turned into a mesh, on the MAIN THREAD.** `add_surface_from_arrays` reaches the
## `RenderingServer`, so this is the half a worker cannot do — see [method arrays].
static func mesh_from(surface: Array) -> ArrayMesh:
	if surface.is_empty() or (surface[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
		return null
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface)
	return result


## **The body's edges, for the debug view.** A surface net has no grid to draw, so the lines are the mesh's own
## triangle edges — three per triangle, and a shared edge drawn twice costs nothing in a view that exists to show
## where the triangles are.
static func wire_mesh(mesh: ArrayMesh) -> ArrayMesh:
	var source: Array = mesh.surface_get_arrays(0)
	var points: PackedVector3Array = source[Mesh.ARRAY_VERTEX]
	var triangles: PackedInt32Array = source[Mesh.ARRAY_INDEX]
	var edges := PackedInt32Array()
	edges.resize(triangles.size() * 2)
	for triangle in range(0, triangles.size(), 3):
		var base := triangle / 3 * 6
		edges[base] = triangles[triangle]
		edges[base + 1] = triangles[triangle + 1]
		edges[base + 2] = triangles[triangle + 1]
		edges[base + 3] = triangles[triangle + 2]
		edges[base + 4] = triangles[triangle + 2]
		edges[base + 5] = triangles[triangle]
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_INDEX] = edges
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return result


## **How far the body reaches in a direction** — the datum question, answered by marching the field inward from
## outside it. Sphere tracing: every step is the field's own value, which is the distance to the surface, so it
## cannot step past it.
## **The noise is built for the resolution, and both the drawn mesh and this must use the same one** — the
## band limit decides which octaves exist, so a datum asked with another resolution would answer about a
## slightly different surface. The builder has one `RESOLUTION` and passes it to both.
static func radius_at(
	seed_value: int, radius: float, direction: Vector3, resolution := 64, removals := []
) -> float:
	var balls := balls(seed_value)
	var noise := noise_for(seed_value, maxi(resolution, 8))
	var dir := direction.normalized()
	var t := MARGIN * 1.6
	# **The roughness makes the field no longer a true distance** — its gradient can exceed 1 — so a sphere
	# trace that stepped by the field's full value could step past the surface. The safety factor is the price of
	# having relief at all, and 128 steps is what it costs to keep converging.
	for _step in 128:
		var value := field(balls, noise, removals, dir * t)
		if value <= 0.0:
			return t * radius
		t -= maxf(value * 0.8, 0.001)
		if t <= 0.0:
			break
	return maxf(t, 0.0) * radius


static func _emit_quad(
	cell_vertex: PackedInt32Array, n: int, points: PackedVector3Array,
	normals: PackedVector3Array, indices: PackedInt32Array, cells: Array
) -> void:
	var corners: Array = []
	for cell in cells:
		var index := int(cell[0]) + int(cell[1]) * n + int(cell[2]) * n * n
		if index < 0 or index >= cell_vertex.size():
			return
		var vertex := cell_vertex[index]
		if vertex < 0:
			return
		corners.append(vertex)
	_emit_triangle(points, normals, indices, corners[0], corners[1], corners[2])
	_emit_triangle(points, normals, indices, corners[0], corners[2], corners[3])


## **A triangle, wound the way Godot's front faces are.** Winding is not a detail here: Godot's front face is
## CLOCKWISE seen from outside (`icosphere.gd` carries the same note, and `tests/test_icosphere.gd` measures it
## against `SphereMesh` rather than trusting the prose), so a triangle whose cross-product normal points OUTWARD
## is counter-clockwise and is therefore a BACK face — which `cull_back` culls.
##
## **Getting this wrong does not look like an inversion.** Evert, 2026-11-12, flying the first blob build: *"it
## seems its rendered inside-out... I see the far side of the mesh, and its lit wrong."* Every outward triangle was
## culled and the inside of the far wall was drawn instead, so the body was lit by whatever was behind it — a
## plausible-looking body with the sun on the wrong side.
##
## So the face normal is asked to point INWARD, which is what the outward-stored vertex normal says is correct:
## `face · normal < 0` means the winding already matches the engine, and `> 0` is the case that must be swapped.
static func _emit_triangle(
	points: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array,
	a: int, b: int, c: int
) -> void:
	var face := (points[b] - points[a]).cross(points[c] - points[a])
	if face.dot(normals[a]) <= 0.0:
		indices.append_array([a, b, c])
	else:
		indices.append_array([a, c, b])


## A corner's offset within its cell, from the index `dx + 2*dy + 4*dz`.
static func _corner(corner: int) -> Vector3:
	return Vector3(float(corner & 1), float((corner >> 1) & 1), float((corner >> 2) & 1))


## **The roughness generator for a grid.** Seeded from the body, so the same rock is the same rock; the octave
## count follows the CELL SIZE, because an octave finer than three cells is aliased into the extraction instead
## of shaping it — which is the same rule the surface shader follows, one resolution down.
static func noise_for(seed_value: int, resolution: int) -> FastNoiseLite:
	var cell := 2.0 * MARGIN / float(maxi(resolution, 8))
	var octaves := 1
	var wavelength := ROUGHNESS_WAVELENGTH
	while octaves < ROUGHNESS_OCTAVES and wavelength * 0.5 >= 3.0 * cell:
		wavelength *= 0.5
		octaves += 1
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 1.0 / ROUGHNESS_WAVELENGTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.fractal_gain = 0.5
	return noise


## The polynomial smooth minimum: `min(a, b)` where the two are further apart than `SMOOTH`, rounding the join
## where they are closer. The whole of what makes a pile into a body rather than a pile.
static func _smooth_min(a: float, b: float) -> float:
	var closeness := maxf(SMOOTH - absf(a - b), 0.0) / SMOOTH
	return minf(a, b) - closeness * closeness * SMOOTH * 0.25


static func _unit(seed_value: int, salt: int) -> float:
	# **Godot's own hasher, because a hand-rolled one does not mix.** The first version was
	# `(seed ^ (salt * prime)) & 0x7fffffff`, which leaves a seed that differs by one giving a shape that differs
	# by one — so four bodies drawn from four consecutive ids came out as the same rock, and the pictures would
	# have shown four copies of it. `hash()` of a string is the engine's avalanche and costs nothing here: it is
	# called once per ball, never per sample.
	var mixed := absi(hash("%d:%d" % [seed_value, salt]))
	return float(mixed % 100000) / 100000.0
