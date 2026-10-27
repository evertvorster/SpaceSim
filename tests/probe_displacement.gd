extends SceneTree
## **Displacement investigation, block A** — what the mesh can express, and what a terrain-driven error law would cost.
##
## Run headless:  godot-double-mono --headless --path . --script res://tests/probe_displacement.gd
##
## Everything here is arithmetic on code the game runs: `SpacesimPatches.select` (the real walk) and
## `SpacesimPatches.build` (the real merge). No rendering device, no pictures.

const EARTH := 6.371e6
const PIXEL := 1.2966806e-3
## The icosahedron's edge, as a chord on the unit sphere — an icosahedron of circumradius 1 has edge
## `2·sin(63.4349°/2)... ` no: the standard value is `sqrt(2 - 2/sqrt(5))`·? Measured instead from the vertices the
## project already ships, so this file cannot disagree with `SpacesimIcosphere`.
func _face_edge() -> float:
	var face: Array = SpacesimIcosphere.FACES[0]
	var a: Vector3 = SpacesimIcosphere.VERTICES[int(face[0])].normalized()
	var b: Vector3 = SpacesimIcosphere.VERTICES[int(face[1])].normalized()
	return a.distance_to(b)


## A chord on the unit sphere as an angle, and so as metres on a body of radius `radius`.
func _metres(chord: float, radius: float) -> float:
	return radius * 2.0 * asin(clampf(chord * 0.5, -1.0, 1.0))


func _init() -> void:
	var edge := _face_edge()
	var chunks_per_depth := {}
	print("=== A1: the mesh at altitude, epsilon 0.5 m (the default), pixel %.4f rad" % PIXEL)
	print("    icosahedron edge %.4f rad" % (2.0 * asin(edge * 0.5)))
	print("    %-10s %-8s %-8s %-12s %-12s %s" % [
		"alt", "chunks", "tris", "chunk edge", "leaf edge", "depths"])
	for altitude in [2.0e6, 3.19e5, 1.0e5, 4.0e4, 1.0e4, 1.0e3, 1.0e2, 1.0e1]:
		var chunks := SpacesimPatches.select(
			EARTH + altitude, Vector3.RIGHT, EARTH, PIXEL, 0.5)
		if chunks.is_empty():
			print("    %-10s (nothing)" % ("%.0f m" % altitude))
			continue
		var shallowest := 99
		var deepest := -1
		for chunk in chunks:
			var depth := int(chunk[2])
			shallowest = mini(shallowest, depth)
			deepest = maxi(deepest, depth)
			chunks_per_depth[depth] = int(chunks_per_depth.get(depth, 0)) + 1
		var chunk_edge := _metres(edge / pow(2.0, float(deepest)), EARTH)
		var leaf_edge := _metres(edge / pow(2.0, float(deepest + SpacesimPatches.CHUNK_SUBDIVISIONS)), EARTH)
		print("    %-10s %-8d %-8d %-12s %-12s %d..%d" % [
			"%.0f m" % altitude, chunks.size(), chunks.size() * SpacesimPatches.CHUNK_TRIANGLES,
			_km(chunk_edge), _km(leaf_edge), shallowest, deepest])

	print("")
	print("=== A3: the smallest hill that mesh can show, by the sampling rule (8 triangles across a feature)")
	for altitude in [3.19e5, 4.0e4, 1.0e4, 1.0e3]:
		var chunks := SpacesimPatches.select(EARTH + altitude, Vector3.RIGHT, EARTH, PIXEL, 0.5)
		var deepest := 0
		for chunk in chunks:
			deepest = maxi(deepest, int(chunk[2]))
		var leaf := _metres(edge / pow(2.0, float(deepest + SpacesimPatches.CHUNK_SUBDIVISIONS)), EARTH)
		print("    %-10s leaf %-10s -> feature >= %-10s" % [
			"%.0f m" % altitude, _km(leaf), _km(leaf * 8.0)])

	print("")
	print("=== D1: what epsilon buys, in triangles (Earth, 40 km and 10 km)")
	for altitude in [4.0e4, 1.0e4]:
		for epsilon in [0.5, 0.25, 2.0]:
			var chunks := SpacesimPatches.select(EARTH + altitude, Vector3.RIGHT, EARTH, PIXEL, epsilon)
			print("    %-8s eps %-5s chunks %-6d tris %-8d" % [
				"%.0f m" % altitude, str(epsilon), chunks.size(),
				chunks.size() * SpacesimPatches.CHUNK_TRIANGLES])

	print("")
	print("=== B2/D2: the merge, warm, and with a per-vertex attribute alongside")
	print("    %-9s %-8s %-10s %-10s %s" % ["alt", "verts", "merge", "+attribute", "per vertex"])
	for altitude in [4.0e4, 1.0e4, 1.0e3]:
		var chunks := SpacesimPatches.select(EARTH + altitude, Vector3.RIGHT, EARTH, PIXEL, 0.5)
		# Warm the chunk cache first: the first `arrays_of` for a selection builds every chunk mesh, which is the
		# `build()` cost and not the merge.
		SpacesimPatches.arrays_of(chunks)
		var began := Time.get_ticks_usec()
		var arrays := SpacesimPatches.arrays_of(chunks)
		var plain := (Time.get_ticks_usec() - began) / 1000.0
		var count := (arrays[0] as PackedVector3Array).size()
		# The attribute a displaced vertex shader needs: one float per vertex (the chunk's leaf triangle edge).
		began = Time.get_ticks_usec()
		var spacing := PackedFloat32Array()
		spacing.resize(count)
		for index in count:
			spacing[index] = float(index % 7)
		var with_attribute := (Time.get_ticks_usec() - began) / 1000.0
		print("    %-9s %-8d %-10s %-10s %.2f us" % [
			"%.0f m" % altitude, count, "%.2f ms" % plain, "%.2f ms" % (plain + with_attribute),
			(plain * 1000.0) / maxf(float(count), 1.0)])
	print("")
	print("    A rebuild at 10x these counts is the number to watch: 60,000 triangles is ~180,000 vertices.")
	quit()


func _km(metres: float) -> String:
	if metres >= 1000.0:
		return "%.1f km" % (metres / 1000.0)
	return "%.0f m" % metres
