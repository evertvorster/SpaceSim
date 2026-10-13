shader_type spatial;
render_mode blend_add, cull_front, unshaded, depth_draw_never, shadows_disabled;

// The air, as a single sphere of Rayleigh and Mie scattering.
//
// **This is `glsl-atmosphere` by Rye Terrell — https://wwwtyro.net/ — applied to a shell instead of
// a fullscreen quad.** Unlicense (public domain). The technique and the Earth-like values behind its
// constants are catalogued in `Notes/Projects/Programming/SpaceSim/wwwtyro.net — reference.md`.
//
// ---------------------------------------------------------------------------------------------------
// WHY A SHELL, AND WHY cull_front
//
// The sphere reaches `radius + frames.atmosphere_altitude`, and **only its far surface is shaded** —
// that surface is the view ray's exit point, which is all the march needs. The march then starts at
// the camera and runs to `min(exit, planet hit)`, and **the planet hit is computed here** because a
// spatial shader cannot read the depth buffer.
//
// That one combination covers every regime with no mode and no second pass, because the depth buffer
// does the occlusion:
//
//   * from outside  — the shell's far side is depth-rejected wherever the planet covers it, so only
//                     the ring around the limb is shaded;
//   * from inside   — the shell's far side IS the sky dome, so the whole sky is shaded.
//
// What it does not do: the haze over the planet's *disk* seen from outside. The shell's far side is
// behind the planet there, so those pixels are never shaded. The limb is the part that reads.
//
// ---------------------------------------------------------------------------------------------------
// WHY blend_add
//
// A sky is something you look *through*: the star's own disk has to stay visible in it. With
// `blend_mix` and alpha 1 the opaque sky would hide the star's mesh, so the scattering adds instead —
// which is also what a limb seen from space is (a glow, not a lid).
//
// ---------------------------------------------------------------------------------------------------
// PRECISION
//
// Everything here is in **view space**, where the numbers are metres from the camera rather than
// astronomical coordinates: `VERTEX` inside `fragment()` is view space, and the two world-axis inputs
// are rotated in with a `w = 0` transform so their large translations never enter. Our radii are
// doubles and GLSL floats have ~7 significant digits, so computing an offset of ~6.4e6 m from
// quantities of ~1.5e11 m would lose every bit of it. GDScript computes both offsets in double
// precision and hands over only the small results.
//
// ---------------------------------------------------------------------------------------------------
// COST
//
// 16 primary steps with an 8-step sun ray — 128 samples per pixel, on every pixel the shell covers.
// This is the heaviest shader in the project; the standing frame-rate loop owes a measurement.

const int I_STEPS = 16;
const int J_STEPS = 8;
const float PI_F = 3.141592653589793;

// The camera relative to the body's centre, in metres, on world axes. Refreshed per frame.
uniform vec3 eye_offset;
// Normalised direction from the body to the star, on world axes. Refreshed per frame.
uniform vec3 sun_direction;
// Scales the whole sky, so it stays in proportion to the surface the star lights.
uniform float sun_intensity = 22.0;

uniform float planet_radius;
uniform float atmosphere_radius;

// Per-channel Rayleigh scattering coefficient, 1/m — the derived value, summed over the mix.
uniform vec3 rayleigh_coefficient;
uniform float rayleigh_scale_height;

// Mie is aerosols, not the species mix, so these three are named tuning constants rather than
// derivation — see SpacesimAtmosphereModel.
uniform float mie_coefficient;
uniform float mie_scale_height;
uniform float mie_anisotropy;


// Ray-sphere intersection for a sphere centred on the origin, given a **normalised** direction.
// When the ray misses, x > y — which is how a miss is detected.
vec2 ray_sphere(vec3 origin, vec3 direction, float radius) {
	float b = 2.0 * dot(direction, origin);
	float c = dot(origin, origin) - (radius * radius);
	float d = (b * b) - 4.0 * c;
	if (d < 0.0) {
		return vec2(1e5, -1e5);
	}
	return vec2((-b - sqrt(d)) * 0.5, (-b + sqrt(d)) * 0.5);
}


// The scattering integral, in the same units as glsl-atmosphere's `atmosphere()`: a radiance that
// `sun_intensity` scales. `r0` is the eye relative to the body's centre and `r` a unit ray, both in
// the same space.
vec3 sky_color(vec3 r, vec3 r0, vec3 pSun) {
	// Where the ray enters and leaves the air. A ray that misses the atmosphere entirely is black.
	vec2 span = ray_sphere(r0, r, atmosphere_radius);
	if (span.x > span.y) {
		return vec3(0.0);
	}
	// And it stops at the planet, so the ground is never integrated through.
	span.y = min(span.y, ray_sphere(r0, r, planet_radius).x);
	float step_size = (span.y - span.x) / float(I_STEPS);

	// The phases. Rayleigh is symmetric front-to-back; Mie is forward-peaked by `mie_anisotropy`.
	float mu = dot(r, pSun);
	float mumu = mu * mu;
	float gg = mie_anisotropy * mie_anisotropy;
	float phase_rayleigh = 3.0 / (16.0 * PI_F) * (1.0 + mumu);
	float phase_mie = 3.0 / (8.0 * PI_F) * ((1.0 - gg) * (mumu + 1.0))
		/ (pow(1.0 + gg - 2.0 * mu * mie_anisotropy, 1.5) * (2.0 + gg));

	vec3 total_rayleigh = vec3(0.0);
	vec3 total_mie = vec3(0.0);
	float depth_rayleigh = 0.0;
	float depth_mie = 0.0;
	float t = span.x;

	for (int i = 0; i < I_STEPS; i++) {
		// Sample the middle of the step, which is what glsl-atmosphere does.
		vec3 position = r0 + r * (t + step_size * 0.5);
		float height = length(position) - planet_radius;

		// Optical depth for this step: density falls off exponentially with height, so the whole
		// density gradient IS these two lines — no texture, no extra pass.
		float step_rayleigh = exp(-height / rayleigh_scale_height) * step_size;
		float step_mie = exp(-height / mie_scale_height) * step_size;
		depth_rayleigh += step_rayleigh;
		depth_mie += step_mie;

		// How much sun reaches this sample: march toward the star and accumulate the same way.
		float sun_step = ray_sphere(position, pSun, atmosphere_radius).y / float(J_STEPS);
		float sun_depth_rayleigh = 0.0;
		float sun_depth_mie = 0.0;
		float s = 0.0;
		for (int j = 0; j < J_STEPS; j++) {
			float sun_height = length(position + pSun * (s + sun_step * 0.5)) - planet_radius;
			sun_depth_rayleigh += exp(-sun_height / rayleigh_scale_height) * sun_step;
			sun_depth_mie += exp(-sun_height / mie_scale_height) * sun_step;
			s += sun_step;
		}

		// Blue is extinguished and re-scattered more than red — which is the entire reason the sky
		// is blue, and why the coefficient is per-channel.
		vec3 attenuation = exp(-(mie_coefficient * (depth_mie + sun_depth_mie)
			+ rayleigh_coefficient * (depth_rayleigh + sun_depth_rayleigh)));

		total_rayleigh += step_rayleigh * attenuation;
		total_mie += step_mie * attenuation;
		t += step_size;
	}

	return phase_rayleigh * rayleigh_coefficient * total_rayleigh
		+ phase_mie * mie_coefficient * total_mie;
}


void fragment() {
	// `VERTEX` here is the fragment in view space, and the camera is the origin of view space — so the
	// ray direction is free, exactly as it would be in a sky shader.
	vec3 r = normalize(VERTEX);
	// `w = 0` rotates without translating, so a coordinate of 1.5e11 m contributes only its direction.
	vec3 r0 = (VIEW_MATRIX * vec4(eye_offset, 0.0)).xyz;
	vec3 pSun = normalize((VIEW_MATRIX * vec4(sun_direction, 0.0)).xyz);

	ALBEDO = sky_color(r, r0, pSun) * sun_intensity;
	ALPHA = 1.0;
}
