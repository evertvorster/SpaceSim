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

// **The same three includes the land takes**, or the sea and the shore cannot agree: whether the body occludes the
// star, what the air took on the way in, and a cloud's shadow.
#include "res://addons/spacesim/render/star_transmission.gdshaderinc"
#include "res://addons/spacesim/render/cloud_coverage.gdshaderinc"
#include "res://addons/spacesim/render/deck_shadow.gdshaderinc"

// **The frame's own depth, because the floor is already drawn in it.** See the floor block below: the sea measures its
// own thickness against the surface in the depth buffer instead of evaluating the terrain field a second time. This is
// a `spatial` shader in the transparent queue, so the opaque depth behind it is exactly the planet.
uniform sampler2D depth_texture : hint_depth_texture;

// **The datum, in field units** — `SpacesimSurfaceModel.sea_level()` through the measured quantiles. It is what the
// ground's displaced vertices measure from, so the two layers cannot disagree about where the waterline is.
// **Gone from this shader on 2026-11-02**: the sea stopped asking the terrain field how far down the floor is and reads
// the frame's own depth instead, so `sea_level` and `field_amplitude` had no reader left. The land still translates its
// vertices by them; the water no longer needs to know.
uniform float planet_radius = 6371000.0;
uniform vec3 patch_origin = vec3(0.0);
// `body_eye_local`, `body_sun` and `air_altitude` come from the includes below — the same declarations the land
// shares, so the two cannot be given different values.
uniform float pixel_angle = 0.001;

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
// **The ramp ENDS where the transparency does.** Evert, 2026-11-02: *"once the ocean is deeper than a certain point,
// 15 meters or so, then we should not be able to see the surface below it at all, and it should just be its own color,
// reflecting."* It was 3000 m, which left the sea painted the bright shallow colour for the first three kilometres
// while `shallow_depth` had already made it fully opaque at fifteen — the floor invisible and the colour still saying
// otherwise. The two ends now share one scale: shallow at 5 m, the water's own colour from 15 m down.
uniform float deep_metres : hint_range(10.0, 10000.0) = 15.0;
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
//
// **15 m, not 2.5** — Evert, 2026-11-02: *"I have seen seawater clear up to 15m deep."* That is the honest scale: a
// dive over sand reads at fifteen metres, and the old value was the *ramp's* shallow end borrowed for transparency,
// which made the sea opaque at the depth where it is most translucent. The ramp's own shallow end (`shallow_metres`,
// 5 m) is a colour question and stays where it is.
uniform float shallow_depth : hint_range(0.1, 20.0) = 15.0;
// The floor's visible share at zero depth. Not 0: the water itself still reflects and scatters at the shoreline.
uniform float shore_alpha : hint_range(0.0, 1.0) = 0.45;

// ===== THE SEA'S STATE ==========================================================
//
// **Mostly calm, with a few rough patches and large smooth ones.** Evert, 2026-11-01: *"mostly calm, average of 0.5m
// waves, some patches might be up to 7m waves, but also large patches smooth."*
//
// **REDESIGNED 2026-11-02 as a sum of directional waves, and the reason is precision.** Two sampled-field versions
// came before this and both were wrong in a way only flight showed: the first evaluated an fbm four times per field
// to get a slope by central difference (28 octaves a pixel on top of the terrain field's 21), and the second took the
// slope from screen derivatives of a single evaluation, which speckled. The speckle was not the maths — it was the
// **coordinate**. A position on a 6,371 km sphere in float32 is quantised at **0.5 m**, so a 3 m capillary wave is
// six ULPs and its slope is quantisation noise; a difference quotient averaged that noise, a derivative amplified it.
// The ladder below is 512 m down to 64 m — 128 float32 steps per cycle at the finest, and nothing shorter is
// representable on a planet in this engine at all.
//
// What replaces it is what a sea actually is: **a sum of directional waves, evaluated analytically**. The normal is
// the exact slope of the surface that is described, so there is no sampling and therefore nothing to alias; the
// band-limit is per wave and is the same law the noise used. Everything below 64 m is the ROUGHNESS term's job, and
// that is where it belongs — chop the screen cannot resolve does not vanish, it widens the sun's image into a path.
uniform float calm_wave : hint_range(0.0, 5.0) = 0.5;
uniform float rough_wave : hint_range(0.0, 20.0) = 7.0;
// Where in [0,1] the patch field starts and finishes raising the sea. Below `patch_calm` it is `calm_wave`
// everywhere; above `patch_rough` it is `rough_wave`. Most of the world sits below the first edge, which is what
// "mostly calm" means as a number.
uniform float patch_calm : hint_range(0.0, 1.0) = 0.55;
uniform float patch_rough : hint_range(0.01, 1.0) = 0.85;
// The steepest a wave may lean, as a slope — about 19 degrees, the same ceiling the ground's relief uses.
const float MAP_TILT_LIMIT = 0.35;

// **The wave ladder.** Four directions and four sizes, and the size matters as much as the count.
//
// - **Equal slope per octave**: every wave leans by the same `slope` whatever its wavelength, so the picture is
//   scale-free — a sea rather than a corrugated roof. The amplitude is then `slope / k`, proportional to the
//   wavelength, which is how a real spectrum falls.
// - **The golden angle** turns each direction by 2.4000 rad, so no two are parallel and no lattice forms. Turning them
//   by the *patch field* as well means neighbouring weather leans differently, which is what stops the swell reading
//   as one machine.
// - `WAVE_BASE` is the longest and `WAVE_COUNT` halves it; 512 m down to 64 m.
const int WAVE_COUNT = 4;
const float WAVE_BASE = 512.0;
// How steep the whole ladder is at `rough_wave`: four waves at equal slope add up to about 0.24 in the worst phase
// agreement, against the 0.35 ceiling — so the clamp below is a guard, not the mechanism.
const float WAVE_GAIN = 0.7;
const float GOLDEN_ANGLE = 2.399963229728653;

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

	// ===== THE FLOOR, FROM THE FRAME ITSELF =================================================
	//
	// **The water's thickness is what is already drawn under this pixel**, not a second evaluation of the field.
	// Evert, 2026-11-02: *"the ocean shader is supposed to be on its own mesh. The surface of the planet must still be
	// below it, and actually shine through in areas where it is thin."* The planet IS drawn below — it is the opaque
	// pass, it is in the depth buffer, and `ALPHA` is a blend against it. So the column is `ground distance - water
	// distance` along this pixel's own ray: measured against the surface on screen rather than derived from a field
	// that has to agree with it.
	//
	// **No discard: the coastline IS the intersection, and the depth test makes it.** The land is opaque and drawn
	// first, the water is transparent and drawn after, so where the ground stands above sea level the water fragment
	// is behind it and Godot's depth test rejects it — no rule of ours needed. Evert, 2026-11-01: *"why is
	// coastlines handled seperately? They should just be where the water and land intersect?"* He is right.
	//
	// **What this deletes**: `surface_height` was the last 21 octaves this shader paid, and the land, the sea and the
	// decks were each evaluating the same five-octave field every frame. The sea no longer knows what the terrain is
	// made of at all — it only knows where the floor was drawn.
	//
	// **The risk, named**: the depth buffer is reversed-Z over a far plane set by `sky_reach` (hundreds of km), so its
	// resolution at 20 km is metres, not centimetres. If the shallows band proves coarse in flight, the fix is a
	// tighter far plane or a near-field pass — not a return to the field.
	float buffer_depth = texture(depth_texture, SCREEN_UV).r;
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, buffer_depth, 1.0);
	vec3 scene_point = scene_view.xyz / max(scene_view.w, 1.0e-9);
	// **The camera looks down -Z in view space**, so a distance is the negated z. `VERTEX` in the fragment stage is
	// this fragment in that same space, which is what makes the subtraction a length rather than a guess.
	float scene_distance = -scene_point.z;
	float water_distance = -VERTEX.z;
	float thickness = max(scene_distance - water_distance, 0.0);
	// **The vertical COLUMN, not the ray**: a pixel at the horizon looks through a hundred times more water than the
	// column beneath it, and the ramp is about the column.
	float depth = thickness * max(dot(eye_direction, up), 0.0);

	// ===== THE SURFACE ===================================================================
	//
	// **Waves are a normal, not a displacement.** A level is a level: moving vertices here would make the sea and the
	// ground two different shapes, and the depth at a fragment would describe geometry that is not drawn. The slope is
	// `amplitude x wavenumber`, which is what makes a 7 m swell read as rough rather than as a 7 m hill.
	float patch = sea_patch(up);
	float swell = mix(calm_wave, rough_wave, smoothstep(patch_calm, patch_rough, patch));
	// **The pixel's footprint ON THE WATER** — the eye's height plus this fragment's own depth, times the pixel's
	// angle. Not `angle x planet_radius`, which is the size of a pixel on a surface 6,371 km away and matches nothing.
	float eye_altitude_m = max((length(body_eye_local) - 1.0) * planet_radius, 0.0);
	float pixel_metres = max((eye_altitude_m + depth) * footprint_angle, 0.05);
	// Two directions in the surface's tangent plane, to lay the waves along.
	vec3 t1 = normalize(cross(up, abs(up.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	vec3 t2 = cross(up, t1);
	vec3 p = up * planet_radius;
	// **The slope every wave leans by**, from the equal-slope ladder. `slope × cos(phase)` is the exact derivative
	// of `amplitude × sin(phase)` with `amplitude = slope / k`, so the normal below is not an approximation of a
	// sampled surface — it IS the surface.
	float slope = swell * WAVE_GAIN * TAU / WAVE_BASE;
	vec3 lean = vec3(0.0);
	for (int i = 0; i < WAVE_COUNT; i++) {
		float wavelength = WAVE_BASE * exp2(-float(i));
		// **The band-limit, per wave and before any work is done**: an octave the pixel cannot resolve is skipped,
		// which is a real branch on a value that is uniform for the wave rather than a masked-out calculation.
		float fade = 1.0 - smoothstep(wavelength * 0.25, wavelength * 0.5, pixel_metres);
		if (fade <= 0.0) {
			continue;
		}
		float angle = GOLDEN_ANGLE * float(i) + patch * 1.7;
		vec3 dir = t1 * cos(angle) + t2 * sin(angle);
		lean += dir * (slope * cos(TAU * dot(dir, p) / wavelength) * fade);
	}
	if (length(lean) > MAP_TILT_LIMIT) {
		lean *= MAP_TILT_LIMIT / length(lean);
	}
	vec3 normal = normalize(up - lean);   // body space — see where it is written below

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
	// **What the pixel cannot resolve does not disappear — it widens the lobe.** A distant sea has the same slope
	// variance as a near one, but sampled coarser; the honest cheap version is a rougher specular once the footprint
	// passes the shortest wave's own resolving scale, so the sun's image spreads into a path instead of a point. This
	// is what makes the glint read as a *range* near the horizon — and since the ladder is where the waves END, this
	// is also where the detail the ladder cannot carry is handed over. Evert, 2026-11-02: *"I expected a wider range
	// of glinting near the horizon."*
	float finest = WAVE_BASE * exp2(-float(WAVE_COUNT - 1));
	float unresolved = clamp(pixel_metres / max(finest * 0.5, 1.0), 0.0, 1.0);
	ROUGHNESS = mix(
		mix(0.02, ocean_roughness, clamp(swell / max(rough_wave, 0.001), 0.0, 1.0)),
		max(ocean_roughness, 0.45),
		unresolved
	);
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
