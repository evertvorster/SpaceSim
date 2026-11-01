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
// **THE COLOUR IS A DEPTH RAMP, not one albedo.** This is the shape the sea had when it was a separate layer
// (`2721c2b`), and it is the shape that worked: Evert, 2026-11-02: *"the shader that we used to have as a part of the
// land surface a long time ago... was not too bad. Have a look at the shape of that was."*
//
// The reasoning in that file is worth keeping verbatim: *"the ocean might be transparent, but it has a super-high
// absorption, so realistically we won't see anything below a couple of metres... drawing it as colour gets the picture
// without a single transparent pixel."* One flat albedo of 0.06 is what made this sea black — a real shallow sea is
// BRIGHT, because what you see is the bottom a metre down.
uniform vec3 shallow_color = vec3(0.2, 0.5, 0.5);
uniform vec3 deep_color = vec3(0.02, 0.06, 0.15);
uniform float shallow_metres : hint_range(0.1, 50.0) = 5.0;
uniform float deep_metres : hint_range(10.0, 10000.0) = 3000.0;
uniform float ocean_roughness : hint_range(0.0, 1.0) = 0.14;
uniform float ocean_specular : hint_range(0.0, 1.0) = 0.45;

// **THE SKY THE SEA REFLECTS, because a sea is mostly a mirror and not a paint.** Evert, 2026-11-01: *"the water
// looked too dark, I did not get any reflections of the sun on it."*
//
// Both are the same fault: the sea was being drawn as a **dark diffuse surface**. `ocean_color` is the liquid's band
// colour normalised to its own albedo — about 0.06 for water, which is *correct* and almost black once the light loop
// multiplies it — and a dielectric with `metallic = 0` has nothing else to give. What a real sea does is reflect the
// sky at grazing angles and drink it at the zenith, which is Fresnel, and no amount of albedo produces it.
//
// `sky_tint` is the air's own hue — the Rayleigh coefficients, which are the sky's colour by derivation rather than
// a blue someone picked — published by the host. `reflection_gain` is the one free number.
uniform vec3 sky_tint = vec3(0.20, 0.42, 0.90);
uniform float reflection_gain : hint_range(0.0, 2.0) = 1.0;

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
	// **No discard: the coastline IS the intersection, and the depth test makes it.** The land is opaque and drawn
	// first, the water is transparent and drawn after, so where the ground stands above sea level the water fragment
	// is behind it and Godot's depth test rejects it — no rule of ours needed. Evert, 2026-11-01: *"why is
	// coastlines handled seperately? They should just be where the water and land intersect?"* He is right, and
	// `discard` here would be a second mechanism deciding what the depth test already decides.
	float depth = max((sea_level - ground) * max(field_amplitude, 1.0e-6), 0.0);

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
	vec3 normal = normalize(up - lean * fade);   // body space — see where it is written below

	// ===== THE COLOUR, AND HOW MUCH OF THE FLOOR SHOWS ==================================
	// **The shallow/deep ramp, in metres** — the same two ends the old layer used.
	float fill = smoothstep(shallow_metres, deep_metres, depth);
	vec3 water = mix(shallow_color, deep_color, fill);
	// **A little transparent, and only where it is really shallow** (Evert, 2026-11-01) — the ramp does most of the
	// work, so the alpha is a small concession on top rather than the mechanism: nearly opaque a couple of metres
	// down, and never clear enough to lose the water's own surface at the edge.
	float alpha = mix(shore_alpha, 1.0, smoothstep(0.0, shallow_depth, depth));
	ALBEDO = water;
	ALPHA = alpha;
	// **`NORMAL` IS VIEW SPACE IN THE FRAGMENT STAGE.** The land can write a body-space direction into it because it
	// does so in `vertex()`, where `NORMAL` is model space; here the same assignment made the lighting depend on where
	// the camera was POINTING — Evert, 2026-11-02: *"there seems to be a light spot that moves around when I rotate
	// rather than translate the camera"* — and it also darkened the whole sea, because a body-space vector read as a
	// view-space one faces away from the sun most of the time. The transform is what makes it a normal again.
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(normal, 0.0)).xyz);
	ROUGHNESS = mix(0.02, ocean_roughness, clamp(swell / max(rough_wave, 0.001), 0.0, 1.0));
	SPECULAR = ocean_specular;
	// **Fresnel, in the shader because there is no sky probe to reflect yet.** Grazing view -> the sky, straight down
	// -> the water's own dark colour: `pow(1 - cos, 5)` is the dielectric's own law, and it is what makes a sea read
	// as a surface rather than as a blue floor.
	float facing = clamp(dot(normal, eye_direction), 0.0, 1.0);
	float fresnel = 0.02 + 0.98 * pow(1.0 - facing, 5.0);
	// Written into `EMISSION` for the same reason the deck's base is: it is light arriving from the sky, not light
	// the engine can compute from a light source. It is not multiplied by `AO` either, which is the point — the sky
	// above still reaches the water when the ground beside it is in shadow.
	EMISSION = sky_tint * fresnel * reflection_gain;

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
