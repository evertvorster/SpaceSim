extends SceneTree
## **Can one patch mesh be instanced?** A rigid copy of one shape lands exactly on another only when the two are the same
## shape — otherwise every boundary opens by the difference, which is what Evert's "all triangles are connected with
## shared vertices, there can never be a gap" forbids.
##
## So: are the chunk OUTLINES at one depth congruent? Reconstructed with the same path arithmetic `_chunk_arrays_for`
## uses, and reported as the spread of each spherical side across chunks at that depth. A spread of 0 means instancing
## is exact; anything else is the gap it would open, in metres.
##
##   godot-double-mono --headless --path . --script res://tests/probe_patch_congruence.gd

const RADIUS := 6371000.0


func _init() -> void:
	for depth in [4, 6, 8, 10]:
		var chunks := SpacesimPatches.select(RADIUS * 1.5, Vector3.UP, RADIUS, 1.3e-3, 0.5)
		var shortest := Vector3(INF, INF, INF)
		var longest := Vector3.ZERO
		var count := 0
		for chunk in chunks:
			if int(chunk[2]) != depth:
				continue
			var sides := _outline_sides(chunk)
			shortest = Vector3(minf(shortest.x, sides.x), minf(shortest.y, sides.y), minf(shortest.z, sides.z))
			longest = Vector3(maxf(longest.x, sides.x), maxf(longest.y, sides.y), maxf(longest.z, sides.z))
			count += 1
		if count == 0:
			print("depth %2d  no chunks at this depth" % depth)
			continue
		var worst := 0.0
		for axis in 3:
			worst = maxf(worst, (longest[axis] - shortest[axis]) / maxf(shortest[axis], 1.0e-30))
		print("depth %2d  %5d chunks  side spread %.6f%%  = %.3f m at Earth" % [
			depth, count, worst * 100.0, (longest.x - shortest.x) * RADIUS
		])
	quit(0)


## A chunk's three spherical side lengths, from the same corner arithmetic the geometry uses.
static func _outline_sides(chunk: Array) -> Vector3:
	var face: Array = SpacesimPatches.ROOT_FACES[int(chunk[0])]
	var a: Vector3 = SpacesimIcosphere.VERTICES[int(face[0])].normalized()
	var b: Vector3 = SpacesimIcosphere.VERTICES[int(face[1])].normalized()
	var c: Vector3 = SpacesimIcosphere.VERTICES[int(face[2])].normalized()
	var route := String(chunk[1])
	for index in route.length():
		var kids: Array = SpacesimPatches._child_triangles(a, b, c)
		var kid: Array = kids[int(route[index])]
		a = kid[0]
		b = kid[1]
		c = kid[2]
	return Vector3(a.angle_to(b), b.angle_to(c), c.angle_to(a))
