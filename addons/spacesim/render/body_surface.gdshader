shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://addons/spacesim/render/air.gdshaderinc"

// The surface layer. What a body is *made of* arrives as colours; this turns one flat albedo into a
// planet by varying it over a noise field and giving the variation relief.
//
// **THE NOISE IS SAMPLED ON THE UNIT SPHERE, NOT IN WORLD METRES.** That is not a detail — sampling
// world position makes every pixel land on an arbitrary voxel, because a planet is millions of metres
// across and the field is 64 voxels: adjacent pixels differ by ~64 km, which is ~160,000 texture units
// at any usable scale. The result is a dense cloud of dots rather than structure, and float32 spacing
// at astronomical coordinates (~32,768) makes it worse. Planet 3D normalises for exactly this reason.
// A unit direction puts adjacent pixels 0.06 of a voxel apart instead.
//
// The local position is captured in `vertex()` because **`VERTEX` inside `fragment()` is in VIEW
// space**, not model space.

// **THE FIELD IS SAMPLED ONCE ACROSS THE SPHERE.** The direction spans ±1 per axis, so multiplying it
// by a scale before sampling wraps the texture that many times — at scale 4 the cloud deck repeated
// as a visible 8x8 grid of patches. Instead the unit direction is mapped into the middle of the
// texture's [0,1] range, and the *detail* comes from how much noise the texture itself holds.
//
// Two other things are load-bearing and were each wrong once: sampling in world metres at all (every
// pixel lands in an arbitrary voxel — a field of dots), and **`VERTEX` inside `fragment()` is VIEW
// space**, so the model-space position is captured in `vertex()` and passed here.

uniform vec3 base_color : source_color = vec3(0.5, 0.5, 0.5);
uniform vec3 detail_color : source_color = vec3(0.5, 0.5, 0.5);
// Where the blend sits, and how soft it is: a two-stop height gradient.
uniform float detail_mix : hint_range(0.0, 1.0) = 0.5;
uniform float detail_softness : hint_range(0.001, 0.5) = 0.15;
// How far into the texture the sphere is mapped. 1.0 uses a quarter of it, which cannot wrap; above
// about 2.0 the sampling starts to repeat and the surface tiles.
uniform float noise_scale : hint_range(0.1, 2.0) = 1.0;
// The knob for how pronounced the relief is. It multiplies a true gradient, so it is small.
uniform float relief : hint_range(0.0, 0.5) = 0.05;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.9;
uniform float specular_value : hint_range(0.0, 1.0) = 0.2;
// A small per-body shift, so two bodies do not wear the same surface. Small because a large one walks
// the sample straight out of the texture and back into the tiling it was moved to avoid.
uniform vec3 noise_offset = vec3(0.0);
uniform sampler3D noise_field : filter_linear, repeat_enable;

// ===== THE AIR ABOVE THIS SURFACE =================================================
//
// **The light this surface is drawn in is the light that REACHES it.** The star's illuminance is
// measured at the top of the air, so the trip down is where it is lost: blue before red, and more of it
// the lower the sun is in the sky. Attenuating `ALBEDO` is the same statement for a diffuse surface —
// scaling the reflectance by the transmittance is scaling the light it sees, and the path back out is
// the next half of this.
//
// **The airless case is the degenerate one, not a branch.** Every default here leaves the column empty
// and the transmittance exactly 1, so one shader draws a rock and an air world and there is no second
// material to keep in step.
//
// The camera offset and the sun direction are the same two uniforms the shell gets, refreshed by the
// same per-frame call — so the surface and the sky over it cannot be told different things about where
// the sun is.
uniform float planet_radius = 1.0;
uniform float atmosphere_radius = 0.0;
uniform vec3 rayleigh_coefficient = vec3(0.0);
uniform float rayleigh_scale_height = 1.0;
// **Absorption removes light and gives none back.** It belongs in every extinction the surface sees —
// the beam coming down and the light going out — and in none of the emission.
uniform vec3 absorption_coefficient = vec3(0.0);
uniform float mie_coefficient = 0.0;
uniform float mie_scale_height = 1.0;
uniform vec3 eye_offset = vec3(0.0);
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);

// **The sky's own light on the ground.** The ground is lit by two things once there is air over it: the
// star's beam, thinned on the way down, and the air itself, which scatters some of that beam back at the
// ground. Without the second term a twilight surface is lit as if the sky above it were black.
//
// Every number here is a uniform, so the shader holds none of the derivation: `sky_illuminance` is the
// star's illuminance at the top of the air, `sky_diffuse_max` and the rest are
// `SpacesimAtmosphereModel`'s named constants.
uniform vec3 sky_illuminance = vec3(0.0);
uniform float sky_diffuse_max = 0.0;
uniform float sky_down_fraction = 0.0;
uniform float sky_min_cos_zenith = 1.0;
uniform float sky_shadow_softness = 1.0;
// What a sky irradiance is worth in this material's units: a white Lambertian under `100,000` lux renders
// as `1.0`, so an irradiance in lux becomes a radiance by dividing by it.
uniform float reference_lux = 100000.0;

// Model space: the offset from the body's centre.
varying vec3 local_position;

void vertex() {
	local_position = VERTEX;
}

// The field at a unit direction, shifted so each body gets its own place in it.
float field(vec3 direction) {
	return texture(noise_field, direction * (0.25 * noise_scale) + vec3(0.5) + noise_offset).r;
}

void fragment() {
	// One direction per surface point, and the same one for every pixel that shares it.
	vec3 p = normalize(local_position);
	float height = field(p);

	// Colour by height — the gradient, in its simplest honest form: two stops.
	float blend = smoothstep(detail_mix - detail_softness, detail_mix + detail_softness, height);
	ALBEDO = mix(base_color, detail_color, blend);
	ROUGHNESS = roughness_value;
	SPECULAR = specular_value;

	// Relief from the field's gradient, projected onto the surface so it perturbs the normal without
	// tilting it off the sphere.
	float e = 0.01;
	vec3 gradient = vec3(field(p + vec3(e, 0.0, 0.0)) - height,
		field(p + vec3(0.0, e, 0.0)) - height,
		field(p + vec3(0.0, 0.0, e)) - height) / e;

	vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	gradient -= world_normal * dot(gradient, world_normal);
	vec3 bumped = normalize(world_normal - gradient * relief);
	NORMAL = normalize((VIEW_MATRIX * vec4(bumped, 0.0)).xyz);

	// The air's own arithmetic, in the space the sky already does it in. `VERTEX` here is relative to the
	// camera, and the body's centre is `-r0`, so the point relative to the body's centre is `VERTEX + r0`.
	// The sun is a direction, so the `w = 0` transform rotates it without bringing in its translation.
	//
	// **The ground stops the ray, which is what makes the night side need no special case**: from a point
	// the sun cannot reach, the ray toward the sun meets the body almost immediately and the column comes
	// back empty, so the transmittance is 1 and the term is a no-op rather than a wrong answer.
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
		// **The light this surface sends back is thinned by the air it has to cross too**, which is the half
		// of the pair that makes a body seen from outside dimmer than its albedo would suggest.
		vec3 view_transmittance = exp(
			-(rayleigh_coefficient + absorption_coefficient) * view_rayleigh
				- vec3(mie_coefficient * view_mie)
		);
		vec3 surface_albedo = ALBEDO;
		ALBEDO = surface_albedo * sun_transmittance * view_transmittance;

		// **And the sky puts light back on it.** A point in the air's own shadow — past the ground's
		// terminator but under air the star can still reach — is lit from above, and that is what twilight
		// IS. The air's horizon is lower than the ground's by `sqrt(1 - (R / (R + h))^2)`, and the fade is
		// over that gap rather than at the local sunset.
		vec3 normal_view = normalize((VIEW_MATRIX * vec4(normalize(local_position), 0.0)).xyz);
		float cos_zenith = dot(normal_view, to_sun);
		float ratio = planet_radius / atmosphere_radius;
		float air_horizon = -sqrt(max(1.0 - ratio * ratio, 0.0));
		float lit = clamp((cos_zenith - air_horizon) / max(sky_shadow_softness, 1.0e-4), 0.0, 1.0);
		// The air's vertical optical depth, per channel: the same two species the column is made of, and
		// the absorption that joins the extinction.
		vec3 tau_vertical = (rayleigh_coefficient + absorption_coefficient) * rayleigh_scale_height
			+ vec3(mie_coefficient * mie_scale_height);
		float mu = max(abs(cos_zenith), sky_min_cos_zenith);
		vec3 removed = 1.0 - exp(-tau_vertical / mu);
		removed = min(removed, vec3(sky_diffuse_max));
		vec3 sky_lux = sky_illuminance * removed * sky_down_fraction * lit;
		EMISSION += surface_albedo * view_transmittance * sky_lux / max(reference_lux, 1.0);
	}
}
