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

## The GLSL, as **text**: prepended with `#version 450` and compiled from a source string, which is why it
## carries no version, no layout and no entry point of its own.
const FIELD_PATH := "res://addons/spacesim/system/model/surface_field.gdshaderinc"
## The noise, in front of it, because a source string gets no preprocessor. One home for two consumers.
const NOISE_PATH := "res://addons/spacesim/system/model/noise.gdshaderinc"

## The kernel: the storage image, the plan's numbers, and the row/column → direction mapping that the shader
## inverts. **No `#[compute]` marker** — that is Godot's *file* convention, and a source string handed to
## `shader_compile_spirv_from_source()` gets no such treatment, so `#version` has to be the first thing.
const KERNEL := """
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r16f, set = 0, binding = 0) uniform image2D out_map;

layout(push_constant, std430) uniform Params {
	ivec2 size;
	int seed;
	float continent_frequency;
	int continent_octaves;
	float ridge_frequency;
	int ridge_octaves;
	float warp_frequency;
	int warp_octaves;
	float warp_strength;
	float ridge_strength;
	float continent_share;
	float plate_bias_share;
	float belt_width;
	float plate_phase;
	float gain;
	float lacunarity;
	float continent_bounding;
	float warp_bounding;
} params;

const float SURFACE_PI = 3.141592653589793;
const float SURFACE_TAU = 6.283185307179586;

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (pos.x >= params.size.x || pos.y >= params.size.y) {
		return;
	}
	// The map's own `(u, v)`: `u` around the equator, `v` pole to pole, north at the top row. **Pixel
	// centres, half a texel in**, so the seam and the poles land where the CPU path puts them and the
	// shader's inverse is exact.
	float u = (float(pos.x) + 0.5) / float(params.size.x);
	float v = (float(pos.y) + 0.5) / float(params.size.y);
	float latitude = SURFACE_PI * 0.5 - v * SURFACE_PI;
	float longitude = (u - 0.5) * SURFACE_TAU;
	float cos_latitude = cos(latitude);
	// Unit by construction: every direction is on the sphere the field is a function of.
	vec3 direction = vec3(
		cos_latitude * cos(longitude), sin(latitude), cos_latitude * sin(longitude));

	SurfacePlan plan;
	plan.seed = params.seed;
	plan.continent_frequency = params.continent_frequency;
	plan.continent_octaves = params.continent_octaves;
	plan.ridge_frequency = params.ridge_frequency;
	plan.ridge_octaves = params.ridge_octaves;
	plan.warp_frequency = params.warp_frequency;
	plan.warp_octaves = params.warp_octaves;
	plan.warp_strength = params.warp_strength;
	plan.ridge_strength = params.ridge_strength;
	plan.continent_share = params.continent_share;
	plan.plate_bias_share = params.plate_bias_share;
	plan.belt_width = params.belt_width;
	plan.plate_phase = params.plate_phase;
	plan.gain = params.gain;
	plan.lacunarity = params.lacunarity;
	plan.continent_bounding = params.continent_bounding;
	plan.warp_bounding = params.warp_bounding;

	imageStore(out_map, pos, vec4(surface_height(direction, plan), 0.0, 0.0, 1.0));
}
"""

## The push-constant block's size in bytes: `ivec2` plus seventeen 4-byte fields, which is 76 and **must be
## supplied exactly** — the driver rejects both more and less (*"requires (76) bytes of push constant data,
## supplied: (80)"*), unlike a uniform block where padding is the caller's to choose. Layout is in
## [constant KERNEL]; the offsets are written out in [method _params].
const PARAMS_SIZE := 76

var _device: RenderingDevice
var _shader: RID
var _pipeline: RID
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
	return true


## Release the device and everything on it.
##
## **The device is freed, not merely dropped.** A local `RenderingDevice` left alive to be destroyed at
## process teardown **segfaults on exit** (measured 2026-10-17 on the cloud port: exit 139 with no output,
## from a probe that had done its work and printed the result). It is an `Object`, so `free()` works.
func close() -> void:
	if _device != null and _pipeline.is_valid():
		_device.free_rid(_pipeline)
	if _device != null and _shader.is_valid():
		_device.free_rid(_shader)
	_pipeline = RID()
	_shader = RID()
	if _device != null:
		_device.free()
		_device = null
	_tried = false


## Why [method open] did not work, or an empty string.
func error() -> String:
	return _error


## **A body's whole-surface height map, from the GPU**: `FORMAT_RH`, equirectangular, north at the top row,
## values about ±1 (the field's own, **not** metres and **not** sea-levelled — sea level is a percentile of
## the distribution, measured from this).
##
## Returns `null` with [method error] set when there is no device to run on.
func bake(plan_data: SpacesimSurfaceField.Plan, width: int, height: int) -> Image:
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

	var image_uniform := RDUniform.new()
	image_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image_uniform.binding = 0
	image_uniform.add_id(texture)
	var uniform_set := _device.uniform_set_create([image_uniform], _shader, 0)
	if not uniform_set.is_valid():
		_error = "uniform_set_create() gave an invalid RID"
		_device.free_rid(texture)
		return null

	var params := _params(w, h, plan_data)
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

	if data.size() != w * h * 2:
		_error = "read back %d bytes for a %dx%d half-float map" % [data.size(), w, h]
		return null
	var image := Image.create_from_data(w, h, false, Image.FORMAT_RH, data)
	image.set_meta("spacesim_bake", "gpu")
	return image


## The noise, then the field, then the kernel, under one `#version`. Assembled rather than `#include`d
## because a source string gets no preprocessor help.
func _source() -> String:
	return (
		"#version 450\n"
		+ FileAccess.get_file_as_string(NOISE_PATH)
		+ FileAccess.get_file_as_string(FIELD_PATH)
		+ KERNEL
	)


## The push-constant block, written field by field so the layout is readable beside the shader's.
##
## **Every number comes off the plan**, including the three FBM normalisers — a constant typed into the GLSL
## would be a second copy of a number the plan already knows, and it would drift away from the one the
## GDScript side uses.
func _params(w: int, h: int, plan_data: SpacesimSurfaceField.Plan) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(PARAMS_SIZE)
	bytes.encode_s32(0, w)
	bytes.encode_s32(4, h)
	bytes.encode_s32(8, plan_data.seed)
	bytes.encode_float(12, plan_data.continent_frequency)
	bytes.encode_s32(16, plan_data.continent_octaves)
	bytes.encode_float(20, plan_data.ridge_frequency)
	bytes.encode_s32(24, plan_data.ridge_octaves)
	bytes.encode_float(28, plan_data.warp_frequency)
	bytes.encode_s32(32, plan_data.warp_octaves)
	bytes.encode_float(36, plan_data.warp_strength)
	bytes.encode_float(40, plan_data.ridge_strength)
	bytes.encode_float(44, plan_data.continent_share)
	bytes.encode_float(48, plan_data.plate_bias_share)
	bytes.encode_float(52, plan_data.belt_width)
	bytes.encode_float(56, plan_data.plate_phase)
	bytes.encode_float(60, plan_data.gain)
	bytes.encode_float(64, plan_data.lacunarity)
	bytes.encode_float(68, plan_data.continent_bounding)
	bytes.encode_float(72, plan_data.warp_bounding)
	return bytes
