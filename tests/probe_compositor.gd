extends SceneTree
## B3 feasibility probe — can a GDScript `CompositorEffect` with a compute shader run here?
##
##     xvfb-run -a godot-double-mono --path . --script res://tests/probe_compositor.gd
##
## ## What it is asking, and why it has to be asked
##
## Track B3 needs the **metre on the GPU**: a weighted reduction of the frame to one number, and the
## frame-wide multiply applied before the glow is built. Doing it on the CPU would mean a read-back every
## frame, which is a GPU sync — the classic metering stall — so the effect has to be a compute pass.
##
## **This project has never shipped a `.glsl` and has no `CompositorEffect` anywhere**, and headless
## Godot neither compiles shaders nor reports one that fails to compile (which is why
## `tests/shader_check.sh` exists). So every part of this is unknown until it runs:
##
##   1. does a GDScript `CompositorEffect`'s `_render_callback` get called at all?
##   2. is a `RenderingDevice` available from inside it?
##   3. is the frame's colour texture reachable **as a storage image** — i.e. can the pass write the
##      frame back? The engine only prepares a resolved colour texture when an effect declares
##      `access_resolved_color`, so that flag is part of the question.
##   4. and does a compute shader compiled **from source at run time** (no `.glsl` file, no import) work?
##
## ## How it answers
##
## The scene is one unshaded quad at a **known linear value (0.5)**, a LINEAR tonemap and identity
## exposure, so the pixel before the effect is `sRGB(0.5) = 0.735`. The effect then multiplies the colour
## texture by 0.5 in place. **If the pixel becomes `sRGB(0.25) = 0.537`, the whole chain works** — effect
## dispatched, storage image written, frame changed. Anything else is reported with what it did get:
## which callbacks fired, whether the RD and the render buffers were non-null, which texture accessor
## worked, and any compile error from the shader.
##
## **What it does not prove:** that the reduction can be one dispatch, that the weighting is affordable
## at 4K, or anything about the metre's arithmetic (that is B2, and it is already checked).

const VIEW_SIZE := 64
const SETTLE_FRAMES := 3
const QUAD_LEVEL := 0.5 ## the known linear value the quad is drawn at

## The compute shader, built from source in process. Deliberately the *shape* the metre needs — read the
## colour image, write it back — rather than the metre itself, because the question here is feasibility.
##
## **No `#[compute]` marker and no leading blank line.** That marker is Godot's *file* convention: the
## `RDShaderFile` loader strips it before glslang sees the source, and a string handed straight to
## `shader_compile_spirv_from_source` gets no such treatment — glslang then fails with
## *"0:2: '#': invalid directive"*. `#version` has to be the first thing in the string, and the stage is
## declared by `RDShaderSource.source_compute` rather than by a marker.
const COMPUTE_SOURCE := """#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float factor;
	float pad;
} params;
void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (pos.x >= int(params.size.x) || pos.y >= int(params.size.y)) {
		return;
	}
	vec4 c = imageLoad(color_image, pos);
	imageStore(color_image, pos, vec4(c.rgb * params.factor, c.a));
}
"""


## The effect. An inner class, so the probe is one file: `extends CompositorEffect` and the engine calls
## `_render_callback` through the script's method table like any other virtual.
class MultiplyEffect:
	extends CompositorEffect

	## Everything the probe wants to know afterwards, written here rather than printed, because a
	## `_render_callback` runs inside the render thread's frame and printing from it is not the place.
	var callbacks: Array[int] = []
	var rd_available := false
	var buffers_available := false
	var texture_accessor := "none"
	var texture_format := ""
	var texture_size := Vector2i.ZERO
	var compile_errors := ""
	var dispatch_errors := ""
	var dispatches := 0
	## **This must be set by the caller.** It defaults to 1.0, and the first version of this probe left it
	## there — so the pass ran, wrote the frame, and changed nothing, which reads exactly like "the write
	## does not reach the frame". A probe that multiplies by one measures the instrument, not the engine.
	var factor := 1.0

	var _shader: RID
	var _pipeline: RID

	func _init() -> void:
		effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
		# **The flag that asks the engine to prepare a resolved colour texture.** Without it the
		# colour layer may not be created with storage usage, and a compute pass has nothing to write to.
		access_resolved_color = true
		_build()

	func _build() -> void:
		var rd := RenderingServer.get_rendering_device()
		if rd == null:
			compile_errors = "no RenderingDevice"
			return
		var source := RDShaderSource.new()
		source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		source.source_compute = COMPUTE_SOURCE
		var spirv := rd.shader_compile_spirv_from_source(source)
		# `get_stage_compile_error` returns the MESSAGE (a String), not an Error — an empty one means it
		# compiled. Checked against the class reference after getting this wrong once.
		var err := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
		if not err.is_empty():
			compile_errors = err
			return
		_shader = rd.shader_create_from_spirv(spirv)
		if not _shader.is_valid():
			compile_errors = "shader_create_from_spirv gave an invalid RID"
			return
		_pipeline = rd.compute_pipeline_create(_shader)

	func _render_callback(callback_type: int, render_data: RenderData) -> void:
		callbacks.append(callback_type)
		# **Everything below is measured before any early return.** The first version of this probe read the
		# render buffers *after* bailing out on an invalid pipeline, so "buffers available: false" was the
		# un-set default rather than a measurement — a probe reporting its own initialisation as a finding.
		var rd := RenderingServer.get_rendering_device()
		rd_available = rd != null
		var buffers := render_data.get_render_scene_buffers()
		buffers_available = buffers != null
		if rd == null or not _pipeline.is_valid() or buffers == null:
			return

		# Either accessor may be the one that works; record which, because that is a fact B3 needs.
		# **Annotated**, because the accessors return `RID` untyped as far as the parser is concerned.
		var color: RID
		var via_texture: RID = buffers.get_color_texture()
		if via_texture.is_valid():
			color = via_texture
			texture_accessor = "get_color_texture()"
		else:
			var via_layer: RID = buffers.get_color_layer(0)
			if via_layer.is_valid():
				color = via_layer
				texture_accessor = "get_color_layer(0)"
		if not color.is_valid():
			texture_accessor = "neither accessor gave a valid RID"
			return

		texture_format = str(rd.texture_get_format(color).format)
		texture_size = buffers.get_internal_size()

		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		uniform.binding = 0
		uniform.add_id(color)
		var uniform_set := rd.uniform_set_create([uniform], _shader, 0)
		if not uniform_set.is_valid():
			dispatch_errors = "uniform_set_create failed"
			return

		var size := Vector2(texture_size)
		var params := PackedFloat32Array([size.x, size.y, factor, 0.0]).to_byte_array()
		# **Every compute-list call takes the list handle first** — `compute_list_begin()` returns an
		# `int`, not a state the device remembers.
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, _pipeline)
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		rd.compute_list_set_push_constant(list, params, params.size())
		rd.compute_list_dispatch(list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
		rd.compute_list_end()
		dispatches += 1


var _effect: MultiplyEffect
var _quad: MeshInstance3D
var _camera: Camera3D
var _phase := 0
var _frames := 0
var _before := -1.0
var _after := -1.0


func _initialize() -> void:
	get_root().size = Vector2i(VIEW_SIZE, VIEW_SIZE)

	var root := Node3D.new()
	get_root().add_child(root)

	var mesh := QuadMesh.new()
	mesh.size = Vector2(4.0, 4.0)
	_quad = MeshInstance3D.new()
	_quad.mesh = mesh
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(_quad)

	# Unshaded through a shader rather than `albedo_color`, so the value is **linear and known**: an
	# `albedo_color` is a `source_color` property and gets sRGB-decoded on the way in, which round-trips
	# and hides what is being measured (that cost the ambient probe a revision).
	var surface := Shader.new()
	surface.code = (
		"shader_type spatial;\nrender_mode unshaded;\n"
		+ "void fragment() {\n\tALBEDO = vec3(%f);\n}\n" % QUAD_LEVEL
	)
	var material := ShaderMaterial.new()
	material.shader = surface
	_quad.material_override = material

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 1.0
	_camera.position = Vector3(0.0, 0.0, 2.0)
	_camera.current = true
	root.add_child(_camera)

	# Identity exposure, the B1 finding: `attributes = null` is NOT identity — it skips the factor that
	# implements the lux convention and lands ~95x out. The attributes must be present.
	var attributes := CameraAttributesPhysical.new()
	attributes.auto_exposure_enabled = false
	attributes.exposure_multiplier = 1.0
	_camera.attributes = attributes

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.tonemap_white = 1.0
	environment.glow_enabled = false
	var world := WorldEnvironment.new()
	world.environment = environment
	root.add_child(world)

	_effect = MultiplyEffect.new()
	_effect.factor = 0.5


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < SETTLE_FRAMES:
		return false
	match _phase:
		0:
			# The frame as it is, before any effect exists — the control.
			_before = _read()
			_camera.compositor = _attach()
			_phase = 1
			_frames = 0
		1:
			_after = _read()
			_report()
			return true
	return false


## A `Compositor` holding the effect. Built here rather than in `_initialize` so that the "before" frame
## is genuinely rendered without it. **The array must be typed** — `compositor_effects` is
## `CompositorEffect[]`, and an untyped literal is a runtime error.
func _attach() -> Compositor:
	var effects: Array[CompositorEffect] = [_effect]
	var compositor := Compositor.new()
	compositor.compositor_effects = effects
	return compositor


func _read() -> float:
	var image := get_root().get_texture().get_image()
	var size := image.get_size()
	return image.get_pixel(size.x / 2, size.y / 2).r


func _report() -> void:
	# The expected pixel for a known linear value, through the sRGB encode the read-back does.
	print("COMPOSITOR PROBE — is a GDScript CompositorEffect with a compute pass viable here?")
	print("COMPOSITOR PROBE: quad drawn at a known LINEAR value   %.3f" % QUAD_LEVEL)
	print("COMPOSITOR PROBE: expected pixel before the effect     %.5f" % _srgb(QUAD_LEVEL))
	print("COMPOSITOR PROBE: expected pixel after x0.5            %.5f" % _srgb(QUAD_LEVEL * 0.5))
	print("COMPOSITOR PROBE:")
	print("COMPOSITOR PROBE: pixel BEFORE the effect              %.5f" % _before)
	print("COMPOSITOR PROBE: pixel AFTER the effect               %.5f" % _after)
	print("COMPOSITOR PROBE:")
	print("COMPOSITOR PROBE: shader compiled at run time          %s"
		% ("yes" if _effect.compile_errors.is_empty() else "NO — " + _effect.compile_errors))
	print("COMPOSITOR PROBE: callbacks fired                      %d  %s"
		% [_effect.callbacks.size(), str(_effect.callbacks)])
	print("COMPOSITOR PROBE: callback type asked for              %d (POST_TRANSPARENT)"
		% CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT)
	print("COMPOSITOR PROBE: RenderingDevice available            %s" % _effect.rd_available)
	print("COMPOSITOR PROBE: render buffers available             %s" % _effect.buffers_available)
	print("COMPOSITOR PROBE: colour texture accessor              %s" % _effect.texture_accessor)
	print("COMPOSITOR PROBE: colour texture format                %s" % _effect.texture_format)
	print("COMPOSITOR PROBE: internal size                        %s" % str(_effect.texture_size))
	print("COMPOSITOR PROBE: dispatches done                      %d" % _effect.dispatches)
	print("COMPOSITOR PROBE: dispatch errors                      %s"
		% ("none" if _effect.dispatch_errors.is_empty() else _effect.dispatch_errors))
	print("COMPOSITOR PROBE:")
	if _effect.dispatches > 0 and absf(_after - _srgb(QUAD_LEVEL * 0.5)) < 0.02:
		print("COMPOSITOR PROBE: **VERDICT: the whole chain works.** The effect dispatched, wrote the")
		print("COMPOSITOR PROBE: frame's colour image in place, and the pixel halved. B3 can be built on it.")
	elif _effect.dispatches > 0:
		print("COMPOSITOR PROBE: the effect RAN but the pixel did not halve — so the write did not reach")
		print("COMPOSITOR PROBE: the frame. That is the state to investigate: the texture may need to be a")
		print("COMPOSITOR PROBE: shared view, or the effect may need to write a texture of its own.")
	else:
		print("COMPOSITOR PROBE: **the effect never dispatched.** Read the fields above: no callback means")
		print("COMPOSITOR PROBE: the host is wrong, no RD means this build cannot, and a compile error is")
		print("COMPOSITOR PROBE: named. The fallback is `Environment.tonemap_exposure` driven from a metre")
		print("COMPOSITOR PROBE: read back on the CPU, which costs a sync per frame.")


func _srgb(value: float) -> float:
	if value <= 0.0:
		return 0.0
	if value <= 0.0031308:
		return value * 12.92
	return 1.055 * pow(value, 1.0 / 2.4) - 0.055
