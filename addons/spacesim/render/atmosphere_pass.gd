class_name SpacesimAtmospherePass
extends CompositorEffect
## **The atmosphere, as ONE volumetric march over the whole frame.**
##
## Evert, 2026-10-18: *"the atmosphere should be visible from outer space, so when a planet fills the
## screen, we'll be marching the entire thing with the cloud layer in it."*
##
## ## Why a pass and not a shell
##
## The shell that drew the air until now could never shade the air in front of the planet's disk, because
## the geometry that would carry those pixels is *behind* the planet and loses the depth test — its own
## header says so. A pass owns every pixel, so the air is shaded wherever the ray passes through it: over
## the disk from space, around the limb, and from inside as the sky.
##
## **The clouds are out of this file as of 2026-10-18**, and deliberately: every version of them written
## here was wrong, and they are rebuilt from a clean slate as a volume of their own. Their reason for living
## in a volumetric pass still stands — a cloud drawn as a *surface* is lit from one side only, so from below
## it is a black lid, and passing through it steps the frame's luminance hard enough to swing the exposure —
## which is why the rebuild is a volume too. **Measured at this baseline: 340 fps in flight**; the deck in
## the march took it to 90, and that is the cost the rebuild has to earn back.
##
## ## The composite, and what it replaces
##
##     out = colour * transmittance + in_scatter * sun_intensity
##
## which is the same expression the surface shader was approximating on its own, per material, with the
## air's own numbers. **When this pass is on, those materials must not apply air of their own** —
## one integral, one place.
##
## ## The rules this file has to obey, all of them learned in this project
##
## - It runs at `POST_TRANSPARENT` and **before** the exposure pass, so the meter measures the final frame.
## - The ground is the **analytic** planet hit, not the depth buffer: exact for the body's own surface, and
##   the occluders it misses are metres from the camera where the air contributes ~3e-4 of the sky.
## - The colour texture is a storage image written **in place**: one dispatch, no copy, no read-back.
## - The shader is compiled from a **source string**, so `#version` is the first line and there is no
##   `#[compute]` marker — that is Godot's file convention and glslang rejects it in a string.
## - Everything is **view space**: GLSL floats have ~7 digits, so a world coordinate of 1.5e11 m cannot be
##   subtracted here. GDScript computes the offsets in double and hands over small numbers.
## - No `sample`, `filter`, `input` or `output` as identifiers: `sample` is a reserved word in Vulkan GLSL.
##
## ## Cost, and the rejection that bounds it
##
## A shell costs only where the body's disc is; this costs the frame it is told to cover. So the first
## thing the shader does is test the ray against the atmosphere's sphere and **hand the pixel back
## untouched** when it misses. Empty space costs one dot product and a sqrt.

## **The step budget is the SOURCE's, not this file's.** `I_STEPS = 16` and `J_STEPS = 8` are declared in
## `SOURCE` below, and two GDScript constants claiming the same thing were dead the moment the shader took them
## over — editing them changed nothing in the picture, which is worse than having no constant at all. Deleted.
## They become a runtime value when the cloud volume returns, and then there is one place for them.

const BLOCK := 8

var _built := false
var _status := "not built"
var _frames := 0

var _shader: RID
var _pipeline: RID
var _params: RID

## The per-frame numbers, in the order the shader's `Params` block declares them. Written as one buffer
## update rather than as push constants, because a push-constant block is only 128 bytes.
##
##    0..3   eye_offset          4..7   sun_direction       8..11  rayleigh
##   12..15  absorption          16..19 mie                20..23  frame (size, tan)
##   24..27  radii (planet, top) — zw free for the cloud volume
var _values := PackedFloat32Array()
const PARAM_FLOATS := 28


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	# The pass reads the frame and writes it back, so the resolved colour has to be there for it.
	access_resolved_color = true
	_values.resize(PARAM_FLOATS)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _built:
		var rd := RenderingServer.get_rendering_device()
		if rd != null:
			for rid in [_pipeline, _shader, _params]:
				if (rid as RID).is_valid():
					rd.free_rid(rid)


## What happened, for a probe or a test to read. Nothing here is authoritative about the picture; it is the
## instrument that says whether the pass ran at all, because a pass that quietly does nothing looks exactly
## like a shader that is right.
func status() -> String:
	return _status if not _built else "%s, %d frames" % [_status, _frames]


## **Everything the frame needs, handed over in the camera's own view space.**
##
## Computed in GDScript because that is where `double` is: the offsets are metres between two quantities of
## ~1e6-1e11 m, and doing that subtraction in the shader would lose the answer.
##
## `body` is the atmosphere being looked through — or `null` for none, which zeroes the parameters so the
## shader takes its exit on the first instruction.
func prepare(
	camera: Camera3D, body_centre_world: Vector3, planet_radius: float, atmosphere_radius: float,
	sun_direction_world: Vector3, air: Dictionary, blend: float
) -> void:
	if camera == null:
		blend = 0.0
	var view := camera.global_transform
	# **The EYE relative to the body's centre**, not the other way round — the march's sphere test takes the
	# ray's origin and a sphere centred on the origin, so this is the vector from the body to the camera.
	# Getting it backwards marches away from the planet: the density is zero, the transmittance stays 1 and
	# the frame comes back unchanged, which looks exactly like a pass that draws nothing.
	#
	# `w = 0` for a direction: it rotates without translating, so no astronomical coordinate is ever
	# subtracted inside the shader.
	var eye_offset := view.basis.inverse() * (view.origin - body_centre_world)
	var sun_direction := view.basis.inverse() * sun_direction_world
	_values.fill(0.0)
	_values[0] = eye_offset.x
	_values[1] = eye_offset.y
	_values[2] = eye_offset.z
	_values[4] = sun_direction.x
	_values[5] = sun_direction.y
	_values[6] = sun_direction.z
	var rayleigh: Vector3 = air.get("rayleigh", Vector3.ZERO)
	_values[8] = rayleigh.x
	_values[9] = rayleigh.y
	_values[10] = rayleigh.z
	_values[11] = float(air.get("rayleigh_scale_height", 1.0))
	var absorption: Vector3 = air.get("absorption", Vector3.ZERO)
	_values[12] = absorption.x
	_values[13] = absorption.y
	_values[14] = absorption.z
	_values[16] = float(air.get("mie", 0.0))
	_values[17] = float(air.get("mie_scale_height", 1.0))
	_values[18] = float(air.get("mie_anisotropy", 0.758))
	_values[19] = float(air.get("sun_intensity", 0.0))
	# The frame block is finished in the callback, where the render target's size is known; the vertical
	# half-angle and the on/off are per-frame facts here.
	_values[22] = tan(deg_to_rad(camera.fov * 0.5))
	_values[23] = 0.0 if atmosphere_radius <= planet_radius else clampf(blend, 0.0, 1.0)
	# No air means no march: the shader exits on the blend test before anything else is read.
	_values[24] = planet_radius
	_values[25] = atmosphere_radius

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
	# **A frame with the volume off costs nothing at all**: no dispatch, no uniform set, the frame is left
	# exactly as it was drawn.
	if _values[23] <= 0.0:
		_status = "off"
		return
	var color: RID = buffers.get_color_texture()
	if not color.is_valid():
		_status = "no colour texture"
		return
	var size := Vector2(buffers.get_internal_size())
	if size.x < 1.0 or size.y < 1.0:
		return
	# The render target's size, which is `FRAGCOORD`'s and not the window's — the same distinction the
	# star field had to learn.
	_values[20] = size.x
	_values[21] = size.y
	_status = "ready"

	if _frames == 0:
		print("ATMO: size=%s radii=(%.0f, %.0f) blend=%.1f"
			% [size, _values[24], _values[25], _values[23]])
	var set := _uniform_set(rd, [color, _params])
	if not set.is_valid():
		_status = "the uniform set could not be built"
		return
	rd.buffer_update(_params, 0, PARAM_FLOATS * 4, _values.to_byte_array())
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, set, 0)
	rd.compute_list_dispatch(
		list, ceili(size.x / float(BLOCK)), ceili(size.y / float(BLOCK)), 1
	)
	rd.compute_list_end()
	_frames += 1


func _uniform_set(rd: RenderingDevice, resources: Array) -> RID:
	var uniforms: Array[RDUniform] = []
	var color_uniform := RDUniform.new()
	color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	color_uniform.binding = 0
	color_uniform.add_id(resources[0])
	uniforms.append(color_uniform)
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	params_uniform.binding = 1
	params_uniform.add_id(resources[1])
	uniforms.append(params_uniform)
	return rd.uniform_set_create(uniforms, _shader, 0)


func _build(rd: RenderingDevice) -> void:
	_shader = _compile(rd, _source())
	if not _shader.is_valid():
		_status = "the compute shader did not compile — see the errors above"
		return
	_pipeline = rd.compute_pipeline_create(_shader)
	_params = rd.storage_buffer_create(PARAM_FLOATS * 4)
	_built = true
	_status = "ready"


func _compile(rd: RenderingDevice, source: String) -> RID:
	var shader_source := RDShaderSource.new()
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	shader_source.source_compute = source
	var spirv := rd.shader_compile_spirv_from_source(shader_source)
	var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not error.is_empty():
		push_error("SpacesimAtmospherePass: compute shader did not compile — %s" % error)
		return RID()
	return rd.shader_create_from_spirv(spirv)


## The compute source. **A source string gets no preprocessor**, so there is nothing to `#include`: `#version`
## has to be the first thing glslang sees. When the cloud volume returns it will need the noise include
## concatenated in front, exactly as `SpacesimCloudGpu._source()` does for the field.
func _source() -> String:
	return "#version 450\n" + SOURCE


## **The march, in the same units as `glsl-atmosphere`** — Rye Terrell, wwwtyro.net, Unlicense — applied to
## a ray from the eye instead of to a shell's fragment.
##
## It is a port of `body_atmosphere.gdshader`'s `sky_color`, and every hard-won correction there is carried
## across verbatim, because each of them was a bug that showed up as a wrong picture:
##
## - the march **starts at the eye** (`max(span.x, 0)`), because from inside the air the near root is behind
##   the camera and using it made the step size 8,000x too large;
## - a planet hit must **exist and lie ahead** (`x <= y && x > 0`), because `ray_sphere`'s miss sentinel is
##   the *positive* number 1e5 and `x > 0` alone accepted it;
## - samples are **quadratically spaced** toward the eye, where the air is;
## - the miss sentinel is compared, never tested for sign.
const SOURCE := """layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(std430, set = 0, binding = 1) buffer Params {
	vec4 eye_offset;      // the body's centre relative to the eye, VIEW space, metres
	vec4 sun_direction;   // VIEW space, unit
	vec4 rayleigh;        // xyz 1/m, w scale height in metres
	vec4 absorption;      // xyz 1/m
	vec4 mie;             // x coefficient, y scale height, z anisotropy, w sun intensity
	vec4 frame;           // xy render size, z tan(fov/2), w blend 0..1
	vec4 radii;           // x planet, y atmosphere top, zw free for the cloud volume
} params;

const int I_STEPS = 16;
const int J_STEPS = 8;
const float PI_F = 3.141592653589793;
// A miss is signalled with x > y, and `x` is POSITIVE — so a hit must be proved, never inferred from a
// sign. Same sentinel and same lesson as the shell's shader.
vec2 ray_sphere(vec3 origin, vec3 direction, float radius) {
	float b = 2.0 * dot(direction, origin);
	float c = dot(origin, origin) - (radius * radius);
	float d = (b * b) - 4.0 * c;
	if (d < 0.0) {
		return vec2(1e5, -1e5);
	}
	return vec2((-b - sqrt(d)) * 0.5, (-b + sqrt(d)) * 0.5);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(params.frame.x) || pixel.y >= int(params.frame.y)) {
		return;
	}
	if (params.frame.w <= 0.0) {
		return;
	}
	vec4 here = imageLoad(color_image, pixel);

	// The ray for this pixel, in view space: the camera is the origin and looks down -Z.
	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.frame.xy;
	float tan_y = params.frame.z;
	float tan_x = tan_y * params.frame.x / params.frame.y;
	vec2 ndc = vec2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
	vec3 ray = normalize(vec3(ndc.x * tan_x, ndc.y * tan_y, -1.0));
	vec3 eye = params.eye_offset.xyz;

	// **REJECTION FIRST.** A ray that misses the air is the common case in an empty sky and must cost a few
	// instructions, not a march.
	vec2 span = ray_sphere(eye, ray, params.radii.y);
	if (span.x > span.y) {
		return;
	}


	// **The ground comes from the analytic sphere test below, not from the depth buffer.** For the body's own
	// surface that is exact, and the only other thing that could occlude the air is an object a few metres
	// from the camera, where the column in front of it contributes ~3e-4 of the sky. A depth texture would
	// buy that and cost a projection-convention dependency inside the march; it is the first thing to add if
	// a foreground object ever reads wrong.
	float start = max(span.x, 0.0);
	float end = span.y;
	vec2 planet_span = ray_sphere(eye, ray, params.radii.x);
	if (planet_span.x <= planet_span.y && planet_span.x > 0.0) {
		end = min(end, planet_span.x);
	}

	if (end <= start) {
		return;
	}
	float span_length = end - start;

	vec3 sun = params.sun_direction.xyz;
	float mu = dot(ray, sun);
	float mumu = mu * mu;
	float gg = params.mie.z * params.mie.z;
	float phase_rayleigh = 3.0 / (16.0 * PI_F) * (1.0 + mumu);
	float phase_mie = 3.0 / (8.0 * PI_F) * ((1.0 - gg) * (mumu + 1.0))
		/ (pow(1.0 + gg - 2.0 * mu * params.mie.z, 1.5) * (2.0 + gg));

	vec3 total_rayleigh = vec3(0.0);
	vec3 total_mie = vec3(0.0);
	float depth_rayleigh = 0.0;
	float depth_mie = 0.0;

	for (int i = 0; i < I_STEPS; i++) {
		float f0 = float(i) / float(I_STEPS);
		float f1 = float(i + 1) / float(I_STEPS);
		float t0 = start + span_length * f0 * f0;
		float t1 = start + span_length * f1 * f1;
		float step_size = t1 - t0;
		vec3 position = eye + ray * (t0 + step_size * 0.5);
		float height = length(position) - params.radii.x;
		float step_rayleigh = exp(-height / params.rayleigh.w) * step_size;
		float step_mie = exp(-height / params.mie.y) * step_size;
		depth_rayleigh += step_rayleigh;
		depth_mie += step_mie;

		float sun_step = ray_sphere(position, sun, params.radii.y).y / float(J_STEPS);
		float sun_depth_rayleigh = 0.0;
		float sun_depth_mie = 0.0;
		float s = 0.0;
		for (int j = 0; j < J_STEPS; j++) {
			float sun_height = length(position + sun * (s + sun_step * 0.5)) - params.radii.x;
			sun_depth_rayleigh += exp(-sun_height / params.rayleigh.w) * sun_step;
			sun_depth_mie += exp(-sun_height / params.mie.y) * sun_step;
			s += sun_step;
		}
		vec3 attenuation = exp(-(params.mie.x * (depth_mie + sun_depth_mie)
			+ (params.rayleigh.xyz + params.absorption.xyz)
				* (depth_rayleigh + sun_depth_rayleigh)));
		total_rayleigh += step_rayleigh * attenuation;
		total_mie += step_mie * attenuation;
	}

	vec3 scattered = phase_rayleigh * params.rayleigh.xyz * total_rayleigh
		+ phase_mie * params.mie.x * total_mie;
	// **The whole column's transmittance**, so what is behind the air is dimmed by exactly the air in
	// front of it — the ground, the stars, and anything already drawn at that pixel.
	vec3 transmittance = exp(-(params.mie.x * depth_mie
		+ (params.rayleigh.xyz + params.absorption.xyz) * depth_rayleigh));

	vec3 color = here.rgb * transmittance + scattered * params.mie.w * params.frame.w;
	// **Not clamped to 1.0**: this writes linear HDR and the tonemap downstream decides what is white.
	imageStore(color_image, pixel, vec4(color, here.a));
}
"""
