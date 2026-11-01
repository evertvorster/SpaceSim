class_name SpacesimSurfaceGpu
extends RefCounted
## **The surface height field, baked on the GPU** — one `R16F` map per body, from the plan
## [method SpacesimSurfaceField.plan] derives.
##
## ## The shape is `SpacesimCloudGpu`'s, and the arrangement is not
##
## The cloud bake has a CPU twin that stays, because it is also the only route a headless run has. **This
## one does not**: the GLSL in `surface_field.gdshaderinc` is the single implementation, and the CPU
## transcription beside it exists only to design the shader against and is retired with it (Evert,
## 2026-10-19). So there is no fallback here and no second code path — a run without a rendering device has
## no surface maps, which the suite knows.
##
## ## Why the format is `R16F` and not `R8`
##
## The height is **differentiated** to make normals, and 256 levels over a ±10 km range terraces every gentle
## slope into visible steps. **And it is one 16-bit channel, not two packed into an `RGBA8`** — filtering and
## mipping a value split across two channels is invalid: mip 1 and beyond average the halves separately and
## produce nonsense. `R16F` is what the hardware filters and mips correctly.
##
## ## A LOCAL rendering device, deliberately
##
## Not `RenderingServer.get_rendering_device()`, which belongs to the render thread and whose RID allocator
## is not thread safe. A local device is ours, we submit and synchronise explicitly, and it cannot disturb
## the frame. Its calls are **render-thread-only** — a `WorkerThreadPool` task that touches one does nothing
## and reports an error per call — so a bake happens where the device was opened, on the main thread.
## `create_local_rendering_device()` returns `null` under `--headless`, which is why a bake is a real-run
## thing.

## **The source is assembled by the field**, not here: `SpacesimSurfaceField.source()` is `#version`, the
## noise, the field and the kernel, so this bake and the render-thread one compile the same program.




var _device: RenderingDevice
## **How many RIDs this device has created and not freed** — the same instrument its cloud twin carries, and for
## the same reason. A whole-map bake creates a texture and a uniform set and frees both; the shader and pipeline
## live until [method close]. A number that is not zero at teardown is a leak, and the allocator exhaustion that
## cost this project two flights was found in a pass that was reading someone else's error.
##
## **Counted only once the RID exists**, so a failed create cannot leave a phantom and make `close()` cry wolf.
var _rids_live := 0
var _shader: RID
var _pipeline: RID
## **The heights pipeline**, compiled from the same field with a different kernel — see [method heights]. Separate
## shader and pipeline because a compute source is one program, and this one reads a buffer rather than an image.
var _heights_shader: RID
var _heights_pipeline: RID
var _error := ""
var _tried := false
## Where the last bake's time went, in microseconds: `create`, `dispatch`, `readback`. Split before anything
## is optimised — the cloud port's read-back was 10% of its bake and looked like the problem.
var last_microseconds: Dictionary = {}


## Compile the kernel and keep the device. Safe to call repeatedly; a failure is remembered, so a scene with
## no GPU does not retry the compile every frame.
func open() -> bool:
	if _pipeline.is_valid():
		return true
	if _tried:
		return false
	_tried = true
	var device := RenderingServer.create_local_rendering_device()
	if device == null:
		_error = "no local RenderingDevice (headless, or not a Vulkan/Forward+ run)"
		return false
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = _source()
	var spirv := device.shader_compile_spirv_from_source(source)
	# `get_stage_compile_error()` returns the message STRING, not an `Error` — empty means it compiled.
	var message := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not message.is_empty():
		_error = "the compute shader did not compile: " + message
		# **The device is freed on every failure path too.** A local `RenderingDevice` left alive segfaults
		# the process at teardown, and a shader that will not compile is exactly when that happens — the
		# probe that found this exited 139 with the compile error above the crash.
		device.free()
		return false
	_shader = device.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		_error = "shader_create_from_spirv() gave an invalid RID"
		device.free()
		return false
	_pipeline = device.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_error = "compute_pipeline_create() gave an invalid RID"
		device.free()
		return false
	_device = device
	_rids_live += 2  ## the shader and the pipeline, both checked valid above
	return true


## Release the device and everything on it.
##
## **The device is freed, not merely dropped.** A local `RenderingDevice` left alive to be destroyed at
## process teardown **segfaults on exit** (measured 2026-10-17 on the cloud port: exit 139 with no output,
## from a probe that had done its work and printed the result). It is an `Object`, so `free()` works.
func close() -> void:
	if _device != null and _heights_pipeline.is_valid():
		_device.free_rid(_heights_pipeline)
		_rids_live -= 1
	if _device != null and _heights_shader.is_valid():
		_device.free_rid(_heights_shader)
		_rids_live -= 1
	if _device != null and _pipeline.is_valid():
		_device.free_rid(_pipeline)
		_rids_live -= 1
	if _device != null and _shader.is_valid():
		_device.free_rid(_shader)
		_rids_live -= 1
	if _rids_live != 0:
		printerr(
			"ERROR: SpacesimSurfaceGpu: %d RID(s) created and never freed — a bake's texture and uniform set "
			% _rids_live
			+ "must come back, or the device's allocator fills"
		)
	_pipeline = RID()
	_shader = RID()
	_heights_pipeline = RID()
	_heights_shader = RID()
	if _device != null:
		_device.free()
		_device = null
	_tried = false


## Why [method open] did not work, or an empty string.
func error() -> String:
	return _error


## **The field's height at each of a list of DIRECTIONS**, on the device that already bakes it.
##
## **This is what a vertex is translated by, and it is why there is no raster.** A map answers "the height near
## (u, v)" on a lattice a mesh has no use for: at 1 km altitude a facet is ~35 m across, so a global map fine enough
## to carry the mesh is 10^12 texels. The lattice already holds the directions it needs, so they are asked exactly —
## `surface_height` from the same GLSL the draw shader and the bake run, at `footprint = 0`, which `surface_height`
## reads as *no limit*: a point's height is a pure function of its direction and never changes when the LOD does.
##
## **The calls are render-thread-only** — a local `RenderingDevice` from a `WorkerThreadPool` task does nothing and
## reports an error per call — so this is called from the main thread, between a build landing and its publish.
##
## Returns an empty array when there is no device (headless) or the kernel would not compile; [method error] then says
## why. The value is the FIELD's, in field units about ±1, not metres and not sea-levelled — the caller scales it.
func heights(plan_data: SpacesimSurfaceField.Plan, directions: PackedVector3Array) -> PackedFloat32Array:
	if directions.is_empty() or not _open_heights():
		return PackedFloat32Array()
	var count := directions.size()
	# **Padded to the workgroup**, so the kernel needs no bound and no number in the plan's block. The tail is
	# discarded on read-back.
	var padded := ceili(count / 64.0) * 64
	# `vec4` per direction: std430 gives a `vec3` a 16-byte stride anyway, and saying it explicitly keeps the buffer
	# the shape the kernel declares.
	var input := PackedFloat32Array()
	input.resize(padded * 4)
	for index in count:
		var unit := directions[index]
		input[index * 4] = unit.x
		input[index * 4 + 1] = unit.y
		input[index * 4 + 2] = unit.z

	var marker := Time.get_ticks_usec()
	var in_buffer := _device.storage_buffer_create(input.to_byte_array().size(), input.to_byte_array())
	var out_buffer := _device.storage_buffer_create(padded * 4)
	if not in_buffer.is_valid() or not out_buffer.is_valid():
		_error = "storage_buffer_create() gave an invalid RID"
		if in_buffer.is_valid():
			_device.free_rid(in_buffer)
		if out_buffer.is_valid():
			_device.free_rid(out_buffer)
		return PackedFloat32Array()
	_rids_live += 2
	last_microseconds["create"] = Time.get_ticks_usec() - marker

	var sets := []
	for binding in 2:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = binding
		uniform.add_id(in_buffer if binding == 0 else out_buffer)
		sets.append(uniform)
	var uniform_set := _device.uniform_set_create(sets, _heights_shader, 0)
	if not uniform_set.is_valid():
		_error = "uniform_set_create() gave an invalid RID"
		_device.free_rid(in_buffer)
		_device.free_rid(out_buffer)
		_rids_live -= 2
		return PackedFloat32Array()
	_rids_live += 1

	# **The plan's block, at the size it declares** — 112 bytes, and the driver rejects anything else. `size` and the
	# two `vec2`s are the bake's; a heights dispatch passes zeros and never reads them.
	var params := SpacesimSurfaceField.push_constants(plan_data, 0, 0)
	var list := _device.compute_list_begin()
	_device.compute_list_bind_compute_pipeline(list, _heights_pipeline)
	_device.compute_list_bind_uniform_set(list, uniform_set, 0)
	_device.compute_list_set_push_constant(list, params, params.size())
	_device.compute_list_dispatch(list, padded / 64, 1, 1)
	_device.compute_list_end()

	marker = Time.get_ticks_usec()
	_device.submit()
	_device.sync()
	last_microseconds["dispatch"] = Time.get_ticks_usec() - marker
	marker = Time.get_ticks_usec()
	var data := _device.buffer_get_data(out_buffer)
	last_microseconds["readback"] = Time.get_ticks_usec() - marker

	_device.free_rid(uniform_set)
	_device.free_rid(in_buffer)
	_device.free_rid(out_buffer)
	_rids_live -= 3

	if data.size() != padded * 4:
		_error = "read back %d bytes for %d heights" % [data.size(), padded]
		return PackedFloat32Array()
	var heights := data.to_float32_array()
	heights.resize(count)
	return heights


## **A body's whole-surface height map, from the GPU**: `FORMAT_RH`, equirectangular, north at the top row,
## values about ±1 (the field's own, **not** metres and **not** sea-levelled — sea level is a percentile of
## the distribution, measured from this).
##
## Returns `null` with [method error] set when there is no device to run on.
func bake(
	plan_data: SpacesimSurfaceField.Plan, width: int, height: int,
	uv_origin: Vector2 = Vector2.ZERO, uv_size: Vector2 = Vector2.ONE
) -> Image:
	if not open():
		return null
	var w := maxi(width, 1)
	var h := maxi(height, 1)

	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	format.width = w
	format.height = h
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	var marker := Time.get_ticks_usec()
	var texture := _device.texture_create(format, RDTextureView.new())
	last_microseconds["create"] = Time.get_ticks_usec() - marker
	if not texture.is_valid():
		_error = "texture_create() gave an invalid RID"
		return null
	_rids_live += 1

	var image_uniform := RDUniform.new()
	image_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image_uniform.binding = 0
	image_uniform.add_id(texture)
	var uniform_set := _device.uniform_set_create([image_uniform], _shader, 0)
	if not uniform_set.is_valid():
		_error = "uniform_set_create() gave an invalid RID"
		_device.free_rid(texture)
		_rids_live -= 1
		return null
	_rids_live += 1

	var params := SpacesimSurfaceField.push_constants(plan_data, w, h, uv_origin, uv_size)
	# Every `compute_list_*` call takes the list handle FIRST, and it is an `int`.
	var list := _device.compute_list_begin()
	_device.compute_list_bind_compute_pipeline(list, _pipeline)
	_device.compute_list_bind_uniform_set(list, uniform_set, 0)
	_device.compute_list_set_push_constant(list, params, params.size())
	_device.compute_list_dispatch(list, ceili(w / 8.0), ceili(h / 8.0), 1)
	_device.compute_list_end()

	# A local device processes nothing until it is told to, and reads back only after a synchronisation.
	marker = Time.get_ticks_usec()
	_device.submit()
	_device.sync()
	last_microseconds["dispatch"] = Time.get_ticks_usec() - marker
	marker = Time.get_ticks_usec()
	var data := _device.texture_get_data(texture, 0)
	last_microseconds["readback"] = Time.get_ticks_usec() - marker

	_device.free_rid(uniform_set)
	_device.free_rid(texture)
	_rids_live -= 2

	if data.size() != w * h * 2:
		_error = "read back %d bytes for a %dx%d half-float map" % [data.size(), w, h]
		return null
	var image := Image.create_from_data(w, h, false, Image.FORMAT_RH, data)
	image.set_meta("spacesim_bake", "gpu")
	return image


## The noise, then the field, then the kernel, under one `#version` — assembled by
## `SpacesimSurfaceField.source()`, because a source string gets no preprocessor help. This is the one
## call, not a copy of the assembly.
func _source() -> String:
	return SpacesimSurfaceField.source()


## **The heights kernel's own shader and pipeline**, compiled on first use from the same assembler with the other
## kernel — and kept for the session, because a geometry rebuild asks for heights on every walk.
##
## **Its own `RenderingDevice` is NOT created**: this reuses the one [method open] made, so a scene holds one device
## and one teardown, which is the shape the RID counter and `close()` already assume.
func _open_heights() -> bool:
	if _heights_pipeline.is_valid():
		return true
	if not open():
		return false
	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = SpacesimSurfaceField.source_for_heights()
	var spirv := _device.shader_compile_spirv_from_source(source)
	var message := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not message.is_empty():
		_error = "the heights kernel did not compile: " + message
		return false
	_heights_shader = _device.shader_create_from_spirv(spirv)
	if not _heights_shader.is_valid():
		_error = "heights: shader_create_from_spirv() gave an invalid RID"
		return false
	_heights_pipeline = _device.compute_pipeline_create(_heights_shader)
	if not _heights_pipeline.is_valid():
		_error = "heights: compute_pipeline_create() gave an invalid RID"
		return false
	_rids_live += 2
	return true


## How many RIDs the device holds right now. **Zero between bakes**, and the GPU suite asserts it: an
## instrument is only worth having if something fails when it moves.
func live_rids() -> int:
	return _rids_live
