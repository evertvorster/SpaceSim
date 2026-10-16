extends SceneTree
## The cloud phases' first questions, asked before anything is built on the answers.
##
##     xvfb-run -a godot-double-mono --path . --script res://tests/probe_cloud_maps.gd
##
## ## Why these four, and why in this order
##
## The approved plan (vault `Cloud Decks` §4) puts **the address** first — one hierarchical
## `body -> layer -> face -> level -> cell` shared by geometry patches and texture tiles — and the tile
## quadtree after it. Both exist to give *resolution on demand*, and Evert's original shape was
## "as we zoom closer, we can refine the texture for the area that will be in view, so we get the
## illusion of infinite resolution."
##
## **That may be machinery clouds do not need**, and it is cheap to find out before writing it:
##
##   1. **Where does one whole-body map stop being enough?** A map of `W` texels around a body of radius
##      `r` has a texel `2*pi*r/W` long; it stops being enough when that texel projects to more than a
##      pixel, at `d = texel / pixel_angle`. If that distance is *above* the altitude where the near
##      regime takes over, no tiling is ever needed and the quadtree is dead weight.
##   2. **Can a big map be afforded at all?** An 8192x4096 bake is 100 MB as RGB8 and takes however long
##      it takes; if it is seconds, the bake has to go off the main thread, which is question 3.
##   3. **Can a mesh be built off the main thread?** The project's law is that the scene tree and the
##      `RenderingServer` are the main thread's; whether `ArrayMesh` construction is in that category is
##      not documented, and it decides whether a patch system can generate in the background at all.
##   4. **What is the device's texture ceiling?** A single map is only an option if 8192 is allowed.
##
## **Everything here is a measurement, and the numbers are the output.** Nothing is asserted.

const FOV := 70.0 ## the game's camera default
const RENDER_HEIGHT := 1080.0
const EARTH_RADIUS := 6.371e6
const JUPITER_RADIUS := 6.9911e7

var _thread_mesh: ArrayMesh = null
var _thread_note := "not attempted"


func _initialize() -> void:
	print("=== 1. where one map stops being enough ===")
	var pixel_angle := SpacesimLod.pixel_angle(FOV, RENDER_HEIGHT)
	# **GDScript's `%` has no `%e` and no `%g`** — both are runtime errors rather than formatting
	# surprises, and they sail through `--check-only`. Scale the number instead.
	print("pixel angle at %.0fp / %.0f deg: %.3f mrad" % [RENDER_HEIGHT, FOV, pixel_angle * 1000.0])
	print("")
	print("%-9s %-7s %-14s %-16s" % ["body", "map", "texel", "sub-pixel beyond"])
	for spec in [[EARTH_RADIUS, 2048], [EARTH_RADIUS, 4096], [EARTH_RADIUS, 8192],
			[JUPITER_RADIUS, 4096], [JUPITER_RADIUS, 8192]]:
		var radius: float = spec[0]
		var width: int = spec[1]
		# An equirectangular map: the whole circumference across the width.
		var texel := TAU * radius / float(width)
		var distance := texel / pixel_angle
		print("%-9s %-7d %-14s %-16s" % [
			"Earth" if radius < 1.0e7 else "Jupiter",
			width,
			"%.2f km" % (texel / 1000.0),
			"%.0f km" % (distance / 1000.0),
		])
	print("")
	print("Also worth having: Earth's cumulus fields are 1-2 km across, and the")
	print("band scale the model derives for Jupiter is 3,153 km.")
	print("")

	print("=== 2. what a bake costs ===")
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.01
	noise.fractal_octaves = 5
	for size in [[2048, 1024], [4096, 2048], [8192, 4096]]:
		var width: int = size[0]
		var height: int = size[1]
		var started := Time.get_ticks_usec()
		var image: Image = noise.get_image(width, height)
		var elapsed := Time.get_ticks_usec() - started
		var megabytes := float(image.get_data().size()) / 1.0e6
		print("%-5dx%-5d  %8.2f ms  %8.1f MB (%s)" % [
			width, height, elapsed / 1000.0, megabytes, str(image.get_format())
		])
	print("")

	print("=== 3. an ArrayMesh built on a worker thread ===")
	var task := WorkerThreadPool.add_task(Callable(self, "_build_off_thread"))
	WorkerThreadPool.wait_for_task_completion(task)
	if _thread_mesh == null:
		print("RESULT: no mesh came back — %s" % _thread_note)
	else:
		var surfaces := _thread_mesh.get_surface_count()
		var vertices := 0
		if surfaces > 0:
			vertices = _thread_mesh.surface_get_array_len(0)
		print("RESULT: built off-thread — %d surface(s), %d vertices, %s" % [
			surfaces, vertices, _thread_note
		])
	# The main-thread baseline for comparison: the largest icosphere the project builds.
	var started := Time.get_ticks_usec()
	var ico := SpacesimIcosphere.mesh_at(SpacesimLod.MAX_LEVEL)
	var elapsed := Time.get_ticks_usec() - started
	print("baseline: icosphere level %d on the main thread, %d surface(s), %.2f ms" % [
		SpacesimLod.MAX_LEVEL, ico.get_surface_count(), elapsed / 1000.0
	])
	print("")
	print("(4. the device's texture ceiling is reported from the first frame, where the")
	print("RenderingDevice exists.)")


## Builds a subdivided grid off the main thread. Deliberately not `SpacesimIcosphere.mesh_at()`, whose
## level cache is shared static state and would be a hazard rather than a test.
func _build_off_thread() -> void:
	var side := 64
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for row in range(side + 1):
		for column in range(side + 1):
			var u := float(column) / float(side)
			var v := float(row) / float(side)
			var direction := Vector3(u - 0.5, v - 0.5, 0.0).normalized()
			vertices.append(direction)
			normals.append(direction)
	for row in range(side):
		for column in range(side):
			var corner := row * (side + 1) + column
			indices.append(corner)
			indices.append(corner + 1)
			indices.append(corner + side + 1)
			indices.append(corner + 1)
			indices.append(corner + side + 2)
			indices.append(corner + side + 1)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var started := Time.get_ticks_usec()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var elapsed := Time.get_ticks_usec() - started
	_thread_mesh = mesh
	_thread_note = "add_surface_from_arrays took %.2f ms for %d triangles" % [
		elapsed / 1000.0, indices.size() / 3
	]


func _process(_delta: float) -> bool:
	var device := RenderingServer.get_rendering_device()
	if device == null:
		print("=== 4. texture ceiling ===")
		print("RESULT: no RenderingDevice here (headless has the dummy driver) —")
		print("rerun under xvfb-run for this question.")
		return true
	print("=== 4. texture ceiling ===")
	print("max 2D texture: %d px" % device.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_2D))
	print("max cube face:  %d px" % device.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_SIZE_CUBE))
	print("max array layers: %d" % device.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_ARRAY_LAYERS))
	print("device: %s" % RenderingServer.get_video_adapter_name())
	return true
