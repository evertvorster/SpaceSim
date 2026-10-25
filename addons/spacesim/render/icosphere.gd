class_name SpacesimIcosphere
extends RefCounted
## A unit sphere as a subdivided icosahedron: one mesh per level, built once and shared.
##
## **Why an icosphere and not a lat-long sphere.** A `SphereMesh` regenerates on every property change,
## so adaptive detail costs a rebuild; its cells are wildly unequal in area, so it over-tessellates the
## poles and still delivers less silhouette accuracy per triangle than the count suggests; and it has no
## hierarchical address. An icosphere subdivides *exactly* — one triangle into four, so levels are
## `20 * 4^k` — which makes a level change a pointer assignment, and its triangles carry a cell address
## (`face 0..19`, level, subdivision path) that `SpacesimPatches` walks.
##
## **Built at unit radius.** Every body scales the same mesh by its own radius, so the whole engine
## shares levels 0 to 5 — 27,300 triangles of mesh data in total, against ~16,000 *per body* before.
##
## **The address is derived, not carried.** Subdivision is a deterministic function of the level, so the
## (face, path) address of any triangle is computable from the level, and that is what `SpacesimPatches`
## does when it selects which chunks to subdivide. What would have been a migration is a *flat* address
## or vertex data as the authority on where the surface is, and neither is here: the surface stays
## `body_surface`'s evaluable function of direction, and this mesh samples it.

## The golden ratio, for the icosahedron's vertices.
const PHI := 1.618033988749895

## A regular icosahedron's 12 vertices: three mutually perpendicular golden rectangles. Normalised on
## build, so the raw ±1 and ±phi here are only the construction.
const VERTICES := [
	Vector3(-1, PHI, 0), Vector3(1, PHI, 0), Vector3(-1, -PHI, 0), Vector3(1, -PHI, 0),
	Vector3(0, -1, PHI), Vector3(0, 1, PHI), Vector3(0, -1, -PHI), Vector3(0, 1, -PHI),
	Vector3(PHI, 0, -1), Vector3(PHI, 0, 1), Vector3(-PHI, 0, -1), Vector3(-PHI, 0, 1),
]

## Its 20 faces, wound counter-clockwise seen from outside — **the standard construction, NOT Godot's
## convention**, which is clockwise. `_build` flips the winding once, when the indices are written, so
## this list stays the well-known one and the flip is visible in one place.
const FACES := [
	[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
	[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
	[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
	[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
]

static var _levels: Array = []
## The same levels as line meshes, for the wireframe view. Built on demand.
static var _lines: Array = []
## Each level's measured sagitta, or -1 where it has not been measured yet. See `relative_sagitta`.
static var _sagittas: Array = []


## The mesh for a level, built on first use and then the *same* object every time.
##
## **Building once is the whole point of the primitive**: a body changing level assigns a pointer,
## where a `SphereMesh` would re-tessellate. Levels are built lazily rather than all at startup, so a
## scene that only ever shows a body at level 1 does not pay for level 6.
static func mesh_at(level: int) -> ArrayMesh:
	var index := clampi(level, 0, SpacesimLod.MAX_LEVEL)
	while _levels.size() <= index:
		_levels.append(null)
	if _levels[index] == null:
		_levels[index] = _build(index)
	return _levels[index]


## **The same level as LINES**: every triangle's three edges, for the wireframe debug view.
##
## Its own mesh rather than a render mode, because `Viewport.DEBUG_DRAW_WIREFRAME` draws the lines with
## the material's own shading — so a sunlit white disc is white lines on white, which shows nothing. A
## `PRIMITIVE_LINES` mesh with an unshaded material is white everywhere by construction, which is the
## whole point of looking at it.
##
## **Lazy and per level**, like the triangles: the view is a debug aid, so nothing pays for it until it is
## asked for. It is 6 indices per triangle against the triangles' 3 — a level-6 sphere is ~6 MB of line
## data, which is why it is built on demand and never for levels nobody looks at.
static func lines_at(level: int) -> ArrayMesh:
	var index := clampi(level, 0, SpacesimLod.MAX_LEVEL)
	while _lines.size() <= index:
		_lines.append(null)
	if _lines[index] == null:
		_lines[index] = _build_lines(index)
	return _lines[index]


## How many levels are built so far. For a test that wants to show the cache is a cache.
static func built_levels() -> int:
	return _levels.size()


## **The level's worst-case deviation from the sphere, as a fraction of the radius** — the sagitta,
## which is what the silhouette error is made of.
##
## The vertices are exactly on the unit sphere by construction; what departs from it is the flat
## triangle between them. For a triangle whose vertices are unit vectors, the closest the triangle gets
## to the origin is the distance from the origin to its plane, so the deviation is `1 - |a . n|` with
## `n` the unit plane normal. **This is a measurement of the built mesh**, which is what makes it usable
## as the check on the law: see `tests/test_icosphere.gd`.
##
## **Measured once per level and then remembered, and it has to be.** The measurement copies the level's
## vertex and index arrays — `surface_get_arrays` allocates, it does not hand out a reference — and then
## walks every triangle in it, so level 6 alone is 81,920 triangles of cross products. Levels 0 to 6 are
## **109,220 triangles a call**, and a caller that asks once a frame pays that every frame: the engine's
## profiler measured **16.2 ms of a 35 ms frame** here, the entire frame-rate complaint, for a number
## that is a property of a mesh built once and shared. A level's sagitta cannot change, so this is a
## cache and not an optimisation.
static func relative_sagitta(level: int) -> float:
	var index := clampi(level, 0, SpacesimLod.MAX_LEVEL)
	while _sagittas.size() <= index:
		_sagittas.append(-1.0)
	if _sagittas[index] < 0.0:
		_sagittas[index] = _measure_sagitta(index)
	return _sagittas[index]


## The measurement itself, once. Split out so the cache above reads as a cache.
static func _measure_sagitta(level: int) -> float:
	var mesh := mesh_at(level)
	if mesh == null:
		return 0.0
	var arrays := mesh.surface_get_arrays(0)
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var worst := 0.0
	for i in range(0, indices.size(), 3):
		var a := points[indices[i]]
		var b := points[indices[i + 1]]
		var c := points[indices[i + 2]]
		var normal := (b - a).cross(c - a)
		if normal.length_squared() <= 0.0:
			continue
		worst = maxf(worst, 1.0 - absf(a.dot(normal.normalized())))
	return worst


## The 12 vertices normalised onto the unit sphere, as a fresh array.
static func _unit_icosahedron() -> Array:
	var points: Array = []
	for vertex in VERTICES:
		points.append((vertex as Vector3).normalized())
	return points


## One subdivision: every triangle split at its edge midpoints, each midpoint normalised onto the
## sphere, emitting four triangles with the parent's winding.
static func _subdivide(points: Array, faces: Array) -> Array:
	var midpoints := {}
	var next: Array = []
	for face in faces:
		var a: int = face[0]
		var b: int = face[1]
		var c: int = face[2]
		var ab := _midpoint(points, midpoints, a, b)
		var bc := _midpoint(points, midpoints, b, c)
		var ca := _midpoint(points, midpoints, c, a)
		next.append([a, ab, ca])
		next.append([b, bc, ab])
		next.append([c, ca, bc])
		next.append([ab, bc, ca])
	return next


## The midpoint of an edge, as an index into `points`, **shared between the two triangles that meet
## there**.
##
## **The cache is not an optimisation, it is what keeps the surface closed.** A midpoint belongs to
## exactly two triangles; giving each its own copy leaves the two halves free to disagree at the seam,
## and a seam is a crack — visible at the silhouette, which is the one thing the mesh carries. Keyed on
## the edge, so both callers get the same vertex.
static func _midpoint(points: Array, midpoints: Dictionary, a: int, b: int) -> int:
	var key := Vector2i(mini(a, b), maxi(a, b))
	if midpoints.has(key):
		return midpoints[key]
	points.append(((points[a] + points[b]) * 0.5).normalized())
	var index := points.size() - 1
	midpoints[key] = index
	return index


static func _build(level: int) -> ArrayMesh:
	var points := _unit_icosahedron()
	var faces: Array = []
	for face in FACES:
		faces.append([int(face[0]), int(face[1]), int(face[2])])
	for _step in level:
		faces = _subdivide(points, faces)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	for point in points:
		vertices.append(point)
		# **On a unit sphere the position IS the normal**, so the normals come free — and being
		# per-vertex and radial, they interpolate exactly along facet edges, which is why a coarse
		# icosphere still looks round and only the silhouette shows the approximation.
		normals.append(point)

	var indices := PackedInt32Array()
	for face in faces:
		# **Reversed, because Godot's front face is CLOCKWISE seen from outside** — which is what
		# `SphereMesh` is wound as, and every material here is written against it: a body's materials are
		# drawn from outside and cull back faces. (The one front-culling consumer, the air shell's
		# `body_atmosphere.gdshader`, was deleted on 2026-10-19; the convention stays because `SphereMesh`
		# and every mesh a Godot project adds share it.) The construction above is the
		# standard counter-clockwise one, so the flip happens here, once, where it can be seen. Getting
		# it wrong renders a planet inside out — and **an inside-out sphere still looks like a disc**, so
		# it shows up as a sky that is black from inside and a body with no shading, not as an obvious
		# inversion. `tests/test_icosphere.gd` measures the winding against `SphereMesh` so it cannot
		# regress quietly.
		indices.append(face[0])
		indices.append(face[2])
		indices.append(face[1])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## A level as line segments: every triangle's three edges, from the triangle mesh so the two cannot
## disagree about which triangles exist.
##
## The winding is irrelevant to lines, so this reads the indexed triangles as they are rather than
## repeating `_build`'s flip — and it deliberately does **not** add the `ARRAY_NORMAL` array: an
## unshaded material has no use for it, and half a megabyte of normals nothing reads is a tax on a view
## that exists to be cheap.
static func _build_lines(level: int) -> ArrayMesh:
	var triangles := mesh_at(level)
	var arrays_in := triangles.surface_get_arrays(0)
	var points: PackedVector3Array = arrays_in[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays_in[Mesh.ARRAY_INDEX]
	var lines := PackedVector3Array()
	lines.resize(indices.size() * 2)
	var write := 0
	for triangle in range(0, indices.size(), 3):
		var a := points[indices[triangle]]
		var b := points[indices[triangle + 1]]
		var c := points[indices[triangle + 2]]
		lines[write] = a
		lines[write + 1] = b
		lines[write + 2] = b
		lines[write + 3] = c
		lines[write + 4] = c
		lines[write + 5] = a
		write += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh
