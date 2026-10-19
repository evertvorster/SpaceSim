class_name SpacesimExposurePass
extends CompositorEffect
## The **frame-wide exposure**: metre, then multiply, in one compute pass. Track B3 of the lighting plan.
##
## ## What it replaces, and why a pass rather than a property
##
## Godot bakes the exposure into each *path* — `light_data.energy *= exposure_normalization_factor`
## (`light_storage.cpp:765`) — so the ambient receives none at all (measured: exposure ×1, ×1000 and
## ×80000 give byte-identical pixels), the point-of-light splat needs a hand-applied multiply, and the
## star's disc is a documented exception. **This pass applies one number to the finished frame instead**,
## so every path in it is scaled by the same thing by construction.
##
## **Why not `Environment.tonemap_exposure`, which is already a frame-wide multiply?** Because the metre
## has to run on the GPU and the multiply has to follow it *without a CPU round trip* — a read-back every
## frame is a GPU sync, the classic metering stall. `CompositorEffect` runs **"before any built-in
## post-processing effects"** (its own class reference), so both live in one place, and Godot's glow then
## reads an already-exposed frame — which matters, because the glow applies the exposure itself
## (`copy.glsl:195`) and the two would otherwise double-count. **So `Environment.tonemap_exposure` must
## stay at 1.0 while this pass is attached.**
##
## ## The three dispatches
##
## | | |
## |---|---|
## | **sample** | `SAMPLES_X × SAMPLES_Y` threads, each averaging its own block of the frame — **each texel capped at `CAP`**, then the block mean weighted by `SpacesimExposureMeter`'s radial profile. Writes `(weighted, weight)` per sample. |
## | **finalize** | one thread: the weighted mean, then `target/mean` clamped to the exposure's own window, then the temporal lerp against the previous frame's value. |
## | **apply** | the frame × that one number. |
##
## **The reduction is coarse on purpose.** Every texel would be ~2M reads; a 32×18 grid over 1080p is
## 576 samples of ~60×60 texels, about 37k reads, and the profile is smooth enough at that resolution.
## **Capping each texel before averaging** is what keeps the cap meaning the same thing it means on the
## CPU: a small source cannot own the average, because its own pixels are already bounded at white.
##
## ## What it does not do
##
## It does not decide *where* the exposure comes from beyond the metre (the plan's §6a), and it does not
## touch the glow or the tonemap — those stay Godot's. `SIGMA`, `CAP` and `TARGET_AVERAGE` come from
## `SpacesimExposureMeter`; the window and the rate come from `SpacesimExposure`. **One home each.**

## The reduction's grid. 32×18 = 576 samples, which at 1080p is a block of about 60×60 texels each.
const SAMPLES_X := 32
const SAMPLES_Y := 18
const SAMPLE_COUNT := SAMPLES_X * SAMPLES_Y

## Local size of the final multiply's dispatch.
const BLOCK := 8

## Seconds since the last frame, **set by the game each frame**. There is no delta inside
## `_render_callback`, and reaching for a wall clock there would read the render thread's timing rather
## than the frame's, so the main thread hands it over — the same delta `_update_view` already works in.
var frame_delta := 1.0 / 60.0

## The ceiling on the metre's gain — the top of the window it clamps to. `MAX_MULTIPLIER` (32 stops
## above the floor) unless the game lowers it from `exposure.range_stops`, which is how far the gain
## may go. It matters most on a frame of nothing but stars: with no mean luminance to answer, the
## metre asks for the ceiling.
var max_multiplier := SpacesimExposure.MAX_MULTIPLIER

## The last metre value the *CPU* knows, which is only ever a report: it is written from the render
## thread, so it may lag or be read mid-write. The authoritative value lives on the GPU, in `_state`.
var last_multiplier := 0.0
## The mean luminance and the target that produced it, alongside the multiplier — read back with
## `read_meter()`. **A diagnostic, and a readback stalls the pipeline**, so nothing on the frame path may
## call it: it exists so "the exposure jumped" can be answered with numbers rather than with a theory.
var last_mean := 0.0
var last_target := 0.0

## How often the metre is read back, in frames. **A readback waits for the frame it reads**, so this is a
## deliberate cost paid by an instrument, not something the pass needs; it exists to answer why the
## exposure jumped on a landing, and it is counted in frames rather than seconds because frames are what
## the stall is measured against.
const METER_EVERY := 120

## Built in the first callback rather than in `_init`: a headless run has no `RenderingDevice`, and a
## construction that assumed one would fail there for no reason.
var _built := false
var _status := "not built"
var _frames := 0

var _shader_sample: RID
var _shader_finalize: RID
var _shader_apply: RID
var _pipeline_sample: RID
var _pipeline_finalize: RID
var _pipeline_apply: RID
var _partials: RID
var _state: RID


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	# The pass reads the frame and writes it back, so the resolved colour has to be there for it.
	access_resolved_color = true


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _built:
		var rd := RenderingServer.get_rendering_device()
		if rd != null:
			for rid in [_pipeline_sample, _pipeline_finalize, _pipeline_apply, _shader_sample,
					_shader_finalize, _shader_apply, _partials, _state]:
				if (rid as RID).is_valid():
					rd.free_rid(rid)


## **The metre's own numbers, read back from the GPU — and the read has to happen HERE.**
##
## `RenderingServer.get_rendering_device()` hands back the device the **render thread** owns, and its RID
## allocator is not thread safe. Reading it from `_process` — which is exactly what a HUD readout invites —
## races that allocator: this was tried, and four and a half minutes of flying produced thousands of
## `Element limit reached` / `Failed to create uniform set for batch` errors as the allocator filled up,
## ending in leaked RenderingDevice resources at exit. **The instrument wrecked the thing it measured.**
##
## So the read lives in the callback, which is the render thread, and it is rate limited because
## `buffer_get_data` waits for the frame it is reading — a stall, and a stall in a pass that exists to keep
## the frame's exposure honest is worth counting in frames rather than in seconds.
func _read_meter(rd: RenderingDevice) -> void:
	if not (_state as RID).is_valid():
		return
	var floats := rd.buffer_get_data(_state).to_float32_array()
	var multiplier := floats[0] if floats.size() > 0 else 0.0
	var mean := floats[1] if floats.size() > 1 else 0.0
	var target := floats[2] if floats.size() > 2 else 0.0
	# A jump of more than half in one read is either the scene changing or the `mean == 0` branch asking
	# for the ceiling, and `mean` and `target` say which.
	if last_multiplier > 0.0 and (multiplier > last_multiplier * 1.5 or multiplier < last_multiplier / 1.5):
		print(
			"EXPOSURE: multiplier %.3f -> %.3f  mean %.6f  target %.3f"
			% [last_multiplier, multiplier, mean, target]
		)
	last_multiplier = multiplier
	last_mean = mean
	last_target = target


## What happened, for a probe or a test to read. The GPU's own value is authoritative; this is the
## instrument.
func status() -> String:
	return _status if not _built else "%s, %d frames" % [_status, _frames]


# --- the shaders ------------------------------------------------------------------------------------

## One block of the frame each: cap every texel, average the block, weight it by the radial profile.
##
## **The luminance is Rec.709 in linear light** — the same expression as
## `SpacesimExposureMeter.luminance`, which is the source of truth and is pinned by a test. Godot's own
## reduction uses `max(r, g, b)` instead, which over-weights a saturated colour.
##
## **`sample` is a reserved word in GLSL** (a qualifier, in Vulkan GLSL) — naming the invocation's coordinate
## `sample` is a *syntax error*, reported as `unexpected SAMPLE`, and it cost a run to find. The loop
## variable is `cell` for that reason, and nothing here is called `sample`, `filter`, `input` or `output`.
const SAMPLE_SOURCE := """#version 450
layout(local_size_x = 32, local_size_y = 18, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform readonly image2D color_image;
layout(std430, set = 0, binding = 1) buffer Partials {
	vec2 data[];
} partials;
layout(push_constant, std430) uniform Params {
	vec2 size;
	vec2 grid;
	float cap;
	float sigma;
} params;
void main() {
	ivec2 cell = ivec2(gl_GlobalInvocationID.xy);
	// The block of the frame this cell covers, in texels. At least one, so a frame smaller than the
	// grid still works.
	ivec2 lo = (cell * ivec2(params.size)) / ivec2(params.grid);
	ivec2 hi = max(((cell + ivec2(1)) * ivec2(params.size)) / ivec2(params.grid), lo + ivec2(1));
	float sum = 0.0;
	float count = 0.0;
	for (int y = lo.y; y < hi.y; ++y) {
		for (int x = lo.x; x < hi.x; ++x) {
			if (x >= int(params.size.x) || y >= int(params.size.y)) {
				continue;
			}
			float l = dot(imageLoad(color_image, ivec2(x, y)).rgb, vec3(0.2126, 0.7152, 0.0722));
			sum += min(l, params.cap);
			count += 1.0;
		}
	}
	float mean = count > 0.0 ? sum / count : 0.0;
	// The radial weight, in units of the frame's half-diagonal — the same profile
	// `SpacesimExposureMeter.weight` applies on the CPU.
	vec2 uv = (vec2(cell) + vec2(0.5)) / vec2(params.grid);
	vec2 centred = uv * 2.0 - vec2(1.0);
	float r = length(centred) / sqrt(2.0);
	float weight = exp(-(r * r) / (params.sigma * params.sigma));
	partials.data[cell.y * int(params.grid.x) + cell.x] = vec2(mean * weight, weight);
}
"""

## One thread: the weighted mean, the target, the window, and the temporal lerp.
const FINALIZE_SOURCE := """#version 450
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
layout(std430, set = 0, binding = 0) buffer Partials {
	vec2 data[];
} partials;
layout(std430, set = 0, binding = 1) buffer State {
	vec4 value;
} state;
layout(push_constant, std430) uniform Params {
	float count;
	float target;
	float min_multiplier;
	float max_multiplier;
	float rate;
	float delta;
	float pad0;
	float pad1;
} params;
void main() {
	float weighted = 0.0;
	float weight = 0.0;
	for (int i = 0; i < int(params.count); ++i) {
		weighted += partials.data[i].x;
		weight += partials.data[i].y;
	}
	// A frame with nothing in it pins at the ceiling rather than dividing by zero — the lower bound
	// Evert asked for, and the same answer `SpacesimExposure.target_multiplier` gives for no light.
	float mean = weight > 0.0 ? weighted / weight : 0.0;
	float target = mean > 0.0
		? clamp(params.target / mean, params.min_multiplier, params.max_multiplier)
		: params.max_multiplier;
	float previous = state.value.x;
	// `previous <= 0` is the first frame: snap rather than easing up from nothing.
	float t = clamp(params.rate * params.delta, 0.0, 1.0);
	state.value.x = previous <= 0.0 ? target : mix(previous, target, t);
	// **`y` is the mean the target was computed from**, and `z` the target itself: the multiplier alone
	// cannot say whether a jump came from the scene changing or from the "no light at all" branch asking
	// for the ceiling. Instrument only — nothing reads them on the GPU.
	state.value.y = mean;
	state.value.z = target;
}
"""

## The frame times that one number.
const APPLY_SOURCE := """#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(std430, set = 0, binding = 1) buffer State {
	vec4 value;
} state;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float pad0;
	float pad1;
} params;
void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (pos.x >= int(params.size.x) || pos.y >= int(params.size.y)) {
		return;
	}
	vec4 c = imageLoad(color_image, pos);
	// **Alpha is left alone**: it is the frame's coverage, not its light, and scaling it would change
	// how things composite rather than how they look.
	imageStore(color_image, pos, vec4(c.rgb * state.value.x, c.a));
}
"""


func _build(rd: RenderingDevice) -> void:
	_shader_sample = _compile(rd, SAMPLE_SOURCE)
	_shader_finalize = _compile(rd, FINALIZE_SOURCE)
	_shader_apply = _compile(rd, APPLY_SOURCE)
	if not _shader_sample.is_valid() or not _shader_finalize.is_valid() or not _shader_apply.is_valid():
		_status = "a shader failed to compile — see the errors above"
		return
	_pipeline_sample = rd.compute_pipeline_create(_shader_sample)
	_pipeline_finalize = rd.compute_pipeline_create(_shader_finalize)
	_pipeline_apply = rd.compute_pipeline_create(_shader_apply)
	# 2 floats per sample; 4 for the state (a `vec4`, so its alignment is never in question).
	_partials = rd.storage_buffer_create(SAMPLE_COUNT * 8)
	# **Seeded at zero, which the finalize shader reads as "no previous frame" and snaps on.** That is
	# the same choice `SpacesimExposure.snap_to` makes at startup: the first frame is already right
	# rather than easing into right.
	_state = rd.storage_buffer_create(16, PackedFloat32Array([0.0, 0.0, 0.0, 0.0]).to_byte_array())
	_built = true
	_status = "ready"


## GLSL compiled from a **source string**, so no `.glsl` file and no import step is involved.
##
## **No `#[compute]` marker.** That is Godot's file convention — `RDShaderFile` strips it before glslang
## sees the source — and a string handed straight to the compiler gets no such treatment: glslang then
## reports *"0:2: '#': invalid directive"* and `#version` has to be the first line.
func _compile(rd: RenderingDevice, source: String) -> RID:
	var shader_source := RDShaderSource.new()
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	shader_source.source_compute = source
	var spirv := rd.shader_compile_spirv_from_source(shader_source)
	# `get_stage_compile_error` returns the **message**, not an `Error`: empty means it compiled.
	var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not error.is_empty():
		push_error("SpacesimExposurePass: compute shader did not compile — %s" % error)
		return RID()
	return rd.shader_create_from_spirv(spirv)


# --- the pass ---------------------------------------------------------------------------------------

func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	var rd := RenderingServer.get_rendering_device()
	var buffers := render_data.get_render_scene_buffers()
	if rd == null or buffers == null:
		_status = "no RenderingDevice or no render buffers"
		return
	if not _built:
		_build(rd)
	if not _built:
		return

	var color: RID = buffers.get_color_texture()
	if not color.is_valid():
		_status = "no colour texture"
		return
	var size := Vector2(buffers.get_internal_size())
	if size.x < 1.0 or size.y < 1.0:
		return

	# The three uniform sets are rebuilt each frame rather than cached: the colour texture's RID can
	# change with the render target, and a stale set is a wrong frame rather than an error. **Rebuilt, and
	# freed at the end of this callback** — see the note there; forgetting the free is a RID leak per frame. The second
	# argument says which bindings are **storage buffers** rather than images — the colour image is an
	# image, the partials and the state are buffers, and getting that wrong is a validation error naming
	# the binding and the set.
	var sample_set := _uniform_set(rd, _shader_sample, [color, _partials], [false, true])
	var finalize_set := _uniform_set(rd, _shader_finalize, [_partials, _state], [true, true])
	var apply_set := _uniform_set(rd, _shader_apply, [color, _state], [false, true])
	if not sample_set.is_valid() or not finalize_set.is_valid() or not apply_set.is_valid():
		_status = "a uniform set could not be built"
		return

	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline_sample)
	rd.compute_list_bind_uniform_set(list, sample_set, 0)
	rd.compute_list_set_push_constant(list, PackedFloat32Array([
		size.x, size.y, float(SAMPLES_X), float(SAMPLES_Y),
		SpacesimExposureMeter.CAP, SpacesimExposureMeter.SIGMA,
	]).to_byte_array(), 24)
	# One workgroup per cell: the shader's local size *is* the grid, so the dispatch is one group wide and
	# tall and each invocation owns exactly one cell of the frame.
	rd.compute_list_dispatch(list, SAMPLES_X / 32, SAMPLES_Y / 18, 1)
	# **A barrier between the dispatches**, because the second reads what the first wrote and Godot does
	# not insert one inside a compute list.
	rd.compute_list_add_barrier(list)
	rd.compute_list_bind_compute_pipeline(list, _pipeline_finalize)
	rd.compute_list_bind_uniform_set(list, finalize_set, 0)
	rd.compute_list_set_push_constant(list, PackedFloat32Array([
		float(SAMPLE_COUNT), SpacesimExposureMeter.TARGET_AVERAGE,
		SpacesimExposure.MIN_MULTIPLIER, max_multiplier,
		SpacesimExposure.ADAPTATION_RATE, frame_delta, 0.0, 0.0,
	]).to_byte_array(), 32)
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_add_barrier(list)
	rd.compute_list_bind_compute_pipeline(list, _pipeline_apply)
	rd.compute_list_bind_uniform_set(list, apply_set, 0)
	rd.compute_list_set_push_constant(list, PackedFloat32Array([
		size.x, size.y, 0.0, 0.0,
	]).to_byte_array(), 16)
	rd.compute_list_dispatch(
		list, ceili(size.x / float(BLOCK)), ceili(size.y / float(BLOCK)), 1
	)
	rd.compute_list_end()

	# **Free the three sets. They are the pass's only per-frame allocation, and not freeing them was a leak
	# of three RIDs a frame.** At 340 fps that is a thousand a second, and the engine's `UniformSet` allocator
	# runs out in about a minute — after which *"Element limit reached"* appears at `_allocate_rid`, the **2D**
	# renderer fails with *"Failed to create uniform set for batch"*, and the whole frame stops shading.
	# Evert flew four and a half minutes into exactly that, and it reads as a rendering crash rather than as a
	# leak, because the damage lands in a subsystem that has nothing to do with this pass.
	#
	# **Safe while the compute list is still in flight**: `RenderingDevice::free_rid` pushes the resource to
	# be disposed of when this frame index is next processed (*"means, it's safe to do it"*, RD source), which
	# is the same guarantee `SpacesimCloudGpu` relies on when it frees a set straight after `sync()`.
	rd.free_rid(sample_set)
	rd.free_rid(finalize_set)
	rd.free_rid(apply_set)

	_frames += 1
	_status = "ready"
	# The metre's own numbers, read on the render thread and rate limited — see `_read_meter`.
	if _frames % METER_EVERY == 0:
		_read_meter(rd)


## A uniform set for one shader. `storage[i]` says whether entry `i` is a storage buffer rather than an
## image, since `RDUniform` needs the type up front and the two cannot be told apart from the RID.
func _uniform_set(rd: RenderingDevice, shader: RID, resources: Array, storage: Array) -> RID:
	var uniforms: Array[RDUniform] = []
	for i in resources.size():
		var uniform := RDUniform.new()
		uniform.uniform_type = (
			RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER if storage[i]
			else RenderingDevice.UNIFORM_TYPE_IMAGE
		)
		uniform.binding = i
		uniform.add_id(resources[i])
		uniforms.append(uniform)
	return rd.uniform_set_create(uniforms, shader, 0)
