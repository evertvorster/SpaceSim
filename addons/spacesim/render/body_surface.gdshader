shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// **The field, in a fragment shader.** `noise.gdshaderinc` is FastNoiseLite in GLSL with no `shared` memory —
// which is exactly what makes it legal here — and `surface_field.gdshaderinc` is the same generator the bake
// compiles, so the detail below the map's texel belongs to the map's spectrum rather than being a second
// geology. The include is the whole mechanism: one field, two compilers.
#include "res://addons/spacesim/system/model/noise.gdshaderinc"
#include "res://addons/spacesim/system/model/surface_field.gdshaderinc"

// **The surface layer: a height field, a colour ramp, and a sea.**
//
// A surface is not a cloud, and this is its own shader rather than the deck's: opaque, culled, lit, with a
// specular lobe — no `blend_mix`, no `cull_disabled`, no `specular_disabled`, no coverage threshold and no
// veil. What it takes from the deck is three *mechanisms* — the equirect mapping, the footprint fade and the
// per-body map — and none of its render modes.
//
// ---------------------------------------------------------------- WHAT IT IS GIVEN
//
// **Nothing here derives anything.** The heights are `SpacesimSurfaceField`'s, baked by
// `SpacesimSurfaceGpu`; the colours are `SpacesimSurfaceModel.bands()`'s, with each band's luminance set to
// its own albedo; the sea level is a percentile of the map's own distribution, measured by
// `SpacesimSurfaceMaps`. The shader places them on the sphere and shades them.
//
// ---------------------------------------------------------------- ONE MAP, AND WHY THAT IS SAFE
//
// **Everything drawn comes from `height_map`**, the map that refines as the eye approaches. An earlier version
// of this shader took the ocean mask and the colour bands from a separate, fixed-width coarse map, on the
// theory that a refining map would make every shore move outward as detail arrived. **That reasoning was
// wrong, and it cost the picture**: it is true only when the threshold is a *percentile of the map being
// read*, and this one is not — the sea level is an absolute **value**, so any map can threshold it and the
// coast lands in the same place in the field's own terms, just at higher resolution. Locking the colour to a
// fixed 1,024-wide map bought a stability the value comparison already had, and paid for it with **39 km
// texels at every distance** — a planet drawn at a seventh of the screen's resolution from low orbit, which
// reads as a featureless ball.
//
// So: one sampler here. The coarse bake still exists, and its job is the one thing a formula cannot do —
// **measure** the field's distribution — and that measurement is a number on the host, not a texture here.
//
// ---------------------------------------------------------------- THE RELIEF IS A SHADING TRICK
//
// A real planet's relief is 0.14 % of its radius, so its true slopes are a fraction of a degree and the
// shading they produce is invisible at any distance. `relief_exaggeration` is the named concession: the
// normal is tilted by the height gradient times it. **The silhouette does not change** — that is the mesh's
// business, and displacement is its own rung.

// **No `mipmaps` flag on these**: Godot picks a lod from the screen-space derivatives of the sampling
// coordinates, which on an equirect map is correct except at the poles, where the longitude derivative blows
// up and the map is read at its coarsest levels. That failure mode is *blur*, which is the safe direction,
// and the fine detail at the poles comes from the ladder rather than from the map.
uniform sampler2D height_map : filter_linear, repeat_enable, hint_default_black;
// The colour ramp: **1-D, indexed by field value over [-1, 1]**, built from the derived bands and the
// measured quantiles. Clamped, because a value past either end is a coast or a peak and not a wrap.
uniform sampler2D colour_ramp : filter_linear, repeat_disable, hint_default_black;

// ===== THE LADDER =================================================================================
//
// Everything the map cannot hold: the field's own generator sampled below the map's nyquist, with each rung
// faded by what a pixel can resolve. **The numbers are the plan's**, handed over by the host, so the detail is
// the same field the bake drew and not a second geology — see `surface_field.gdshaderinc`.
uniform int detail_octaves = 0;
uniform int detail_seed = 0;
uniform float detail_gain = 0.5;
uniform float detail_lacunarity = 2.0;
// The feature size the ladder starts at, in radians on the unit sphere — two texels of the map in hand.
uniform float detail_feature = 0.0;
// How much the detail moves the *colour*, as a fraction of the band's own — zero-mean, so the drawn average
// cannot drift away from the measured distribution the bands were placed with.
uniform float detail_variation : hint_range(0.0, 1.0) = 0.0;
// How much the detail tilts the normal, per unit of height difference across a pixel. A look number, and the
// one place the ladder's relief is calibrated.
uniform float detail_relief = 0.0;
// And how much it moves the *water*, which is a much smaller number: a sea with hills in it is the one thing
// that reads as wrong at any distance.
uniform float wave_relief = 0.0;
// **Where the detail's shadows are allowed to exist, in metres per pixel.** Evert, 2026-10-19: *"we don't
// actually need to see the shadows of fine detail until we are very close."* Past `relief_far` a pixel covers
// more ground than a bump is wide, and what the bump does then is not shading — it is moiré toward the horizon
// and black speckle where a sub-pixel slope is drawn as a pit. Full strength inside `relief_near`, gone by
// `relief_far`.
uniform float relief_near = 5.0;
uniform float relief_far = 60.0;
// **A ceiling on the tilt, in the same units as the gradient.** A bump's dark side drawn as absolute black is
// the missing air as much as the relief — with no sky above it, nothing lifts a shadow — so a normal may lean
// only so far before the fiction becomes a hole.
uniform float relief_max_tilt = 0.6;

// **Where the sea is**, in field units — `value_at(ocean_fraction)` off the measured quantiles. Zero until a
// map lands, which draws a neutral datum rather than a wrong ocean.
uniform float sea_level = 0.0;
// The field's own value times this is metres, and the metres are what the normal needs. From the plan.
uniform float field_amplitude = 1.0;
uniform float planet_radius = 1.0;
// How much the normal is tilted by the gradient — see the header. The one number here that is a look rather
// than a derivation, and it is a *uniform* so the host owns it.
uniform float relief_exaggeration = 12.0;
// The detail map's width, which is what turns a texel into an angle.
uniform int map_width = 1024;


// Shading by phase, two pairs of numbers in one place. **A liquid is glossy** and its sun glint is what makes
// an ocean read as water rather than as a dark grey patch; a frozen volatile is bright and slightly glossy;
// rock and vegetation are neither. Ice is its own band once the snow line lands (S3/E1).
uniform float water_roughness : hint_range(0.0, 1.0) = 0.08;
uniform float water_specular : hint_range(0.0, 1.0) = 0.5;
uniform float land_roughness : hint_range(0.0, 1.0) = 0.9;
uniform float land_specular : hint_range(0.0, 1.0) = 0.15;

const float SURFACE_PI = 3.141592653589793;
const float SURFACE_TAU = 6.283185307179586;

// Model space: the unit-sphere position, which **is** the direction. Captured in `vertex()` because
// `VERTEX` inside `fragment()` is in VIEW space.
varying vec3 unit_position;


void vertex() {
	unit_position = normalize(VERTEX);
}


// The mapping, and it must be the exact inverse of the bake's — `u` around the equator, `v` north-at-the-top.
// A mismatch here does not look like an error, it looks like bad geography.
vec2 equirect(vec3 direction) {
	return vec2(
		0.5 + atan(direction.z, direction.x) / SURFACE_TAU,
		0.5 - asin(clamp(direction.y, -1.0, 1.0)) / SURFACE_PI
	);
}


void fragment() {
	vec3 up = unit_position;
	vec2 uv = equirect(up);

	// **The one height**, at whatever resolution the map in hand has — which is the whole point: the coast and
	// the bands sharpen as the eye approaches, and they cannot move, because `sea_level` is a value.
	float height = texture(height_map, uv).r;

	// **The water line, antialiased by what a pixel can resolve.** The width of the fade is the footprint of
	// the reading in field units, so a coast a pixel wide is a soft edge and a coast on the horizon is a level
	// crossing — without it the sea has a staircase.
	float footprint = max(fwidth(height), 1.0e-4);
	float water = 1.0 - smoothstep(sea_level - footprint, sea_level + footprint, height);

	// The colour, from the ramp the derivation built, indexed by the same height.
	float ramp_position = clamp(height * 0.5 + 0.5, 0.0, 1.0);
	ALBEDO = texture(colour_ramp, vec2(ramp_position, 0.5)).rgb;
	ROUGHNESS = mix(land_roughness, water_roughness, water);
	SPECULAR = mix(land_specular, water_specular, water);

	// **The relief, from four taps of the same map.** `eps` is one texel of *that* map, because a fixed
	// epsilon would sample detail the map in hand does not hold and read as noise on distant ground.
	// **Three texels, not one.** One texel is the noisiest possible baseline: adjacent texels of a smooth field
	// differ by the sampling, and on the field's *steepest* feature — the coastal slope, which is where the
	// plate belt and the waterline meet — the difference swings the normal tens of degrees from pixel to
	// pixel. A wider baseline is the cheap fix; the principled one is the ladder, whose octaves are
	// band-limited by the pixel footprint.
	float texel = 3.0 / float(max(map_width, 1));
	float toward_east = texture(height_map, uv + vec2(texel, 0.0)).r;
	float toward_west = texture(height_map, uv - vec2(texel, 0.0)).r;
	// `v` increases *southward*, so the north neighbour is the smaller `v`.
	float toward_north = texture(height_map, uv - vec2(0.0, texel)).r;
	float toward_south = texture(height_map, uv + vec2(0.0, texel)).r;

	// Metres per texel, which is what turns a height difference into a slope. The east-west one shrinks with
	// latitude and is floored, because the equirect map's texels collapse at the poles.
	float metres_east = SURFACE_TAU * planet_radius * max(cos(asin(clamp(up.y, -1.0, 1.0))), 0.05) * texel;
	float metres_north = SURFACE_PI * planet_radius * texel;
	float slope_east = (toward_east - toward_west) * field_amplitude * relief_exaggeration
		/ (2.0 * max(metres_east, 1.0e-3));
	float slope_north = (toward_north - toward_south) * field_amplitude * relief_exaggeration
		/ (2.0 * max(metres_north, 1.0e-3));
	// **And a ceiling on the tilt — the one that matters.** The relief here is a *shading fiction*: it tilts a
	// normal on a sphere that has no relief at all. At a slope of 1:1 (45°) that fiction outshouts the
	// geometry, and the symptom is specific and ugly: **the coastlines light up on the night side**. The coast
	// is the one place the field is steep, so it is the one place the tilt is large — and a large enough tilt
	// faces the sun from well past the terminator, so a thin, dotted outline of every continent glows in the
	// dark while the flat interiors beside it stay black. Nothing in the picture says "relief"; it says
	// "coastlines are lit", which is what a flown screenshot showed.
	//
	// 0.35 is about 19°, which is already steeper than real terrain at a 19 km sampling scale and is the most
	// a normal may lean before it starts inventing light. The real fix is geometric relief (displacement), where
	// a back-lit slope is genuinely back-lit.
	slope_east = clamp(slope_east, -0.35, 0.35);
	slope_north = clamp(slope_north, -0.35, 0.35);

	// **The ladder, from the map's nyquist down to what this pixel can resolve.** `footprint` is the angle one
	// pixel spans — the same quantity the mesh's error budget spends — so the fade needs no distance and
	// nothing to keep in step with the camera.
	// **The LONGEST of the two screen derivatives, not the sum of them.** `fwidth` adds the magnitudes per
	// component, which at a grazing angle — the whole far half of a planet's surface — is dominated by the
	// direction the surface recedes in, and a footprint that large fades rungs that are still resolvable
	// across the view. The other way round is the moiré: a rung drawn where a pixel spans several features.
	float footprint_angle = max(length(dFdx(up)), length(dFdy(up)));
	float detail = 0.0;
	if (detail_octaves > 0 && detail_feature > 0.0) {
		detail = surface_detail(
			up, detail_seed, detail_gain, detail_lacunarity, detail_feature, footprint_angle,
			detail_octaves
		);
	}

	// A tangent basis on the sphere: east from the polar axis, north from the two.
	vec3 polar = abs(up.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 east = normalize(cross(polar, up));
	vec3 north = cross(up, east);
	// **Water is flat** — a glassy sea with hills in it is the one thing that reads as wrong at any distance.
	float relief = 1.0 - water;
	vec3 tilted = normalize(up - east * slope_east * relief - north * slope_north * relief);
	// Model space in, view space out: `NORMAL` is a view-space quantity in a spatial shader, and the
	// fragment stage has `VIEW_MATRIX` rather than `MODELVIEW_MATRIX`. A body's node carries scale and no
	// rotation, so its model space and world space are the same space — which is why this one matrix is
	// enough, and the same reasoning the star's splat uses when it copies the camera basis rather than
	// billingboarding in the material.
	NORMAL = normalize((VIEW_MATRIX * vec4(tilted, 0.0)).xyz);

	// **The detail's own relief, and it costs two derivatives rather than four more noise evaluations.** A
	// procedural height computed per pixel can be bumped by its *screen-space* gradient: the position's
	// derivatives give a tangent frame in view space, and `dFdx/dFdy` of the detail value is its slope per
	// pixel. That is also self-band-limiting — the derivative of a band-limited function is only meaningful at
	// the frequency the pixel resolves — so it needs no epsilon and cannot alias.
	//
	// Water gets a smaller tilt than land, and land's is the one that makes a coaster-sized pixel read as
	// terrain rather than as paint.
	if (detail != 0.0) {
		vec3 view_x = dFdx(VERTEX);
		vec3 view_y = dFdy(VERTEX);
		vec3 tangent = normalize(cross(NORMAL, view_y));
		vec3 bitangent = normalize(cross(view_x, NORMAL));
		// **The relief fades on the pixel's own size**, in metres of ground per pixel — full strength within
		// `relief_near`, gone by `relief_far`. Measured in metres rather than in texels or in distance because
		// the question it answers is "is a bump bigger than a pixel", which is the same at any altitude.
		float pixel_metres = footprint_angle * planet_radius;
		float relief_fade = 1.0 - smoothstep(relief_near, relief_far, pixel_metres);
		float relief = mix(detail_relief, wave_relief, water) * relief_fade;
		vec2 gradient = vec2(dFdx(detail), dFdy(detail)) * relief;
		// A bump may lean only so far — see `relief_max_tilt`.
		float magnitude = length(gradient);
		if (magnitude > relief_max_tilt) {
			gradient *= relief_max_tilt / magnitude;
		}
		NORMAL = normalize(NORMAL - (tangent * gradient.x + bitangent * gradient.y));
		// And the colour, zero-mean and small, on land only — a sea is one colour.
		ALBEDO *= 1.0 + detail * detail_variation * (1.0 - water);
	}
}
