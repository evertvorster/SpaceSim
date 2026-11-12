extends SceneTree
## **Spike: what an implicit blob body costs, and whether its mesh is sound.**
##
##     timeout 120 godot-double-mono --headless --path . --script res://tests/probe_blob_rock.gd
##
## **Numbers only.** There is no picture half and there will not be one: a rig I have to iterate on is a rig that
## answers the question wrongly twice before it answers it at all, and whether the shape reads as a rock is
## Evert's eye on a flight. What this reports is the cost objection to the method, measured, plus the two
## properties that make a mesh usable — that it is closed, and that its volume is a body's rather than a sliver's.
##
## Out of the suite on purpose (`probe_*`): it takes seconds and asserts nothing about the engine.

const RADIUS := 1.0


func _initialize() -> void:
	for resolution in [48, 64, 96]:
		var started := Time.get_ticks_usec()
		var mesh := SpacesimBlobShape.mesh(hash("spike:cost"), RADIUS, resolution)
		var elapsed := float(Time.get_ticks_usec() - started) / 1000.0
		var triangles := 0
		if mesh != null:
			triangles = mesh.get_faces().size() / 3
		print("BLOB: %d^3  %8.1f ms  %6d triangles" % [resolution, elapsed, triangles])

	for index in 6:
		var seed_value := hash("spike:blob:%d" % index)
		_report_mesh(index, SpacesimBlobShape.mesh(seed_value, RADIUS, 64))
	quit()


## **One body, measured**: the shape, the size of it, and whether it is closed.
func _report_mesh(index: int, mesh: ArrayMesh) -> void:
	var arrays: Array = mesh.surface_get_arrays(0)
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var lo := Vector3.ONE * INF
	var hi := Vector3.ONE * -INF
	for point in points:
		lo = Vector3(minf(lo.x, point.x), minf(lo.y, point.y), minf(lo.z, point.z))
		hi = Vector3(maxf(hi.x, point.x), maxf(hi.y, point.y), maxf(hi.z, point.z))
	var size := hi - lo
	var thin := minf(size.x, minf(size.y, size.z))
	var thick := maxf(size.x, maxf(size.y, size.z))

	# **Closed?** Every undirected edge of a closed surface is shared by exactly two triangles.
	var usage := {}
	for triangle in range(0, indices.size(), 3):
		for pair in [[0, 1], [1, 2], [2, 0]]:
			var a := indices[triangle + pair[0]]
			var b := indices[triangle + pair[1]]
			var key := Vector2i(mini(a, b), maxi(a, b))
			usage[key] = int(usage.get(key, 0)) + 1
	var open := 0
	for count in usage.values():
		if int(count) != 2:
			open += 1

	# **Volume by the divergence theorem**, as a share of the sphere of the same reach — a rock is less than 1,
	# and a share near zero is a surface that has been turned inside out.
	var volume := 0.0
	for triangle in range(0, indices.size(), 3):
		var a := points[indices[triangle]]
		var b := points[indices[triangle + 1]]
		var c := points[indices[triangle + 2]]
		volume += a.dot(b.cross(c)) / 6.0
	var sphere := 4.0 / 3.0 * PI * pow(thick * 0.5, 3.0)
	print("BLOB: %d  %6d triangles, %.2f x %.2f x %.2f, volume %.2f of a sphere, %d open edges"
		% [index, indices.size() / 3, size.x, size.y, size.z, absf(volume) / maxf(sphere, 1.0e-9), open])
