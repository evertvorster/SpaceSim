shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

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
// ---------------------------------------------------------------- TWO MAPS, TWO JOBS
//
// `coarse_map` is an **absolute** resolution — baked once per body and never refined — and it decides the
// ocean mask and the colour bands. `height_map` is the one that refines as the eye approaches, and it carries
// the shading height and the gradient the normals are made from.
//
// **The coastline reads the coarse map only.** If it thresholded the refining map, every shore would move
// outward as detail arrived on approach — a shimmer along exactly the thing being looked at.
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
uniform sampler2D coarse_map : filter_linear, repeat_enable, hint_default_black;
uniform sampler2D height_map : filter_linear, repeat_enable, hint_default_black;
// The colour ramp: **1-D, indexed by field value over [-1, 1]**, built from the derived bands and the
// measured quantiles. Clamped, because a value past either end is a coast or a peak and not a wrap.
uniform sampler2D colour_ramp : filter_linear, repeat_disable, hint_default_black;

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

	// The coarse reading: the mask and the bands, and neither of them ever consults the detail map.
	float coarse = texture(coarse_map, uv).r;

	// **The water line, antialiased by what a pixel can resolve.** The width of the fade is the footprint of
	// the coarse reading in field units, so a coast a pixel wide is a soft edge and a coast on the horizon is
	// a level crossing — without it the sea has a staircase.
	float footprint = max(length(fwidth(vec2(coarse))), 1.0e-4);
	float water = 1.0 - smoothstep(sea_level - footprint, sea_level + footprint, coarse);

	// The colour, from the ramp the derivation built. **The coarse height indexes it** — using the detailed
	// one would move every band edge as the map refined, which is the coastline problem one layer up.
	float ramp_position = clamp(coarse * 0.5 + 0.5, 0.0, 1.0);
	ALBEDO = texture(colour_ramp, vec2(ramp_position, 0.5)).rgb;
	ROUGHNESS = mix(land_roughness, water_roughness, water);
	SPECULAR = mix(land_specular, water_specular, water);

	// **The relief, from four taps of the detail map.** `eps` is one texel of *that* map, because a fixed
	// epsilon would sample detail the map in hand does not hold and read as noise on distant ground.
	float texel = 1.0 / float(max(map_width, 1));
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
}
