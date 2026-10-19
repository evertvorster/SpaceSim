class_name SpacesimAtmospherePass
extends CompositorEffect
## **The air, as a volumetric march** — one `CompositorEffect` at `POST_TRANSPARENT` that reads the resolved
## colour, marches one ray per pixel through the body's atmosphere, and writes the result back in place.
##
## Rebuilt from [[SpaceSim/Atmospheres]] §9a, which is the spec written from the version that was flown and
## verified on 2026-10-18. **It is air only**: the cloud is a later rung ([[SpaceSim/Cloud Volumes]] §6a), and
## the pass is required to work with none — that is the state the 340 fps number was measured in.
##
## ---------------------------------------------------------------- WHY A PASS AND NOT A SHELL
##
## A shell cannot shade the air *over the planet's disk*, because those pixels belong to the planet. A pass owns
## them, so the air over the disc, the limb, and the sky from underneath are one mechanism with one ray:
## there is no far side to depth-reject and no mesh to keep centred on the camera.
##
## ---------------------------------------------------------------- THE NUMBERS ARE THE HOST'S
##
## Nothing here derives any physics. `SpacesimAtmosphereModel` owns the coefficients, the scale heights and the
## radii, and this pass is handed them; the only arithmetic it does is the offset and the rotation, **in
## `double`**, because a GLSL float holds seven digits and a world coordinate of 1.5e11 m cannot be subtracted
## inside a shader. See `eye_offset` below — getting its direction wrong is the most misleading failure this
## pass has produced.

## Taps per pixel, and they are the first budget lever. `I` along the view ray, `J` toward the sun at each
## sample. **128 taps a pixel**; the resolution lever (a half-res pass with a depth-aware upsample) is
## untried and is the thing to measure before the cloud work spends this budget.
const I_STEPS := 16
const J_STEPS := 8

## The blend, 0..1: it scales the in-scatter *and* gates the whole pass, so a frame with it at zero is left
## exactly as it was drawn.
var blend := 1.0

var _built := false
var _status := "not built"
var _shader: RID
var _pipeline: RID
var _params: RID
## The 28 floats, kept on the host so a frame that changes nothing still has them to write.
var _numbers := PackedFloat32Array()
var _numbers_ready := false
var _announced := false


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	# The pass reads the frame and writes it back, so the resolved colour has to be there for it.
	access_resolved_color = true


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _built:
		var rd := RenderingServer.get_rendering_device()
		if rd != null:
			for rid in [_pipeline, _shader, _params]:
				if (rid as RID).is_valid():
					rd.free_rid(rid)


## **The body's centre relative to the eye, in view space** — the one arithmetic this pass can get backwards and
## cannot then distinguish from doing nothing.
##
## The sphere test takes a ray from the origin against a sphere at `eye_offset`, so the vector points **from the
## body to the eye**; backwards, every ray marches away from the planet, the density is zero, transmittance stays
## 1 and the frame comes back unchanged. Pure, and pinned by a test, because the failure is silent.
static func view_offset(basis_inverse: Basis, eye: Vector3, body_centre: Vector3) -> Vector3:
	return basis_inverse * (eye - body_centre)


## A world direction rotated into view space. **A rotation, not a translation** — the basis inverse applied to a
## direction, never to a point with an origin — and the eye's own position must not enter it.
static func view_direction(basis_inverse: Basis, world: Vector3) -> Vector3:
	return basis_inverse * world.normalized()


## What happened, for a probe or a test to read. **A pass that quietly does nothing looks exactly like a
## correct one**, and this is the only cheap way to tell them apart.
func status() -> String:
	return _status


## **Hand the pass this frame's numbers.** Called by the scene once a frame, for the body whose air the eye is
## nearest. Every argument is already in the units the shader wants; `body_centre` and `sun_direction` are
## rotated into **view space** by the caller, in `double`.
##
## `body_centre` is the body's centre **relative to the eye** — the sphere test takes a ray from the origin
## against a sphere at `eye_offset`, so the vector must point from the body toward the camera. Backwards, every
## ray marches away from the planet and the frame comes back unchanged.
##
## **`sun_scale` is not lux.** The frame's own convention is `radiance / UNIT_LUX_PER_SR` (`100000 / pi`), which
## is what the star field and the point lights both write, so the caller hands over
## `SpacesimAtmosphereModel.sky_scale(illuminance)` — the derivation's existing conversion — rather than a raw
## illuminance. Passing lux here makes the air about 32,000x too bright, which tone-maps to a white sky and reads
## as a broken march rather than as a wrong unit.
func set_air(
	body_centre: Vector3,
	sun_direction: Vector3,
	rayleigh: Vector3,
	rayleigh_scale_height: float,
	absorption: Vector3,
	mie_coefficient: float,
	mie_scale_height: float,
	mie_anisotropy: float,
	sun_scale: float,
	planet_radius: float,
	air_top: float,
	tan_half_fov: float
) -> void:
	_numbers = PackedFloat32Array([
		body_centre.x, body_centre.y, body_centre.z, 0.0,
		sun_direction.x, sun_direction.y, sun_direction.z, 0.0,
		rayleigh.x, rayleigh.y, rayleigh.z, rayleigh_scale_height,
		absorption.x, absorption.y, absorption.z, 0.0,
		mie_coefficient, mie_scale_height, mie_anisotropy, sun_scale,
		0.0, 0.0, tan_half_fov, blend,           # frame.xy is the render size, filled at dispatch
		planet_radius, air_top, 0.0, 0.0,
	])
	_numbers_ready = true


func _build(rd: RenderingDevice) -> void:
	_shader = _compile(rd, MARCH_SOURCE)
	if not _shader.is_valid():
		_status = "did not compile"
		return
	_pipeline = rd.compute_pipeline_create(_shader)
	# Seven `vec4`s: 112 bytes. A storage buffer rather than push constants, because a push-constant block is
	# 128 bytes and this one is not going to stay at 112 forever.
	_params = rd.storage_buffer_create(112)
	_built = true
	_status = "ready"


## GLSL from a **source string**, so no `.glsl` file and no import step. Two consequences that have each cost a
## debug cycle: `#version 450` must be the first thing glslang sees, and **no `#[compute]` marker** — that is
## Godot's own file convention and a string handed straight to the compiler gets no such treatment.
func _compile(rd: RenderingDevice, source: String) -> RID:
	var shader_source := RDShaderSource.new()
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	shader_source.source_compute = source
	var spirv := rd.shader_compile_spirv_from_source(shader_source)
	# `get_stage_compile_error` returns the **message**, not an `Error`: empty means it compiled. **Reported, not
	# thrown** — a compile failure is a status string, so a pass that does nothing cannot pass for a working one.
	var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not error.is_empty():
		push_error("SpacesimAtmospherePass: the march did not compile — %s" % error)
		_status = "did not compile — see the error above"
		return RID()
	return rd.shader_create_from_spirv(spirv)


func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	# **The gate comes first**, before anything else is read: a frame with the air off costs nothing at all.
	if blend <= 0.0 or not _numbers_ready:
		return
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
	# **The render target's size, not the window's** — the same distinction the star field had to learn, and
	# getting it wrong gives a frame that looks right at one resolution and wrong at another.
	var size := Vector2(buffers.get_internal_size())
	if size.x < 1.0 or size.y < 1.0:
		return

	_numbers[20] = size.x
	_numbers[21] = size.y
	_numbers[23] = blend
	rd.buffer_update(_params, 0, 112, _numbers.to_byte_array())

	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(color)
	var buffer_uniform := RDUniform.new()
	buffer_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	buffer_uniform.binding = 1
	buffer_uniform.add_id(_params)
	var set := rd.uniform_set_create([uniform, buffer_uniform], _shader, 0)
	if not set.is_valid():
		_status = "a uniform set could not be built"
		return

	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, set, 0)
	rd.compute_list_dispatch(list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
	rd.compute_list_end()
	# **Freed at the end of the callback, and that is required.** Three uniform sets a frame is a thousand a
	# second at 340 fps, and the engine's `UniformSet` allocator is exhausted inside a minute — after which the
	# *2D* renderer fails and the whole frame stops shading, which reads as a rendering crash and not as a leak
	# in a pass. `free_rid` defers disposal to a frame index the device has not reached, so this is safe while
	# the compute list is still in flight.
	rd.free_rid(set)
	if not _announced:
		_announced = true
		# **Said once, on the frame it first runs**: a pass that quietly does nothing looks exactly like a correct
		# one, and this line plus `status()` is the only cheap way to tell them apart.
		print("AIR: march on, %.0fx%.0f, planet %s m, air top %s m"
			% [size.x, size.y, str(_numbers[24]), str(_numbers[25])])
	_status = "ready"


## The march. **Every trap in `Atmospheres` §9a's table is marked where it can bite**, because each one has
## already cost a cycle: the miss sentinel is positive, a planet hit must be *proved*, the march must start at
## the eye when the eye is inside the air, and no identifier may be `sample`.
const MARCH_SOURCE := """#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;

layout(std430, set = 0, binding = 1) buffer Params {
	vec4 eye_offset;      // the body's centre relative to the eye, view space, metres
	vec4 sun_direction;   // unit, view space
	vec4 rayleigh;        // xyz coefficient 1/m, w scale height m
	vec4 absorption;      // xyz coefficient 1/m
	vec4 mie;             // x coefficient, y scale height, z anisotropy, w the sun, scaled to frame units
	vec4 frame;           // xy render size px, z tan(fov/2), w blend
	vec4 radii;           // x planet, y air top
} params;

const int I_STEPS = 16;
const int J_STEPS = 8;

// **A MISS AND A HIT MUST BE DISTINGUISHABLE, and the sentinel is positive.** `(1e5, -1e5)` gives x > y on a
// miss, so a hit is `x <= y && x > 0`: it must exist *and* lie ahead of the eye. Testing the sign alone
// accepts the sentinel and clamps every missing ray to a real march.
vec2 ray_sphere(vec3 centre, float radius, vec3 direction) {
	float b = dot(centre, direction);
	float c = dot(centre, centre) - radius * radius;
	float d = b * b - c;
	if (d < 0.0) {
		return vec2(1e5, -1e5);
	}
	d = sqrt(d);
	return vec2(-b - d, -b + d);
}

float rayleigh_phase(float mu) {
	return 3.0 / (16.0 * 3.141592653589793) * (1.0 + mu * mu);
}

float mie_phase(float mu, float g) {
	float gg = g * g;
	return 3.0 / (8.0 * 3.141592653589793) * ((1.0 - gg) * (1.0 + mu * mu))
		/ ((2.0 + gg) * pow(1.0 + gg - 2.0 * g * mu, 1.5));
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.frame.xy);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}
	if (params.frame.w <= 0.0) {
		return;
	}

	// ---- the ray: the camera is the origin and looks down -z
	vec2 ndc = (vec2(pixel) + 0.5) / params.frame.xy * 2.0 - 1.0;
	ndc.y = -ndc.y;
	float tan_y = params.frame.z;
	float tan_x = tan_y * params.frame.x / params.frame.y;
	vec3 direction = normalize(vec3(ndc.x * tan_x, ndc.y * tan_y, -1.0));

	float planet_radius = params.radii.x;
	float air_top = params.radii.y;
	vec3 centre = params.eye_offset.xyz;

	// ---- rejection first: in an empty sky this is the common case and must cost a few instructions
	vec2 air_span = ray_sphere(centre, air_top, direction);
	if (air_span.x > air_span.y || air_span.y <= 0.0) {
		return;
	}

	// ---- the ground is the analytic planet hit, not the depth buffer
	vec2 planet_span = ray_sphere(centre, planet_radius, direction);
	bool planet_hit = planet_span.x <= planet_span.y && planet_span.x > 0.0;

	// ---- **the march starts at the eye.** From inside the air the near root is behind the camera, and using
	// it makes every step thousands of times too long: a hard edge and no sky.
	float start = max(air_span.x, 0.0);
	float end = air_span.y;
	if (planet_hit) {
		end = min(end, planet_span.x);
	}
	float span = end - start;
	if (span <= 0.0) {
		return;
	}

	float mu = dot(direction, params.sun_direction.xyz);
	float phase_rayleigh = rayleigh_phase(mu);
	float phase_mie = mie_phase(mu, params.mie.z);

	float rayleigh_height = max(params.rayleigh.w, 1.0);
	float mie_height = max(params.mie.y, 1.0);

	vec3 accumulated_rayleigh = vec3(0.0);
	vec3 accumulated_mie = vec3(0.0);
	vec3 in_scatter = vec3(0.0);

	for (int i = 0; i < I_STEPS; i++) {
		// **Samples are spaced quadratically toward the eye**, because that is where the air is: linear spacing
		// spends most of the budget in thin air.
		float fraction = float(i) / float(I_STEPS);
		float t = start + span * fraction * fraction;
		float next_fraction = float(i + 1) / float(I_STEPS);
		float t_next = start + span * next_fraction * next_fraction;
		float step_size = t_next - t;

		vec3 point = direction * t;
		float height = max(length(point - centre) - planet_radius, 0.0);
		float density_rayleigh = exp(-height / rayleigh_height);
		float density_mie = exp(-height / mie_height);

		accumulated_rayleigh += density_rayleigh * step_size;
		accumulated_mie += density_mie * step_size;

		// ---- the second march, from this sample toward the sun, out of the air top
		//
		// **A sample the planet stands in the way of is in shadow, and it must contribute nothing.** Without this
		// test the sun ray marches straight through the body, which *underestimates* its optical depth and so
		// leaves the night side scattering as if it were day — the air glows on the dark limb, and it reads as an
		// exposure fault rather than as a missing shadow. It is the one thing here the ground would show.
		vec2 sun_planet = ray_sphere(centre - point, planet_radius, params.sun_direction.xyz);
		if (sun_planet.x <= sun_planet.y && sun_planet.x > 0.0) {
			continue;
		}
		vec2 sun_span = ray_sphere(centre - point, air_top, params.sun_direction.xyz);
		if (sun_span.x > sun_span.y) {
			continue;
		}
		float sun_start = max(sun_span.x, 0.0);
		float sun_span_length = sun_span.y - sun_start;
		float sun_step = sun_span_length / float(J_STEPS);
		float view_rayleigh = 0.0;
		float view_mie = 0.0;
		float sun_t = sun_start;
		for (int j = 0; j < J_STEPS; j++) {
			vec3 sun_point = point + params.sun_direction.xyz * sun_t;
			float sun_height = max(length(sun_point - centre) - planet_radius, 0.0);
			view_rayleigh += exp(-sun_height / rayleigh_height) * sun_step;
			view_mie += exp(-sun_height / mie_height) * sun_step;
			sun_t += sun_step;
		}

		// **Both columns, both species**: the view ray's and the sun ray's, which is what makes a sunset orange
		// rather than merely dim.
		vec3 tau = params.rayleigh.xyz * (accumulated_rayleigh + view_rayleigh)
			+ params.mie.x * 1.1 * (accumulated_mie + view_mie)
			+ params.absorption.xyz * (accumulated_rayleigh + view_rayleigh);
		vec3 attenuation = exp(-tau);

		in_scatter += attenuation * (
			density_rayleigh * params.rayleigh.xyz * phase_rayleigh
			+ density_mie * params.mie.x * phase_mie
		) * step_size;
	}

	// ---- the composite. **`T` is the whole column's transmittance**, so what is behind the air is dimmed by
	// exactly the air in front of it: the ground, the stars, and anything already drawn at that pixel — which is
	// how a cloud deck drawn before this pass gets its air for nothing.
	vec3 tau_total = params.rayleigh.xyz * accumulated_rayleigh
		+ params.mie.x * 1.1 * accumulated_mie
		+ params.absorption.xyz * accumulated_rayleigh;
	vec3 transmittance = exp(-tau_total);

	vec4 color = imageLoad(color_image, pixel);
	vec3 scattered = in_scatter * params.mie.w;
	// **Not clamped**: this is linear HDR and the tonemap downstream decides what is white.
	vec3 result = color.rgb * transmittance + scattered * params.frame.w;
	imageStore(color_image, pixel, vec4(result, color.a));
}
"""
