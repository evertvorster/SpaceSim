shader_type spatial;
// `cull_disabled` because one shell has to serve both sides of itself: from space you see the deck's
// TOP, and from the ground the same sphere is your ceiling. Drawing both faces lets depth decide —
// the far side is behind the planet from outside, and behind nothing from inside. It also means a
// grazing ray at the limb crosses the shell twice and blends twice, which is roughly what a long
// tangential path through cloud should do.
render_mode blend_mix, cull_disabled, specular_disabled;

// The cloud deck: one shell of noise, drawn where the noise says there is cloud.
//
// ---------------------------------------------------------------- WHAT IT IS NOT
//
// **Not additive.** The air is `blend_add` because a sky is something you look *through*; a deck is
// something you look *at*, and it has to **occlude** what is behind it. That is the whole reason this
// is a second material rather than another term in the atmosphere's.
//
// **Not at `radius * 1.012`.** That is a fraction of the body, and it is what made the previous deck
// the outermost silhouette of every world — 76 km above Earth against a real cloud top of 10–12.
// **The altitude is derived**: it is the condensation level, so it is a real height above a real
// surface, and it moves with the air rather than with the planet's size.
//
// ---------------------------------------------------------------- COVERAGE
//
// **`threshold` is a PERCENTILE of this field, not `1 - cover`.** A threshold gives the fraction of the
// field *above* it, which is the authored fraction only if the distribution is known — so the host
// measures the field and hands over the percentile, and a test asserts that the achieved coverage is
// the requested one. Assuming it was what made the first deck's coverage a guess.
//
// **The field is sampled on the UNIT SPHERE, and only mapped into the texture — never scaled by it.**
// Sampling in world metres puts every pixel in an arbitrary voxel (a field of dots), and *scaling* the
// direction before sampling wraps the texture, which at scale 4 repeats as a visible 8x8 grid of
// patches. `direction * 0.25 + 0.5` uses a quarter of the texture and cannot wrap; the detail comes
// from what the texture itself holds. Same mapping as the surface shader, and the same two traps.

// **These two are LINEAR, and the host has already scaled the luminance to the deck's measured albedo.**
// Not `source_color`, deliberately: with the decode left to Godot the drawn reflectance would be the
// palette's `level^2.2` rather than the number `bond_albedo` uses, which is the whole fault this avoids.
uniform vec3 cloud_color = vec3(1.0);
// The thin edge and the shadowed underside. The host derives it from `cloud_color` rather than picking
// it, so a deck keeps its identity while gaining structure.
uniform vec3 edge_color = vec3(0.7);
uniform float threshold : hint_range(0.0, 1.0) = 0.5;
uniform float softness : hint_range(0.001, 0.5) = 0.06;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
uniform float noise_scale : hint_range(0.1, 2.0) = 1.0;
uniform vec3 noise_offset = vec3(0.0);
uniform sampler3D noise_field : filter_linear, repeat_enable;

// ===== THE AIR THIS DECK SITS UNDER ================================================
//
// **A cloud is a surface under the air, so it is lit and seen through it exactly as the ground is.**
// Without this the deck is lit by the star's full beam and seen unattenuated — which is what made it
// read as a flat white lid from space, where 100 km of air should both dim it and add its own glow.
// It is the same block `body_surface.gdshader` carries, off the same uniforms, from the same call.
uniform float planet_radius = 1.0;
uniform float atmosphere_radius = 0.0;
uniform vec3 rayleigh_coefficient = vec3(0.0);
uniform float rayleigh_scale_height = 1.0;
uniform vec3 absorption_coefficient = vec3(0.0);
uniform float mie_coefficient = 0.0;
uniform float mie_scale_height = 1.0;
uniform vec3 eye_offset = vec3(0.0);
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 sky_illuminance = vec3(0.0);
uniform float sky_diffuse_max = 0.0;
uniform float sky_down_fraction = 0.0;
uniform float sky_min_cos_zenith = 1.0;
uniform float sky_shadow_softness = 1.0;
uniform float reference_lux = 100000.0;

#include "res://addons/spacesim/render/air.gdshaderinc"

// Model space, the offset from the body's centre — which for a unit sphere IS its direction. Captured
// in `vertex()` because **`VERTEX` inside `fragment()` is in VIEW space**.
varying vec3 local_position;


void vertex() {
	local_position = VERTEX;
}


// The field at a unit direction, shifted so each body gets its own place in it. Identical to the
// surface shader's, and it has to be: the deck's shadow is sampled from this same field.
float field(vec3 direction) {
	return texture(noise_field, direction * (0.25 * noise_scale) + vec3(0.5) + noise_offset).r;
}


void fragment() {
	vec3 p = normalize(local_position);
	float height = field(p);
	// Coverage, with a soft edge of its own width so the deck has a boundary rather than a stencil.
	float cover = smoothstep(threshold - softness, threshold + softness, height);
	// The edge of a cloud is its thinnest part, so the same number drives colour and alpha: a soft
	// boundary is also a thin one, which is what makes a deck read as cloud rather than as cut paper.
	ALBEDO = mix(edge_color, cloud_color, cover);
	ALPHA = cover * opacity;
	ROUGHNESS = 0.9;

	// **The air above, exactly as the ground sees it.** The star's beam is thinned on the way down and the
	// light the cloud sends back on the way out, and the sky puts its own light on it. The point is at the
	// deck's own radius, so the columns are the ones above *the deck* and not above the ground.
	if (atmosphere_radius > planet_radius) {
		vec3 r0 = (VIEW_MATRIX * vec4(eye_offset, 0.0)).xyz;
		vec3 point = VERTEX + r0;
		vec3 to_sun = normalize((VIEW_MATRIX * vec4(sun_direction, 0.0)).xyz);
		float rayleigh_column = air_column(
			point, to_sun, planet_radius, atmosphere_radius, rayleigh_scale_height
		);
		float mie_column = air_column(
			point, to_sun, planet_radius, atmosphere_radius, mie_scale_height
		);
		vec3 to_eye = normalize(-point);
		float view_rayleigh = air_column(
			point, to_eye, planet_radius, atmosphere_radius, rayleigh_scale_height
		);
		float view_mie = air_column(
			point, to_eye, planet_radius, atmosphere_radius, mie_scale_height
		);
		vec3 sun_transmittance = exp(
			-(rayleigh_coefficient + absorption_coefficient) * rayleigh_column
				- vec3(mie_coefficient * mie_column)
		);
		vec3 view_transmittance = exp(
			-(rayleigh_coefficient + absorption_coefficient) * view_rayleigh
				- vec3(mie_coefficient * view_mie)
		);
		vec3 cloud_albedo = ALBEDO;
		ALBEDO = cloud_albedo * sun_transmittance * view_transmittance;
		// And the sky's own light on the cloud, which at a deck's altitude is the same law as on the ground.
		vec3 normal_view = normalize((VIEW_MATRIX * vec4(normalize(local_position), 0.0)).xyz);
		float cos_zenith = dot(normal_view, to_sun);
		float ratio = planet_radius / atmosphere_radius;
		float air_horizon = -sqrt(max(1.0 - ratio * ratio, 0.0));
		float lit = clamp((cos_zenith - air_horizon) / max(sky_shadow_softness, 1.0e-4), 0.0, 1.0);
		vec3 tau_vertical = (rayleigh_coefficient + absorption_coefficient) * rayleigh_scale_height
			+ vec3(mie_coefficient * mie_scale_height);
		float mu = max(abs(cos_zenith), sky_min_cos_zenith);
		vec3 removed = min(1.0 - exp(-tau_vertical / mu), vec3(sky_diffuse_max));
		vec3 sky_lux = sky_illuminance * removed * sky_down_fraction * lit;
		EMISSION += cloud_albedo * view_transmittance * sky_lux / max(reference_lux, 1.0);
	}
}
