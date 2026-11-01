shader_type spatial;
// **The sea: a LEVEL over the ground, drawn on the ground's own lattice.**
//
// Evert, 2026-11-01: *"lets do the ocean. We can use the sphere that we subdivide so we know we are lined up on the
// triangle faces. Material and reflectivity needs to be proper for earth and different planets."*
//
// A liquid is a level — that is why the sea was never a band in the surface ramp (it was, briefly, and it painted a
// blue ocean on the LAND shader: no level, no depth, nothing transparent). So this is a sphere at the sea level datum,
// wearing the same triangles as the ground beneath it, and the coastline is decided per PIXEL by the same field
// function the ground uses — not by clipping triangles, which would facet the shore at whatever the walk's current
// subdivision happens to be.
//
// **What makes it a sea rather than a blue sheet**: the ground's height under a fragment IS the water's depth, so
// transparency, the colour's deepening and (later) anything depth-dependent fall out of one subtraction. Evert:
// *"it needs to be a little transparent, but only for where the water is really shallow."*
//
// **Derived, not authored.** The colour, reflectance, roughness and specular all come from the liquid's own
// `SpacesimSpecies` through `SpacesimSurfaceModel` — Earth's water and Titan's methane seas are the same shader with
// different numbers, and nothing Earth-specific is written here.
render_mode blend_mix, cull_back, diffuse_burley, specular_schlick_ggx, depth_draw_opaque;

#include "res://addons/spacesim/system/model/noise.gdshaderinc"
#include "res://addons/spacesim/system/model/surface_field.gdshaderinc"
// **The same three includes the land takes**, or the sea and the shore cannot agree: whether the body occludes the
// star, what the air took on the way in, and a cloud's shadow.
#include "res://addons/spacesim/render/star_transmission.gdshaderinc"
#include "res://addons/spacesim/render/cloud_coverage.gdshaderinc"
#include "res://addons/spacesim/render/deck_shadow.gdshaderinc"

// **The datum, in field units** — `SpacesimSurfaceModel.sea_level()` through the measured quantiles. It is what the
// ground's displaced vertices measure from, so the two layers cannot disagree about where the waterline is.
uniform float sea_level = 0.0;
uniform float planet_radius = 6371000.0;
uniform vec3 patch_origin = vec3(0.0);
// `body_eye_local`, `body_sun` and `air_altitude` come from the includes below — the same declarations the land
// shares, so the two cannot be given different values.
uniform float pixel_angle = 0.001;
// **Metres per field unit**, which is what turns a height difference into a depth. Published from
// `SpacesimSurfaceField.Plan.amplitude` — the same number the vertex translation multiplies by, so the sea's depth
// and the land's displacement are one quantity.
uniform float field_amplitude = 1.0;

// **The liquid's own numbers**, from `SpacesimSurfaceModel.band_color` and `band_shading`, with the colour's
// luminance set to its albedo the way every surface band is drawn.
uniform vec3 ocean_color = vec3(0.02, 0.06, 0.12);
uniform float ocean_roughness : hint_range(0.0, 1.0) = 0.08;
uniform float ocean_specular : hint_range(0.0, 1.0) = 0.5;

// **How deep the water has to be before it stops showing the floor**, in metres. Evert: *"a little transparent, but
// only for where the water is really shallow."* Fully opaque by this depth, and never fully clear even at the water's
// edge — a sea has a surface as well as a bottom.
uniform float shallow_depth : hint_range(0.1, 20.0) = 2.5;
// The floor's visible share at zero depth. Not 0: the water itself still reflects and scatters at the shoreline.
uniform float shore_alpha : hint_range(0.0, 1.0) = 0.45;

// ===== THE SEA'S STATE ==========================================================
//
// **Mostly calm, with a few rough patches and large smooth ones.** Evert, 2026-11-01: *"mostly calm, average of 0.5m
// waves, some patches might be up to 7m waves, but also large patches smooth."*
//
// Two crossed sines at incommensurate frequencies give patches hundreds of kilometres across with no noise function
// and no texture: the field is smooth, has no aliasing of its own, and the same patch is in the same place from every
// altitude. It is a *weather pattern* rather than a spectrum, which is the right cheapness for a look that has to be
// read at a glance from orbit.
uniform float calm_wave : hint_range(0.0, 5.0) = 0.5;
uniform float rough_wave : hint_range(0.0, 20.0) = 7.0;
// Where in [0,1] the patch field starts and finishes raising the sea. Below `patch_calm` it is `calm_wave`
// everywhere; above `patch_rough` it is `rough_wave`. Most of the world sits below the first edge, which is what
// "mostly calm" means as a number.
uniform float patch_calm : hint_range(0.0, 1.0) = 0.55;
uniform float patch_rough : hint_range(0.01, 1.0) = 0.85;

varying vec3 unit_position;

void vertex() {
	// The direction from the body's centre — the lattice carries metres from a near-eye origin, so the origin is
	// what turns a position back into a direction.
	unit_position = normalize(VERTEX + patch_origin);
}


// **The patch field**: two crossed sines, in [0,1]. Large, smooth, and identical everywhere for a given direction.
float sea_patch(vec3 up) {
	float a = sin(dot(up, vec3(3.1, 5.7, 2.3)) * 2.1);
	float b = sin(dot(up, vec3(-7.3, 1.9, 4.7)) * 1.3 + 1.7);
	float c = sin(dot(up, vec3(1.1, -4.3, 8.9)) * 0.7 + 4.1);
	return clamp(0.5 + 0.28 * a + 0.16 * b + 0.06 * c, 0.0, 1.0);
}


void fragment() {
	vec3 up = unit_position;
	vec3 eye_direction = normalize(body_eye_local - up);
	float footprint_angle = pixel_angle / max(dot(up, eye_direction), 0.02);

	// ===== THE FLOOR, AND THEREFORE THE DEPTH ============================================
	//
	// The same function the ground evaluates, at the same footprint, so the coastline this shader draws is the
	// coastline the ground's own vertices were translated to. One field, one answer.
	SurfacePlan plan = surface_plan();
	float ground = surface_height(up, plan, footprint_angle);
	if (ground > sea_level) {
		// Land: the ground layer draws it, and there is nothing here.
		discard;
	}
	float depth = (sea_level - ground) * max(field_amplitude, 1.0e-6);

	// ===== THE SURFACE ===================================================================
	//
	// **Waves are a normal, not a displacement.** A level is a level: moving vertices here would make the sea and the
	// ground two different shapes, and the depth at a fragment would describe geometry that is not drawn. The slope is
	// `amplitude x wavenumber`, which is what makes a 7 m swell read as rough rather than as a 7 m hill.
	float patch = sea_patch(up);
	float swell = mix(calm_wave, rough_wave, smoothstep(patch_calm, patch_rough, patch));
	// Three directions, metres on the sphere's surface, so a wavelength is a wavelength rather than an angle.
	vec3 p = up * planet_radius;
	float slope = 0.0;
	vec3 lean = vec3(0.0);
	// Long swell first (its wavelength scales with the amplitude a real sea has), then the short chop on top.
	float w1 = mix(60.0, 220.0, clamp(swell / max(rough_wave, 0.001), 0.0, 1.0));
	for (int i = 0; i < 3; i++) {
		vec3 dir = normalize(vec3(float(i) * 2.3 + 0.7, 1.0 - float(i) * 0.4, 3.1 - float(i) * 1.1));
		float wavenumber = TAU / mix(w1, w1 * 0.35, float(i) * 0.5);
		float phase = dot(p, dir) * wavenumber + float(i) * 2.0;
		// The slope a sine of amplitude `swell` contributes: `swell * wavenumber * cos(...)`. Divided by the number of
		// waves so three of them do not add up to three times the amplitude.
		float amount = swell * wavenumber * cos(phase) / 3.0;
		lean += dir * amount;
		slope += abs(amount);
	}
	// **Band-limited by the pixel**, so a distant sea is a smooth sheet rather than a moire of chop: the component is
	// faded out once its wavelength approaches the pixel's own footprint on the water.
	float pixel_metres = max(depth * 0.0 + footprint_angle * planet_radius * 2.0, 0.05);
	float fade = 1.0 - smoothstep(0.15, 0.6, pixel_metres / max(w1 * 0.35, 1.0));
	vec3 normal = normalize(up - lean * fade);

	// ===== THE COLOUR, AND HOW MUCH OF THE FLOOR SHOWS ==================================
	float alpha = mix(shore_alpha, 1.0, smoothstep(0.0, shallow_depth, depth));
	ALBEDO = ocean_color;
	ALPHA = alpha;
	NORMAL = normal;
	ROUGHNESS = mix(0.02, ocean_roughness, clamp(swell / max(rough_wave, 0.001), 0.0, 1.0));
	SPECULAR = ocean_specular;

	// **The same light path the land takes.** The star's own occlusion, the air on the way in (brightness into `AO`
	// because a specular is built from the light, hue into the albedo), and a cloud's shadow on the water.
	vec3 air_through = star_air_transmittance(up, body_sun, air_altitude, planet_radius);
	float air_brightness = dot(air_through, vec3(0.2126, 0.7152, 0.0722));
	ALBEDO *= air_through / max(air_brightness, 1.0e-3);
	AO = star_transmission(up, body_sun, footprint_angle) * air_brightness;
	AO_LIGHT_AFFECT = 1.0;
	if (deck_shadow_present()) {
		AO *= deck_shadow_factor(up, planet_radius, 0.0);
	}
}
