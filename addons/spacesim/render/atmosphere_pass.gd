class_name SpacesimAtmospherePass
extends CompositorEffect
## **The atmosphere, as ONE volumetric march over the whole frame.**
##
## Evert, 2026-10-18: *"the atmosphere should be visible from outer space, so when a planet fills the
## screen, we'll be marching the entire thing with the cloud layer in it."*
##
## ## Why a pass and not a shell
##
## The shell that drew the air until then could never shade the air in front of the planet's disk, because
## the geometry that would carry those pixels is *behind* the planet and loses the depth test. A pass owns
## every pixel, so the air is shaded wherever the ray passes through it: over the disk from space, around
## the limb, and from inside as the sky.
##
## **The clouds went out of this file on 2026-10-18 and came back on 2026-10-21**, and the interval is worth
## knowing because it is why the deck is drawn as it is. Every version of them written here first was wrong
## (an opaque deck can only show its thresholded silhouette, and nothing had proved it was translucent), so
## they were rebuilt from a clean slate as a volume of their own. What returned is a **segment**: the ray is
## walked front to back — haze, air, deck, air — with the boundaries from `SpacesimCloudBand.spans()`, which
## is what makes looking up from *below* a deck correct. `MARCHES_DECK` is false because the shell also draws
## the deck from both sides and the air must not be split at radii nothing occludes; `march_deck`/`deck_span`
## are kept for the next rung. **Measured at the 2026-10-18 baseline: 340 fps in flight**; the deck in the
## march took it to 90, and that is the cost each rung has to earn back.
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
## **How many per-frame uniform sets are alive**, which must return to zero: the set is rebuilt each frame
## because the colour texture's RID can change with the render target, and a set that is created and not
## freed is a RID gone from the frame device's allocator. Reported at teardown rather than watched, so the
## cost is one integer and the check costs nothing per frame.
var _sets_live := 0

var _shader: RID
var _pipeline: RID
var _params: RID
## **The sampler and the fallback texel.** A combined image sampler needs both, and the set is rebuilt every
## frame because the deck's map is replaced when it refines — so a texture that is not there yet has to be a
## real one, not a null RID. This is the same class of trap as the per-frame uniform set: an invalid id in a
## set fails the whole dispatch, and the failure looks like "the pass drew nothing".
var _sampler: RID
var _white: ImageTexture
## The deck's map for this frame, or null when the near regime is not live — the callback turns it into a
## uniform id and falls back to `_white` so the set is always complete.
var _deck_texture: Texture2D
## **How opaque the map's relative reading means** — the fog's only free number, hot from `fog.gain`. Everything
## else in the fog is a consequence: the amount is the cloud map's reading at the camera, and the ramp is full at
## the deck's base and zero at its top because those are where the geometry puts them.
var fog_gain := 2.0

## The per-frame numbers, in the order the shader's `Params` block declares them. Written as one buffer
## update rather than as push constants, because a push-constant block is only 128 bytes.
##
##    0..3   eye_offset          4..7   sun_direction       8..11  rayleigh
##   12..15  absorption          16..19 mie                20..23  frame (size, tan)
##   24..27  radii (planet, atmosphere top, deck top, deck weight)
##   28..31  deck  (base radius, extinction 1/m, threshold, full column height)
##   32..35  deck radiance (xyz)
##   36..47  view -> deck model space, as three vec4 columns
##   48..51  the camera in the deck's model space — what the fog samples by
##
## **The deck is ONE layer, the top one, and that is a named limit rather than an oversight.** The near
## regime is only live inside or just under the top deck, where a lower deck is seen through the gaps of the
## one above it — so the stack belongs in the rung after this one, with a sampler array and a per-deck loop.
## Until then a body with two decks (Jupiter, Saturn) draws its near regime as its top deck alone, and the
## shell still draws both from above.
var _values := PackedFloat32Array()
const PARAM_FLOATS := 52


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	# The pass reads the frame and writes it back, so the resolved colour has to be there for it.
	access_resolved_color = true
	_values.resize(PARAM_FLOATS)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or not _built:
		return
	# **A per-frame allocation that is not per-frame freed is the bug this pass had**, and it is worth
	# shouting about rather than leaving as a slow death: one set a frame exhausts the frame device's RID
	# allocator in about fifteen minutes of flight, and the errors appear in *other* passes — the exposure
	# pass first, then the 2D renderer, which is where Evert saw it (2026-10-20). Fixing it took a minute;
	# finding it took two flights, because the traceback named victims.
	if _sets_live != 0:
		printerr(
			"ERROR: SpacesimAtmospherePass: %d uniform set(s) never freed — a per-frame set must be freed "
			% _sets_live
			+ "per frame, or the RID allocator fills and an unrelated pass fails"
		)
	var rd := RenderingServer.get_rendering_device()
	if rd != null:
		for rid in [_pipeline, _shader, _params, _sampler]:
			if (rid as RID).is_valid():
				rd.free_rid(rid)


## **Everything the frame needs, handed over in the camera's own view space.**
##
## Computed in GDScript because that is where `double` is: the offsets are metres between two quantities of
## ~1e6-1e11 m, and doing that subtraction in the shader would lose the answer.
##
## `body` is the atmosphere being looked through — or `null` for none, which zeroes the parameters so the
## shader takes its exit on the first instruction.
func prepare(
	camera: Camera3D, body_centre_world: Vector3, planet_radius: float, atmosphere_radius: float,
	sun_direction_world: Vector3, air: Dictionary, blend: float, deck: Dictionary = {}
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
	# **The deck, as one slab on the same ray.** The weight is the handover and it is the exact complement of
	# the one the shell applies — 1 below the base, 0 at the top, `smoothstep` across the slab's own
	# thickness — so between them the deck is drawn once and never twice. Both sides derive the fade from the
	# deck's own two radii, so there is no constant to keep in step.
	#
	# **A deck with no map is no deck here.** The publish only hands over once a texture exists, and a bake
	# that is still in flight leaves the shell drawing on its own — a refinement lands *over* the coarse
	# thing and never instead of it.
	if not deck.is_empty():
		var base_radius: float = deck.get("base_radius", 0.0)
		var top_radius: float = deck.get("top_radius", 0.0)
		var texture: Texture2D = deck.get("texture", null)
		if texture != null and top_radius > base_radius:
			var eye_radius := (view.origin - body_centre_world).length()
			_values[26] = top_radius
			_values[27] = 1.0 - smoothstep(base_radius, top_radius, eye_radius)
			_values[28] = base_radius
			_values[29] = float(deck.get("extinction", 0.0))
			_values[30] = float(deck.get("threshold", 0.0))
			_values[31] = float(deck.get("column_height", 0.0))
			var radiance: Vector3 = deck.get("radiance", Vector3.ZERO)
			_values[32] = radiance.x
			_values[33] = radiance.y
			_values[34] = radiance.z
			# The fog's gain, beside the colour it scales — a radiance has no fourth channel.
			_values[35] = fog_gain
			# **View space to the deck's own model space**, done here because a `Basis` is double and a mat3 in
			# the shader is not. The map is body-fixed — it is the same one the mesh samples — so a march that
			# ignored the body's rotation would draw a different cloud from the one the shell draws.
			var body_basis: Basis = deck.get("basis", Basis.IDENTITY)
			var to_model := body_basis.inverse() * view.basis
			for column in 3:
				var axis := to_model[column]
				_values[36 + column * 4] = axis.x
				_values[37 + column * 4] = axis.y
				_values[38 + column * 4] = axis.z
			var eye_model: Vector3 = deck.get("eye_model", Vector3.ZERO)
			_values[48] = eye_model.x
			_values[49] = eye_model.y
			_values[50] = eye_model.z
			# The map's width, which is what turns a step's length in metres into a level of its pyramid.
			_values[51] = float(deck.get("width", 0))
			# Kept for the uniform set, which is built in the callback where the frame's RIDs are known.
			_deck_texture = texture
	else:
		_deck_texture = null


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
		# The numbers the handover depends on, printed once — a pass that quietly hands nothing over looks
		# exactly like a shader that is right, and this is the cheapest way not to be fooled.
		print("ATMO: size=%s radii=(%.0f, %.0f, %.0f) blend=%.1f deck_weight=%.2f deck_ext=%.5f"
			% [size, _values[24], _values[25], _values[26], _values[23], _values[27], _values[29]])
	var set := _uniform_set(rd, [color, _params])
	if not set.is_valid():
		_status = "the uniform set could not be built"
		return
	_sets_live += 1
	rd.buffer_update(_params, 0, PARAM_FLOATS * 4, _values.to_byte_array())
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline)
	rd.compute_list_bind_uniform_set(list, set, 0)
	rd.compute_list_dispatch(
		list, ceili(size.x / float(BLOCK)), ceili(size.y / float(BLOCK)), 1
	)
	rd.compute_list_end()
	# **Freed here, and this is not tidiness.** The set is per frame — the colour texture's RID can change
	# with the render target — and `free_rid` is safe while the compute list is still in flight: the device
	# pushes everything so it is disposed of when this frame index is processed next
	# (`rendering_device.cpp`). The exposure pass and `SpacesimCloudGpu` rely on exactly the same guarantee;
	# this pass was the one place that created a set and never freed it.
	rd.free_rid(set)
	_sets_live -= 1
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
	# **A combined image sampler takes the SAMPLER first and the texture second**, and both ids must be valid
	# or the whole set fails — which presents as a pass that drew nothing rather than as a binding error.
	# The deck's map may be absent on any given frame (no bake yet, or a body with no deck), so the fallback is
	# a real one-texel texture rather than a null RID; the shader never reads it, because a missing deck has
	# `radii.w = 0` and exits before the fetch.
	#
	# **And a `Texture2D`'s RID is NOT a `RenderingDevice` texture RID.** Feeding `get_rid()` straight in fails
	# the set with *"Texture (binding: 2, index 0) is not a valid texture"* — the server's RID and the device's
	# live in different spaces, and `RenderingServer.texture_get_rd_texture` is the bridge between them.
	var cover_uniform := RDUniform.new()
	cover_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	cover_uniform.binding = 2
	cover_uniform.add_id(_sampler)
	cover_uniform.add_id(RenderingServer.texture_get_rd_texture(
		(_deck_texture if _deck_texture != null else _white).get_rid()
	))
	uniforms.append(cover_uniform)
	return rd.uniform_set_create(uniforms, _shader, 0)


func _build(rd: RenderingDevice) -> void:
	_shader = _compile(rd, _source())
	if not _shader.is_valid():
		_status = "the compute shader did not compile — see the errors above"
		return
	_pipeline = rd.compute_pipeline_create(_shader)
	_params = rd.storage_buffer_create(PARAM_FLOATS * 4)
	# Linear filtering and repeat on `u`: the map's seam is `u = 1.0` exactly, and a clamped sampler picks the
	# wrong edge there — the same reason `body_deck.gdshader` declares `repeat_enable`.
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	# Linear between levels too: the deck march asks for a level by number, and nearest-mip stepping shows.
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = rd.sampler_create(state)
	var white := Image.create(1, 1, false, Image.FORMAT_L8)
	white.fill(Color.WHITE)
	_white = ImageTexture.create_from_image(white)
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
## It is a port of the deleted `body_atmosphere.gdshader`'s `sky_color` — the shell that held the sky
## until the march replaced it on 2026-10-19, a note now in the vault's `Archive/` — and every hard-won
## correction from it is carried across verbatim, because each was a bug that showed up as a wrong
## picture:
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
	vec4 radii;           // x planet, y atmosphere top, z deck top, w deck weight 0..1
	vec4 deck;            // x base radius, y extinction 1/m, z threshold, w full column height
	vec4 deck_radiance;   // rgb the fog's colour (the deck's drawn brightness); w the fog's gain
	mat3 to_model;        // view space -> the deck's own model space, column-major
	vec4 eye_model;       // xyz the camera in the deck's model space; w the map's width in texels
} params;
// **The deck's baked map, sampled the way the mesh samples it.** Binding 2 is always present; a frame with
// no deck carries `radii.w = 0` and never reads it.
layout(set = 0, binding = 2) uniform sampler2D cover;

const int I_STEPS = 16;
const int J_STEPS = 8;
// **Does this pass draw the deck as a segment?** It does not — the shell draws it from both sides — so there is
// nothing for the air to be ordered around, and splitting it at the deck's radii only loses the air inside that
// span. One flag, because the split and the march are one mechanism.
const bool MARCHES_DECK = false;

// **The band laws, as literals.** `SpacesimCloudBand` is the specification and computes their consequences
// headlessly; the shader carries the numbers, which is the arrangement Cloud Volumes §4.3a states rather than a
// second source of truth. Six samples per e-fold, and the stop at 1/100 gives `ceil(log(100) * 6) = 28` steps
// whatever the chord — what makes the limb affordable, and the difference between a cloud and an opaque lid.
const float SAMPLES_PER_OPTICAL_DEPTH = 6.0;

const int DECK_STEP_LIMIT = 28;
const float PI_F = 3.141592653589793;
const float TAU_F = 6.283185307179586;
// **The exact inverse of `SpacesimCloudField.bake`** — and of `body_deck.gdshader`'s own `cloud_map_uv`, so
// the slab samples the same texel the mesh does. Bands land mirrored or a hemisphere out if this drifts.
vec2 cloud_map_uv(vec3 p) {
	return vec2(0.5 + atan(p.z, p.x) / TAU_F, 0.5 - asin(clamp(p.y, -1.0, 1.0)) / PI_F);
}
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

// **The band's spans along this ray**, as distances from the eye — the region `base <= r <= top`, which a line
// crosses TWICE when it dips below the base. `SpacesimCloudBand.spans()` is this law and `tests/test_cloud_band.gd`
// pins it on the five cases that were flown; this is its transcription.
void deck_span(vec3 eye, vec3 ray, float top_r, float base_r,
	out float lo0, out float hi0, out float lo1, out float hi1) {
	lo0 = 0.0; hi0 = 0.0; lo1 = 0.0; hi1 = 0.0;
	float tc = -dot(eye, ray);
	float d2 = max(dot(eye, eye) - tc * tc, 0.0);
	float outer_half = top_r * top_r - d2;
	if (outer_half <= 0.0) {
		return;
	}
	outer_half = sqrt(outer_half);
	float base_half = base_r * base_r - d2;
	if (base_half <= 0.0) {
		lo0 = tc - outer_half;
		hi0 = tc + outer_half;
		return;
	}
	base_half = sqrt(base_half);
	lo0 = tc - outer_half; hi0 = tc - base_half;
	lo1 = tc + base_half;  hi1 = tc + outer_half;
}

// **ONE SEGMENT OF AIR**, front to back. Every segment carries its own transmittance and in-scatter, which is
// the whole reason the deck can sit between two of them: the air below a deck and the air above it are the same
// integral with a boundary, and the boundary is a deck radius, not a depth buffer.
//
// `depth_*` is cumulative along the view ray and is what the sun attenuation is built from; `seg_*` is this
// segment's own path and is what its transmittance comes from.
void march_air(float t0, float t1, float phase_r, float phase_m, int steps,
		vec3 eye, vec3 ray, vec3 sun, inout float depth_r, inout float depth_m,
		inout vec3 T, inout vec3 L) {
	float span = t1 - t0;
	float seg_r = 0.0;
	float seg_m = 0.0;
	vec3 sum_r = vec3(0.0);
	vec3 sum_m = vec3(0.0);
	for (int i = 0; i < I_STEPS; i++) {
		if (i >= steps) break;
		// Quadratically spaced toward the eye, where the air is.
		float f0 = float(i) / float(steps);
		float f1 = float(i + 1) / float(steps);
		float a0 = t0 + span * f0 * f0;
		float a1 = t0 + span * f1 * f1;
		float step_size = a1 - a0;
		vec3 position = eye + ray * (a0 + step_size * 0.5);
		float height = length(position) - params.radii.x;
		float step_rayleigh = exp(-height / params.rayleigh.w) * step_size;
		float step_mie = exp(-height / params.mie.y) * step_size;
		depth_r += step_rayleigh;
		depth_m += step_mie;
		seg_r += step_rayleigh;
		seg_m += step_mie;
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
		vec3 attenuation = exp(-(params.mie.x * (depth_m + sun_depth_mie)
			+ (params.rayleigh.xyz + params.absorption.xyz)
				* (depth_r + sun_depth_rayleigh)));
		sum_r += step_rayleigh * attenuation;
		sum_m += step_mie * attenuation;
	}
	L += T * (phase_r * params.rayleigh.xyz * sum_r + phase_m * params.mie.x * sum_m) * params.mie.w;
	T *= exp(-(params.mie.x * seg_m + (params.rayleigh.xyz + params.absorption.xyz) * seg_r));
}

// **ONE SEGMENT OF DECK**, the same way: its own transmittance and in-scatter, so the air after it is
// attenuated by it and nothing has to be reordered later.
void march_deck(float lo, float hi, vec3 eye, vec3 ray, inout vec3 T, inout vec3 L) {
	int steps = max(int(round(ceil((hi - lo) * params.deck.y * SAMPLES_PER_OPTICAL_DEPTH))), 1);
	steps = min(steps, DECK_STEP_LIMIT);
	float step_length = (hi - lo) / float(steps);
	for (int i = 0; i < DECK_STEP_LIMIT; i++) {
		if (i >= steps) break;
		vec3 p = eye + ray * (lo + step_length * (float(i) + 0.5));
		// **A filtered pyramid, not level 0.** A ray running along the layer sweeps more than one texel per screen
		// row, so a point sample aliases into bands on the texel grid. This is a compute shader, so there are no
		// derivatives to pick a level with: the footprint comes from the step itself — one step's length in texels
		// of a map whose width covers TAU at this radius.
		float texel_arc = TAU_F * params.deck.x / max(params.eye_model.w, 1.0);
		float lod = clamp(log2(max(step_length / texel_arc, 1.0)), 0.0, 12.0);
		float field = textureLod(cover, cloud_map_uv(normalize(params.to_model * normalize(p))), lod).r;
		// **Luminance is height**: this column's cloud reaches `top` above the base, so a sample above it is in
		// clear air and the lateral edge is a taper rather than a cut.
		float top = params.deck.w * clamp(
			(field - params.deck.z) / max(1.0 - params.deck.z, 1.0e-4), 0.0, 1.0
		);
		// Uniform through the slab and soft at the top. `1 - smoothstep(a, b, x)` and not the descending form:
		// GLSL leaves `smoothstep` undefined when `edge0 >= edge1`.
		float density = top > 0.0
			? 1.0 - smoothstep(0.72, 1.0, (length(p) - params.deck.x) / top)
			: 0.0;
		float alpha = 1.0 - exp(-density * params.deck.y * step_length);
		L += T * params.deck_radiance.rgb * alpha;
		T *= 1.0 - alpha;
	}
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

	// **THE ORDERED WALK.** Front to back: the haze at the eye, then whichever of air and deck this ray meets,
	// in radius order. The deck is not a surface over which the air is painted — it is a SEGMENT, with the air
	// below it in front and the air above it behind, which is the one thing this pass could never do while the
	// deck was a shell composited before the pass ran. Below a deck looking up, that is the whole difference.
	float depth_r = 0.0;
	float depth_m = 0.0;
	vec3 T = vec3(1.0);
	vec3 L = vec3(0.0);

	// **THE FOG AT THE EYE: the texture says how much, the layer's own thickness says how far up.**
	//
	// Evert, 2026-10-21: *"We are approximating based on the refined texture, and scaling based on distance between
	// the top and the bottom of the cloud layer."* — so there is no optics here and no optical depth. Two numbers
	// from things that already exist:
	//
	//   the texture at the CAMERA    how cloudy this patch is, 0..1
	//   altitude above the BASE      over the layer's own thickness, so full at the top and nothing at the bottom
	//
	// Multiply them and that share is the fog, thickest at the base and thinning to nothing at the top.
	float eye_altitude = length(eye) - params.deck.x;
	if (params.radii.w > 0.0 && eye_altitude > 0.0) {
		float eye_field = texture(cover, cloud_map_uv(normalize(params.eye_model.xyz))).r;
		// **The strength is the TEXTURE, not a remapped share of it.** Evert, 2026-10-21: *"for the strength we
		// should just sample the texture before albedo or color or any attenuation is applied."* It was
		// `(field - threshold) / (1 - threshold)` — a reading that is 0 at the coverage threshold and only 1 at the
		// brightest texel the map can hold, so a patch the eye calls solid arrived as 0.5-0.7 before the gain. The
		// field enters directly now; coverage decides only WHETHER there is cloud, using the same smoothstep span
		// the deck's own alpha uses, so clear air stays clear.
		//
		// Nothing of the deck's albedo, palette or `ramp_gain` is anywhere in this number — those belong to the
		// deck's DRAWN brightness, which is a different quantity, and they were already not in it. What was
		// attenuating the fog was the remap.
		float covered = smoothstep(params.deck.z, 1.0, eye_field);
		float strength = clamp(eye_field * params.deck_radiance.w, 0.0, 1.0) * covered;
		// **Thickest at the BASE, thinning as you climb**, full strength the instant you enter. The ramp's two ends
		// are geometry: 1 at the deck's base, 0 at its top, so nothing has to be gated and there is no step at
		// either end.
		float share = strength * (1.0 - clamp(eye_altitude / max(params.deck.w, 1.0), 0.0, 1.0));
		L += T * params.deck_radiance.rgb * share;
		T *= 1.0 - share;
	}

	// **The segment split exists ONLY to order the air around a deck the pass draws.** Evert, 2026-10-21, flying:
	// *"Flying up and down through the 3km split point, I still see the bit of fogginess swapping from bottom to
	// top, and back again... one of the values we calculate is not properly split at the splitting point,
	// absorption or scattering... something does not carry over properly."*
	//
	// It was the air itself. `march_deck()` is not called — the shell draws the deck from both sides — but the walk
	// still cut the air at the deck's two radii and skipped that interval, so **the air inside the slab was never
	// integrated below the split**, while above it `radii.w` is zero and the air is one continuous column.
	// Crossing the top therefore added ~1,600 m of air (Earth) to the integral in one step: a haze that moves as
	// you pass through. **And the same hole was the Venus banding** — the skipped span is bounded by the deck's
	// radii, so near the limb it runs to ~88 km and is chopped per screen row, which is exactly what a band on the
	// horizon is.
	//
	// The rule: a segment structure and the thing it exists to order must switch together. Nothing in this pass
	// occludes the air, so the air is one segment and the split is not computed at all.
	//
	// **Where the split will go when a deck IS marched (Evert, 2026-10-21): the TOP only.** *"Since the texture we
	// are mapping against is on the top layer, I don't think we need to split the air at the bottom as well... for
	// now we can just hang stuff like the fog gradient and maybe some other future things off of it."* So the base
	// radius stays a published value — the fog's gradient and the column profile read it — but it is not a boundary
	// the picture switches on.
	float b_lo[2];
	float b_hi[2];
	int b_count = 0;
	if (MARCHES_DECK && params.radii.w > 0.0) {
		float lo0, hi0, lo1, hi1;
		deck_span(eye, ray, params.radii.z, params.deck.x, lo0, hi0, lo1, hi1);
		if (hi0 > max(lo0, start)) {
			b_lo[b_count] = max(lo0, start);
			b_hi[b_count] = min(hi0, end);
			if (b_hi[b_count] > b_lo[b_count]) {
				b_count += 1;
			}
		}
		if (hi1 > max(lo1, start) && b_count < 2) {
			b_lo[b_count] = max(lo1, start);
			b_hi[b_count] = min(hi1, end);
			if (b_hi[b_count] > b_lo[b_count]) {
				b_count += 1;
			}
		}
	}

	// The air's share of the step budget, so a deck in the way does not multiply the cost of the sky.
	float band_length = 0.0;
	for (int k = 0; k < 2; k++) {
		if (k < b_count) {
			band_length += b_hi[k] - b_lo[k];
		}
	}
	float air_length = max((end - start) - band_length, 1.0);
	float cursor = start;
	for (int k = 0; k < 2; k++) {
		if (k >= b_count) break;
		if (b_lo[k] > cursor) {
			int steps = max(int(round(float(I_STEPS) * (b_lo[k] - cursor) / air_length)), 2);
			march_air(cursor, b_lo[k], phase_rayleigh, phase_mie, min(steps, I_STEPS),
				eye, ray, sun, depth_r, depth_m, T, L);
		}
		// **ALWAYS**, including from inside the band. Evert, 2026-10-20: the deck vanished between 1.5 km and 3 km
		// — the band's own altitude range — while he was in clear air looking at a distant cloud. The cause was
		// this guard: inside the band the pass drew only the fog, and the shell was faded out, so nothing drew
		// the deck. The shell cannot carry that case anyway: it is the body's own patch mesh, so it only covers
		// what the ground's LOD covers, and a cloud near the horizon falls outside it. The mesh is a picture for
		// when you are outside; inside, the cross-section along the ray is the honest one, and it needs no mesh.
		// **NO DECK IS MARCHED ON THIS BRANCH.** The shell draws it from both sides, so the pass contributes the
		// air and the fog only — one cloud, one mechanism, and any difference between the top view and the bottom
		// view is then a property of the texture or the geometry rather than of two different renderers.
		cursor = b_hi[k];
	}
	if (cursor < end) {
		int steps = max(int(round(float(I_STEPS) * (end - cursor) / air_length)), 2);
		march_air(cursor, end, phase_rayleigh, phase_mie, min(steps, I_STEPS),
			eye, ray, sun, depth_r, depth_m, T, L);
	}

	// **One composite, in order.** The air is no longer a single factor applied to a finished frame; it is a
	// sequence of segments whose boundaries are the deck's own radii, so what is behind the deck is dimmed by
	// the air behind it and not by the air in front.
	vec3 color = mix(here.rgb, T * here.rgb + L, params.frame.w);
	// **Not clamped to 1.0**: this writes linear HDR and the tonemap downstream decides what is white.
	imageStore(color_image, pixel, vec4(color, here.a));
}
"""
