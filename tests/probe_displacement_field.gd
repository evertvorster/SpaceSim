extends SceneTree
## **Displacement investigation, block A2/C1** — what terrain error the current mesh law leaves behind.
##
## Needs a rendering device, because the field exists only in GLSL and is read here from the baked map:
##   xvfb-run -a godot-double-mono --path . --script res://tests/probe_displacement_field.gd
##
## **The question**: the mesh's error law bounds the *sphere's* sagitta at `lod.error_budget` (0.5 m). Once vertices
## carry terrain, what matters is the **height variation across a patch** — how much ground a triangle flattens. This
## measures that, for the chunks the real walk selects, at the altitudes where it could matter. Nothing is
## re-derived: `SpacesimPatches.select` is the game's walk, and the field is the game's own bake.

const EARTH := 6.371e6
const PIXEL := 1.2966806e-3
const WIDTH := 4096
const HEIGHT := 2048

var _map: Image


func _init() -> void:
	var gpu := SpacesimSurfaceGpu.new()
	if not gpu.open():
		print("no rendering device: ", gpu.error())
		quit(1)
		return
	var plan := SpacesimSurfaceField.plan("planet:earth", EARTH)
	_map = gpu.bake(plan, WIDTH, HEIGHT)
	gpu.close()
	if _map == null:
		print("bake failed")
		quit(1)
		return

	print("=== A2/C1: terrain error left by the CURRENT mesh law, field from a %dx%d bake" % [WIDTH, HEIGHT])
	print("    texel %.1f km at the equator; a chunk smaller than that cannot be measured from this map" % (
		TAU * EARTH / float(WIDTH) / 1000.0))
	print("    %-9s %-6s %-7s %-10s %-11s %-11s %s" % [
		"alt", "eps", "tris", "deepest", "worst var", "worst var", "median var"])
	for altitude in [3.19e5, 1.0e5, 4.0e4, 1.0e4]:
		for epsilon in [0.5, 2.0, 8.0]:
			var chunks := SpacesimPatches.select(EARTH + altitude, Vector3.RIGHT, EARTH, PIXEL, epsilon)
			if chunks.is_empty():
				continue
			var worst := 0.0
			var spread: Array = []
			var deepest := 0
			for chunk in chunks:
				deepest = maxi(deepest, int(chunk[2]))
				var variation := _variation(chunk)
				spread.append(variation)
				worst = maxf(worst, variation)
			spread.sort()
			var median: float = spread[spread.size() / 2]
			var distance: float = altitude
			var px_worst: float = worst / distance / PIXEL
			print("    %-9s %-6s %-7d %-10s %-11s %-11s %s" % [
				"%.0f km" % (altitude / 1000.0), str(epsilon),
				chunks.size() * SpacesimPatches.CHUNK_TRIANGLES,
				"d%d" % deepest,
				_km(worst), "%.1f px" % px_worst, _km(median)])
	print("")
	print("    **px** is the height error divided by the distance and the pixel angle: the number of pixels of")
	print("    ground the flattened triangle is out by, at the patch's own distance.")
	quit()


## **The height variation inside one chunk**, as `max - min` over its three corners and three edge midpoints,
## sampled from the baked map with the equirect mapping the shaders use.
func _variation(chunk: Array) -> float:
	var face: Array = SpacesimIcosphere.FACES[int(chunk[0])]
	var corners: Array = [
		SpacesimIcosphere.VERTICES[int(face[0])].normalized(),
		SpacesimIcosphere.VERTICES[int(face[1])].normalized(),
		SpacesimIcosphere.VERTICES[int(face[2])].normalized(),
	]
	# Descend the chunk's own address, so the sample points are the corners of the *chunk*, not the whole face.
	var depth := int(chunk[2])
	var path := String(chunk[1])
	var points: Array = corners.duplicate()
	for index in path.length():
		var child := path.substr(index, 1).to_int()
		points = _child_corners(points, child)
	var samples: Array = points.duplicate()
	for index in points.size():
		samples.append((points[index] + points[(index + 1) % points.size()]).normalized())
	samples.append(((points[0] + points[1] + points[2]) / 3.0).normalized())
	var lowest := INF
	var highest := -INF
	for point in samples:
		var value := _sample(point)
		lowest = minf(lowest, value)
		highest = maxf(highest, value)
	# Field units to metres: `field_amplitude` is the plan's own relief amplitude for this body.
	return (highest - lowest) * EARTH * SpacesimSurfaceField.RELIEF_FRACTION


func _child_corners(points: Array, child: int) -> Array:
	var a: Vector3 = points[0]
	var b: Vector3 = points[1]
	var c: Vector3 = points[2]
	var ab := (a + b).normalized()
	var bc := (b + c).normalized()
	var ca := (c + a).normalized()
	match child:
		0:
			return [a, ab, ca]
		1:
			return [ab, b, bc]
		2:
			return [ca, bc, c]
		_:
			return [ab, bc, ca]


## The map's value at a direction, bilinearly — the same mapping and the same interpolation the shaders use.
func _sample(direction: Vector3) -> float:
	var u := 0.5 + atan2(direction.z, direction.x) / TAU
	var v := 0.5 - asin(clampf(direction.y, -1.0, 1.0)) / PI
	var x := clampf(u, 0.0, 1.0) * float(WIDTH) - 0.5
	var y := clampf(v, 0.0, 1.0) * float(HEIGHT) - 0.5
	var x0 := int(floor(x))
	var y0 := int(floor(y))
	var fx := x - float(x0)
	var fy := y - float(y0)
	var x1 := mini(x0 + 1, WIDTH - 1)
	var y1 := mini(y0 + 1, HEIGHT - 1)
	x0 = maxi(x0, 0)
	y0 = maxi(y0, 0)
	var a := _map.get_pixel(x0, y0).r
	var b := _map.get_pixel(x1, y0).r
	var c := _map.get_pixel(x0, y1).r
	var d := _map.get_pixel(x1, y1).r
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)


func _km(metres: float) -> String:
	if metres >= 1000.0:
		return "%.1f km" % (metres / 1000.0)
	return "%.0f m" % metres
