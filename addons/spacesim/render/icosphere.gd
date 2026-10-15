class_name SpacesimIcosphere
extends RefCounted
## A unit sphere as a subdivided icosahedron: one mesh per level, built once and shared.
##
## **Why an icosphere and not a lat-long sphere.** A `SphereMesh` regenerates on every property change,
## so adaptive detail costs a rebuild; its cells are wildly unequal in area, so it over-tessellates the
## poles and still delivers less silhouette accuracy per triangle than the count suggests; and it has no
## hierarchical address. An icosphere subdivides *exactly* — one triangle into four, so levels are
## `20 * 4^k` — which makes a level change a pointer assignment, and its triangles carry a cell address
## (`face 0..19`, level, subdivision path) that terrain patches will subdivide later.
##
## **Built at unit radius.** Every body scales the same mesh by its own radius, so the whole engine
## shares levels 0 to 5 — 27,300 triangles of mesh data in total, against ~16,000 *per body* before.
##
## **The address is not carried yet, deliberately.** Subdivision is a deterministic function of the
## level, so the (face, path) address of any triangle is derivable from the level whenever terrain
## needs it — adding it later is additive, not a migration, because nothing persists a triangle index
## today. What would have been a migration is a *flat* address or vertex data as the authority on where
## the surface is, and neither is here: the surface stays `body_surface`'s evaluable function of
## direction, and this mesh samples it.

## The golden ratio, for the icosahedron's vertices.
const PHI := 1.618033988749895

## A regular icosahedron's 12 vertices: three mutually perpendicular golden rectangles. Normalised on
## build, so the raw ±1 and ±phi here are only the construction.
const VERTICES := [
	Vector3(-1, PHI, 0), Vector3(1, PHI, 0), Vector3(-1, -PHI, 0), Vector3(1, -PHI, 0),
	Vector3(0, -1, PHI), Vector3(0, 1, PHI), Vector3(0, -1, -PHI), Vector3(0, 1, -PHI),
	Vector3(PHI, 0, -1), Vector3(PHI, 0, 1), Vector3(-PHI, 0, -1), Vector3(-PHI, 0, 1),
]

## Its 20 faces, wound **counter-clockwise seen from outside**, which each subdivision preserves.
const FACES := [
	[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
	[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
	[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
	[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
]

static var _levels: Array = []


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


## How many levels are built so far. For a test that wants to show the cache is a cache.
static func built_levels() -> int:
	return _levels.size()


## Triangles of a level's mesh, counted from the mesh rather than from the law.
static func face_count(level: int) -> int:
	var mesh := mesh_at(level)
	return mesh.get_faces().size() / 3 if mesh != null else 0


## **The level's worst-case deviation from the sphere, as a fraction of the radius** — the sagitta,
## which is what the silhouette error is made of.
##
## The vertices are exactly on the unit sphere by construction; what departs from it is the flat
## triangle between them. For a triangle whose vertices are unit vectors, the closest the triangle gets
## to the origin is the distance from the origin to its plane, so the deviation is `1 - |a . n|` with
## `n` the unit plane normal. **This is a measurement of the built mesh**, which is what makes it usable
## as the check on the law: see `tests/test_icosphere.gd`.
static func relative_sagitta(level: int) -> float:
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
		indices.append(face[0])
		indices.append(face[1])
		indices.append(face[2])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
