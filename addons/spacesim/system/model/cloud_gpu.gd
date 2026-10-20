class_name SpacesimCloudGpu
extends RefCounted
## **The cloud field, baked on the GPU** — the same map [method SpacesimCloudField.bake] produces, from
## the same plan, in a fraction of the time.
##
## ## Why this exists
##
## `bake()` is **92 ns a texel** — 3.10 s and 33.6 MB for an 8192x4096 map — and that is the interpreter,
## not the arithmetic: a texel's worth of noise is a few dozen instructions. The GPU ceiling is 0.1-1 ns a
## texel, which is why the per-texel body became a shader rather than a faster GDScript function.
##
## ## The CPU path is the reference, and it stays
##
## Nothing here decides what the field *is*. `SpacesimCloudField.plan()` derives the numbers, the GLSL in
## `cloud_field.gdshaderinc` is a transcription of `intensity_at()`, and `tests/test_cloud_gpu.gd` bakes a
## small map through both and compares them. **The GPU path is an optimisation until that test says
## otherwise**, and the CPU path also stays because it is the only one that runs headless.
##
## ## A LOCAL rendering device, deliberately
##
## Not `RenderingServer.get_rendering_device()`. A local device is ours: we submit and synchronise
## explicitly, it cannot disturb the frame, and the class reference documents it as usable **on a separate
## thread**, which is where the refinements already run. The cost is that it needs a real rendering driver —
## **in headless mode `create_local_rendering_device()` returns `null`**, so a headless run falls back to
## the CPU path by construction rather than by a flag. That is what keeps `tests/run.sh` honest and makes
## the GPU path an addition rather than a replacement.
##
## ## What is copied back, and why that is still the right shape
##
## The whole map, once. 33 MB of read-back is cheap beside 3 s of interpretation, and it keeps the change
## to *generation only*: `threshold_for()`, `mean_exceedance()`, `mean_opacity()`, `ramp_gain()`, the LRU
## cache and the worker pool all keep working on an `Image` they were already given. A GPU-side histogram
## is the next step only if a measurement asks for it.

## The GLSL is **text**, not a `Shader`: it is prepended with `#version 450` and compiled from a source
## string, which is why it carries no version, no layout and no entry point of its own.
const FIELD_PATH := "res://addons/spacesim/system/model/cloud_field.gdshaderinc"
## **The noise, in its own file**, in front of the field because a source string gets no preprocessor.
##
## It moved out of [constant FIELD_PATH] on 2026-10-19, when the surface field became a second consumer: one
## copy of the noise, two ways in, and `tests/test_cloud_gpu.gd` is what says the move changed nothing —
## it bakes the same map through both paths and compares them level for level.
const NOISE_PATH := "res://addons/spacesim/system/model/noise.gdshaderinc"

## The kernel: the bindings, the parameters, and the row/column -> direction mapping of `bake()`.
##
## **No `#[compute]` marker.** That is Godot's *file* convention — `RDShaderFile` strips it before glslang
## sees the source — and a string handed to `shader_compile_spirv_from_source()` gets no such treatment:
## glslang fails with *"2: '#': invalid directive"* and `#version` has to be the first thing in the string.
const KERNEL := """
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r8, set = 0, binding = 0) uniform image2D out_map;

// `centres` is the vortex centre in `xyz` and `1 - cos(reach)` in `w`; `twists` is the radians in `x`.
// Two arrays of `vec4` rather than one struct array, so every entry is 16-byte aligned and the host side
// is a flat byte buffer.
layout(set = 0, binding = 1, std430) readonly buffer VortexStack {
	vec4 centres[CLOUD_VORTEX_MAX];
	vec4 twists[CLOUD_VORTEX_MAX];
} vortices;

layout(push_constant, std430) uniform Params {
	ivec2 size;
	vec2 uv_origin;
	vec2 uv_size;
	float mix_value;
	float cells;
	float ratio;
	float feature;
	float phase;
	float meander;
	int coarse_seed;
	float coarse_frequency;
	int fine_seed;
	float fine_frequency;
	int octaves;
	float gain;
	float lacunarity;
	float bounding;
	int vortex_count;
	int uniform_field;
	int has_coarse;
	int has_fine;
} params;

const float PI = 3.141592653589793;
const float TAU = 6.283185307179586;

void main() {
	// **Stage the eddy stack into workgroup memory first, and before any early return.** Every texel needs
	// all 96 vortices, and reading them from the `std430` buffer per texel was 82% of this kernel's cost. One
	// coalesced load per entry per 64-texel tile replaces ~3 GB of buffer traffic on an 8192x4096 map.
	//
	// The barrier is mandatory and uniform: every thread in the group must reach it, which is why the bounds
	// test below comes AFTER it rather than before.
	for (int index = int(gl_LocalInvocationIndex); index < params.vortex_count;
			index += int(gl_WorkGroupSize.x * gl_WorkGroupSize.y * gl_WorkGroupSize.z)) {
		cloud_centres[index] = vortices.centres[index];
		cloud_twists[index] = vortices.twists[index];
	}
	barrier();

	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (pos.x >= params.size.x || pos.y >= params.size.y) {
		return;
	}
	// The map's own `(u, v)`: `u` around the equator, `v` pole to pole, and a window is an offset and a
	// scale of the same mapping. Pixel centres, as `bake()` uses — half a texel in, so the seam and the
	// poles land where the CPU path puts them.
	float u = params.uv_origin.x + (float(pos.x) + 0.5) / float(params.size.x) * params.uv_size.x;
	float v = params.uv_origin.y + (float(pos.y) + 0.5) / float(params.size.y) * params.uv_size.y;
	float latitude = PI * 0.5 - v * PI;
	float longitude = (u - 0.5) * TAU;
	float cos_latitude = cos(latitude);
	// Unit by construction: `cos^2(lat)cos^2(lon) + sin^2(lat) + cos^2(lat)sin^2(lon) = 1`.
	vec3 direction = vec3(
		cos_latitude * cos(longitude), sin(latitude), cos_latitude * sin(longitude));

	float value = 1.0;
	if (params.uniform_field == 0) {
		CloudField field;
		field.mix_value = params.mix_value;
		field.cells = params.cells;
		field.ratio = params.ratio;
		field.feature = params.feature;
		field.phase = params.phase;
		field.meander = params.meander;
		CloudNoise coarse;
		coarse.seed = params.coarse_seed;
		coarse.frequency = params.coarse_frequency;
		coarse.octaves = params.octaves;
		coarse.gain = params.gain;
		coarse.lacunarity = params.lacunarity;
		coarse.bounding = params.bounding;
		CloudNoise fine = coarse;
		fine.seed = params.fine_seed;
		fine.frequency = params.fine_frequency;
		value = cloud_intensity_at(
			direction, field, coarse, params.has_coarse != 0, fine, params.has_fine != 0,
			params.vortex_count);
	}

	// **Truncated here, not by the texture format.** The CPU writes `int(value * 255.0)` — a truncation —
	// and `R8_UNORM` rounds to nearest, so half a map would come back one level high. Pre-truncating to a
	// multiple of `1/255` makes the conversion exact and the two paths comparable level for level.
	value = clamp(value, 0.0, 1.0);
	imageStore(out_map, pos, vec4(floor(value * 255.0) / 255.0, 0.0, 0.0, 1.0));
}
"""

## The push-constant block's size in bytes: 96, and it must stay under the 128 a Vulkan implementation is
## required to provide. Layout is in [constant KERNEL]; the offsets are written out in [method _params].
const PARAMS_SIZE := 96

var _device: RenderingDevice
## **How many RIDs this device has created and not freed.** Every bake creates three and frees three, and the
## shader and pipeline live until `close()` — so a number that is not zero at teardown is a leak, and this is
## an instrument rather than a guard: the same class of bug (a per-frame allocation that is never freed)
## exhausted the frame device's allocator twice in this project, and both times it was found by a flight, in a
## pass that was looking at someone else's error.
var _rids_live := 0
var _shader: RID
var _pipeline: RID
var _error := ""
var _tried := false
## Where the last bake's time went, in microseconds, for the probe and for whoever asks next whether the
## read-back is the bottleneck: `create`, `dispatch`, `readback`.
var last_microseconds: Dictionary = {}


## Compile the kernel and keep the device. Safe to call repeatedly; a failure is remembered, so a scene
## with no GPU does not retry the compile every frame.
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
	# `get_stage_compile_error()` returns the message STRING, not an `Error` — an empty one means it
	# compiled. Headless Godot would not have compiled it at all, which is why the check is here.
	var message := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not message.is_empty():
		_error = "the compute shader did not compile: " + message
		# **The device is freed on every failure path too.** A local `RenderingDevice` left alive segfaults
		# the process at teardown, and a shader that will not compile is exactly when that happens — the
		# probe that found this exited 139 with the compile error above the crash.
		device.free()
		return false
	_shader = device.shader_create_from_spirv(spirv)
	_rids_live += 1
	if not _shader.is_valid():
		_error = "shader_create_from_spirv() gave an invalid RID"
		device.free()
		return false
	_pipeline = device.compute_pipeline_create(_shader)
	_rids_live += 1
	if not _pipeline.is_valid():
		_error = "compute_pipeline_create() gave an invalid RID"
		device.free()
		return false
	_device = device
	return true


func close() -> void:
	if _device != null and _pipeline.is_valid():
		_device.free_rid(_pipeline)
		_rids_live -= 1
	if _device != null and _shader.is_valid():
		_device.free_rid(_shader)
		_rids_live -= 1
	if _rids_live != 0:
		printerr(
			"ERROR: SpacesimCloudGpu: %d RID(s) created and never freed — every bake's texture, buffer and "
			% _rids_live
			+ "uniform set must come back, or the device's allocator fills"
		)
	_pipeline = RID()
	_shader = RID()
	# **The device is freed, not merely dropped.** A local `RenderingDevice` left alive to be destroyed at
	# process teardown **segfaults on exit** (measured 2026-10-17: exit 139 with no output, from a probe
	# that had done its work and printed the result). `RenderingDevice` has no `free_rid()` for itself and
	# the class reference names no teardown method, but it is an `Object`, so `free()` works — and the same
	# process that segfaulted then exits 0.
	if _device != null:
		_device.free()
		_device = null
	_tried = false


## Why `open()` did not work, or an empty string. Reported rather than thrown: a bake that cannot run on
## the GPU is a bake that runs on the CPU.
## How many RIDs the device holds right now. **Zero between bakes**, and the GPU suite asserts it: the
## instrument is only worth having if something fails when it moves.
func live_rids() -> int:
	return _rids_live


func error() -> String:
	return _error


## **One layer's coverage map, from the GPU.** The same arguments as [method SpacesimCloudField.bake] and
## the same `Image`, or `null` with [method error] set — callers fall back to the CPU path.
func bake(
	seed: int, morphology: SpacesimCloudModel.Morphology, width: int, height: int,
	uv_origin: Vector2 = Vector2(0.0, 0.0), uv_size: Vector2 = Vector2(1.0, 1.0)
) -> Image:
	if not open():
		return null
	var w := maxi(width, 1)
	var h := maxi(height, 1)
	var planned := SpacesimCloudField.plan(seed, morphology)
	if planned.stack.centres.size() > SpacesimCloudField.VORTEX_BUDGET:
		_error = "the eddy stack has %d vortices against a shader budget of %d" % [
			planned.stack.centres.size(), SpacesimCloudField.VORTEX_BUDGET
		]
		return null

	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R8_UNORM
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
	_rids_live += 1
	last_microseconds["create"] = Time.get_ticks_usec() - marker
	if not texture.is_valid():
		_error = "texture_create() gave an invalid RID"
		return null

	var vortex_bytes := _vortex_bytes(planned.stack)
	var buffer := _device.storage_buffer_create(vortex_bytes.size(), vortex_bytes)
	_rids_live += 1

	var image_uniform := RDUniform.new()
	image_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image_uniform.binding = 0
	image_uniform.add_id(texture)
	var buffer_uniform := RDUniform.new()
	buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	buffer_uniform.binding = 1
	buffer_uniform.add_id(buffer)
	var uniform_set := _device.uniform_set_create([image_uniform, buffer_uniform], _shader, 0)
	_rids_live += 1
	if not uniform_set.is_valid():
		_error = "uniform_set_create() gave an invalid RID"
		_device.free_rid(texture)
		_device.free_rid(buffer)
		_rids_live -= 2
		return null

	var params := _params(w, h, planned, uv_origin, uv_size)
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
	_device.free_rid(buffer)
	_rids_live -= 3

	if data.size() != w * h:
		_error = "read back %d bytes for a %dx%d map" % [data.size(), w, h]
		return null
	var image := Image.create_from_data(w, h, false, Image.FORMAT_L8, data)
	image.set_meta("spacesim_bake", "gpu")
	return image


## The include, then the kernel, under one `#version`. Assembled rather than `#include`d because a source
## string gets no preprocessor help: this is the whole of the "include" mechanism for a compute shader
## compiled at runtime.
func _source() -> String:
	return (
		"#version 450\n"
		+ FileAccess.get_file_as_string(NOISE_PATH)
		+ FileAccess.get_file_as_string(FIELD_PATH)
		+ KERNEL
	)


## The eddy stack as the shader's two `vec4` arrays: centre + `1 - cos(reach)`, then the twist.
func _vortex_bytes(stack: SpacesimCloudField.Vortices) -> PackedByteArray:
	var count := stack.centres.size() if stack != null else 0
	var bytes := PackedByteArray()
	bytes.resize(SpacesimCloudField.VORTEX_BUDGET * 16 * 2)
	for index in count:
		var centre := stack.centres[index]
		var offset := index * 16
		bytes.encode_float(offset, centre.x)
		bytes.encode_float(offset + 4, centre.y)
		bytes.encode_float(offset + 8, centre.z)
		bytes.encode_float(offset + 12, stack.reaches[index])
		var twist_offset := SpacesimCloudField.VORTEX_BUDGET * 16 + index * 16
		bytes.encode_float(twist_offset, stack.twists[index])
	return bytes


## The push-constant block, written field by field so the layout is readable beside the shader's.
##
## **Every number past the geometry is derived on this side.** The frequencies, the octave count and the
## FBM normaliser come off the plan's own generators; a constant typed into the GLSL would be a second
## copy of a number the generator already knows, and it would drift.
func _params(
	w: int, h: int, planned: SpacesimCloudField.Plan, uv_origin: Vector2, uv_size: Vector2
) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(PARAMS_SIZE)
	bytes.encode_s32(0, w)
	bytes.encode_s32(4, h)
	bytes.encode_float(8, uv_origin.x)
	bytes.encode_float(12, uv_origin.y)
	bytes.encode_float(16, uv_size.x)
	bytes.encode_float(20, uv_size.y)
	bytes.encode_float(24, planned.mix)
	bytes.encode_float(28, planned.cells)
	bytes.encode_float(32, planned.ratio)
	bytes.encode_float(36, planned.feature)
	bytes.encode_float(40, planned.phase)
	bytes.encode_float(44, SpacesimCloudField.MEANDER)
	# The frequency and seed come off the generator itself, so the shader and the CPU path cannot be given
	# different ones. Both halves use the same seed — `fine_for()` raises the frequency, nothing else.
	var coarse_seed := planned.noise.seed if planned.noise != null else 0
	var fine_seed := planned.fine.seed if planned.fine != null else 0
	bytes.encode_s32(48, coarse_seed)
	bytes.encode_float(52, planned.noise.frequency if planned.noise != null else 1.0)
	bytes.encode_s32(56, fine_seed)
	bytes.encode_float(60, planned.fine.frequency if planned.fine != null else 1.0)
	var octaves := planned.noise.fractal_octaves if planned.noise != null else 0
	var gain := planned.noise.fractal_gain if planned.noise != null else 0.0
	bytes.encode_s32(64, octaves)
	bytes.encode_float(68, gain)
	bytes.encode_float(72, planned.noise.fractal_lacunarity if planned.noise != null else 2.0)
	bytes.encode_float(76, SpacesimCloudField.fractal_bounding(octaves, gain))
	bytes.encode_s32(80, planned.stack.centres.size())
	bytes.encode_s32(84, 1 if planned.uniform else 0)
	bytes.encode_s32(88, 1 if planned.noise != null else 0)
	bytes.encode_s32(92, 1 if planned.fine != null else 0)
	return bytes
