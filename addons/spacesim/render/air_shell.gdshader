shader_type spatial;
// **The air, as ONE BAND of a body's atmosphere, worn as a shell.**
//
// Evert, 2026-11-02: *"To move the volumetric atmosphere back out of the skybox, and into a stack of shaders
// that we have for each planet... I would really like to model some air between the camera and mountains, and
// some mountains might poke through a shell."*
//
// ## Why a shell, again
//
// The shell that drew the air until 2026-10-19 was replaced because of one limitation it could not work
// around, stated in `49f28cb`: a spatial shader could not read the depth buffer, so the only surface its march
// could stop at was the analytic planet sphere — and from space the far face that would carry the air over the
// disc was rejected by the depth test. **Both of those are now false.** `body_ocean.gdshader` reads
// `hint_depth_texture` in a transparent spatial shader, and `depth_test_disabled` means the far face is not
// rejected at all: it survives wherever the mountain is, asks the buffer where the surface is, and draws only
// the air in front of it.
//
// That is the whole of the difference from the pass: a mountain poking through this shell no longer deletes
// the air in front of it, and a body beyond the atmosphere — Luna, four pixels wide — no longer has the air
// drawn behind it.
//
// ## The band invariant
//
// **This shader integrates the ray's chord through ITS OWN BAND and nothing else.** Both endpoints are the
// ray's crossings of `u_band_inner` / `u_band_outer`, so the bands sum to the whole column and no instance
// needs to know where the eye is relative to the others — only the host's draw order does (a second shell, a
// deck between them, is the next step; this file is one band at a time).
//
// ## The two things the budget buys
//
// `I_STEPS` is the view march, `J_STEPS` the sun's. The second one is half the cost and most of the look — it
// is what gives the red sunset and the aureole — so it is not the one to cut.
//
// Everything here is in the body's own frame and in metres from its centre: a GLSL float has ~7 digits and a
// body centre sits at 1.5e11 m, so the host subtracts in double and hands over the small numbers.
render_mode unshaded, cull_front, depth_test_disabled, depth_draw_never, blend_mix, fog_disabled;

uniform vec3 u_rayleigh = vec3(0.0);
uniform float u_rayleigh_h = 8500.0;
uniform vec3 u_absorption = vec3(0.0);
uniform float u_mie = 0.0;
uniform float u_mie_h = 1200.0;
uniform float u_mie_g = 0.758;
uniform float u_sun_intensity = 0.0;
uniform float u_planet_radius = 6371000.0;
// **The band this shell is.** `inner` is the surface it stands on — the ground's, or a deck's base once a
// second shell exists — and `outer` is the next boundary outward.
uniform float u_band_inner = 6371000.0;
uniform float u_band_outer = 6471000.0;
// The eye, offset from the body's centre; the star, as a unit direction; and the rotation from view space.
uniform vec3 u_eye_local = vec3(0.0);
uniform vec3 u_sun_local = vec3(0.0, 1.0, 0.0);
uniform mat3 u_to_local = mat3(1.0);
// **How much of it is drawn**, from the host's gate: the air's limb ring in pixels, faded over its last two.
// A shell that switched on at two pixels would pop, and alpha is the only thing a strength can scale here.
uniform float u_strength = 1.0;
// **The frame's own surface**, which is where this march must stop. Sampled rather than tested: the depth
// attachment is not a storage image.
uniform sampler2D depth_texture : hint_depth_texture;

const int I_STEPS = 16;
const int J_STEPS = 8;
const float PI_F = 3.141592653589793;

// A miss is signalled with x > y, and `x` is POSITIVE — so a hit must be proved, never inferred from a sign.
// The same sentinel and the same lesson as the pass's and the deleted shell's.
vec2 ray_sphere(vec3 origin, vec3 direction, float radius) {
	float b = 2.0 * dot(direction, origin);
	float c = dot(origin, origin) - (radius * radius);
	float d = (b * b) - 4.0 * c;
	if (d < 0.0) {
		return vec2(1e5, -1e5);
	}
	return vec2((-b - sqrt(d)) * 0.5, (-b + sqrt(d)) * 0.5);
}

void fragment() {
	vec3 dir = u_to_local * normalize(VERTEX);

	// ===== THE BAND'S CHORD ==============================================================
	vec2 outer = ray_sphere(u_eye_local, dir, u_band_outer);
	if (outer.x > outer.y) {
		discard;
	}
	float t0 = max(outer.x, 0.0);
	float t1 = outer.y;
	// **The ground inside the band**, and the only occlusion this shader does not get from the depth buffer:
	// the planet itself is a sphere and needs no sampling. `inner.x > t0` is the front surface ahead; the eye
	// inside the inner sphere is the "under the ground" case, which starts the chord after the far wall —
	// wrong, and impossible for a camera that is above its own surface.
	vec2 inner = ray_sphere(u_eye_local, dir, u_band_inner);
	if (inner.x <= inner.y && inner.x > t0) {
		t1 = min(t1, inner.x);
	}

	// ===== WHERE THE FRAME SAYS THE SURFACE IS ===========================================
	//
	// **A mountain that pokes through this shell must not delete the air in front of it.** With the depth test
	// off the shell is drawn wherever its far face is, so the surface has to be found here, and the depth
	// buffer is the only thing that knows. `0.0` is reverse-Z FAR, so a sky pixel clips nothing.
	float buffer_depth = texture(depth_texture, SCREEN_UV).r;
	if (buffer_depth > 0.0) {
		vec4 scene_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, buffer_depth, 1.0);
		// The unprojected point is on this pixel's ray and the eye is the origin, so its length IS the
		// distance along the ray. Convention-free by construction — whatever the projection did, this undoes.
		t1 = min(t1, length(scene_view.xyz / max(abs(scene_view.w), 1.0e-9)));
	}
	if (t1 <= t0) {
		discard;
	}

	// ===== THE MARCH =====================================================================
	vec3 sun = u_sun_local;
	float mu = dot(dir, sun);
	float mumu = mu * mu;
	float g = u_mie_g;
	float gg = g * g;
	float phase_r = 3.0 / (16.0 * PI_F) * (1.0 + mumu);
	float phase_m = 3.0 / (8.0 * PI_F) * ((1.0 - gg) * (mumu + 1.0))
		/ (pow(1.0 + gg - 2.0 * mu * g, 1.5) * (2.0 + gg));

	float span = t1 - t0;
	float depth_r = 0.0;
	float depth_m = 0.0;
	vec3 sum_r = vec3(0.0);
	vec3 sum_m = vec3(0.0);
	for (int i = 0; i < I_STEPS; i++) {
		// **Quadratically spaced toward the eye, where the air is.** The pass measured this: the zenith read
		// 0.32 against a converged 0.65 for even spacing, and within 8% of converged at the same 16 steps.
		float f0 = float(i) / float(I_STEPS);
		float f1 = float(i + 1) / float(I_STEPS);
		float a0 = t0 + span * f0 * f0;
		float a1 = t0 + span * f1 * f1;
		float step_size = a1 - a0;
		if (step_size <= 0.0) {
			continue;
		}
		vec3 position = u_eye_local + dir * (a0 + step_size * 0.5);
		float height = max(length(position) - u_planet_radius, 0.0);
		float step_rayleigh = exp(-height / max(u_rayleigh_h, 1.0)) * step_size;
		float step_mie = exp(-height / max(u_mie_h, 1.0)) * step_size;
		depth_r += step_rayleigh;
		depth_m += step_mie;
		// **The light's own path to this sample**, coarsely: the second transmittance is half the cost and
		// most of the look.
		float sun_step = ray_sphere(position, sun, u_band_outer).y / float(J_STEPS);
		float sun_r = 0.0;
		float sun_m = 0.0;
		float s = 0.0;
		for (int j = 0; j < J_STEPS; j++) {
			float sun_height = max(length(position + sun * (s + sun_step * 0.5)) - u_planet_radius, 0.0);
			sun_r += exp(-sun_height / max(u_rayleigh_h, 1.0)) * sun_step;
			sun_m += exp(-sun_height / max(u_mie_h, 1.0)) * sun_step;
			s += sun_step;
		}
		vec3 attenuation = exp(-(u_mie * (depth_m + sun_m)
			+ (u_rayleigh + u_absorption) * (depth_r + sun_r)));
		sum_r += step_rayleigh * attenuation;
		sum_m += step_mie * attenuation;
	}

	// ===== THE COMPOSITE =================================================================
	//
	// `T` is per channel and a blend's alpha is a scalar, so the extinction of what is behind is carried by
	// one number — `1 - luminance(T)` — while the in-scatter keeps its own colour. The hue of the in-scatter
	// is what makes the sky blue; the hue of the extinction is the corner this cuts.
	//
	// shader: scalar extinction — a sunset's blue-weighted dimming of the ground is approximated by a grey
	// one. The honest fix is per-channel alpha, which no blend mode has; measure it before reaching for one.
	vec3 T = exp(-(u_mie * depth_m + (u_rayleigh + u_absorption) * depth_r));
	vec3 L = (phase_r * u_rayleigh * sum_r + phase_m * u_mie * sum_m) * u_sun_intensity;
	float alpha = 1.0 - clamp(dot(T, vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
	// **Straight colour and an alpha**, because `blend_mix` multiplies by alpha itself: `ALBEDO * ALPHA +
	// behind * (1 - ALPHA)` must equal `L + behind * T`, so the colour handed over is `L / alpha`. The floor
	// only bites where alpha is under a thousandth, where the whole term is under a thousandth too.
	ALBEDO = L / max(alpha, 1.0e-3);
	ALPHA = alpha * u_strength;
}
