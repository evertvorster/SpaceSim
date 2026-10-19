shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://addons/spacesim/system/model/noise.gdshaderinc"
#include "res://addons/spacesim/system/model/surface_field.gdshaderinc"

// **The ocean: a level, absorbing surface, and nothing else.**
//
// Water and land are fundamentally different things, so they are different shaders. This one has **no relief
// code at all** — not a strength set to zero, an absence — because a sea is the one surface whose height is
// known exactly. The land shader carries the height field, the band ramp and an eight-rung detail ladder; none
// of that is here.
//
// ---------------------------------------------------------------- WHY IT IS OPAQUE
//
// Evert, 2026-10-19: *"The ocean might be transparent, but it has a super-high absorption, so realistically we
// won't see anything below a couple of meters."* So there is no alpha, no blending and no transparent pass: the
// colour **is** the shallow water. Light coming back off the bottom a metre down is what shallow water looks
// like, and drawing it as colour gets the picture without a single transparent pixel — and without the sorting,
// the alpha edge and the shoreline that shimmers.
//
// ---------------------------------------------------------------- THE ONE THING THE TWO LAYERS SHARE
//
// **One map, one threshold.** The land draws where `height >= sea_level` and this draws where it is below, from
// the same texture and the same value. If the two ever disagree by a pixel the coast has a seam, so there is
// one authority for both: `sea_level` is a *value* measured off the map's own distribution, and the map is the
// same texture the land shades from.

// The field, as the land shader receives it. Only the *mask* and the *depth* are used.
uniform sampler2D height_map : filter_linear, repeat_enable, hint_default_black;
// **The tiles over the cap the eye can see**, as one array with a table of rectangles — the map's near field,
// refined where the eye is looking (`SpacesimSurfaceTiles`). `tile_count` is zero when no tile is in hand, which
// is the far case and the headless one. **The land reads the same table from the same array**, so the shore is one
// threshold on one height and two resolutions can never disagree about where the coast is.
uniform sampler2DArray tile_map : filter_linear, repeat_disable, hint_default_black;
uniform vec4 tile_rect[32];
uniform int tile_layer[32];
uniform int tile_count = 0;
uniform float sea_level = 0.0;
// The field's value times this is metres — which turns the map into a **depth**.
uniform float field_amplitude = 1.0;
uniform float planet_radius = 1.0;
uniform int map_width = 2048;

// **The depth ramp**, in metres below the surface: the bottom's own colour showing through near the shore, and
// the water's own colour past it. Both come from `SpacesimSurfaceModel.bands()` on the host — the shallow end
// from the lowest land band (what the bottom is made of, tinted by water) and the deep end from the liquid
// band's own colour — so this shader decides no colour at all.
uniform vec3 shallow_color : source_color = vec3(0.2, 0.5, 0.5);
uniform vec3 deep_color : source_color = vec3(0.02, 0.06, 0.15);
uniform float shallow_metres = 2.0;
uniform float deep_metres = 40.0;

// Water's shading: glossy, with the sun's glint and the bright limb coming out of the BRDF for nothing.
uniform float roughness_value : hint_range(0.0, 1.0) = 0.14;
uniform float specular_value : hint_range(0.0, 1.0) = 0.45;

// ===== THE WAVES =====
//
// **Two rungs of the field's own generator, and a height the sea could actually have.** Evert, 2026-10-19: *"the
// ocean needs to be practically smooth until we walk around next to it... waves as tall as mountains is a bit
// scary."* So the amplitude is a *fraction of a degree* of tilt, and it is gated on the pixel spanning metres of
// water — the only moment a wave can be seen at all. The numbers are the host's.
uniform int wave_octaves = 0;
uniform int wave_seed = 0;
uniform float wave_gain = 0.5;
uniform float wave_lacunarity = 2.0;
// The coarsest wave feature, in radians on the unit sphere: a swell some hundreds of metres across.
uniform float wave_feature = 0.0;
uniform float wave_relief = 0.02;
uniform float wave_near = 1.0;
uniform float wave_far = 25.0;

const float OCEAN_PI = 3.141592653589793;
const float OCEAN_TAU = 6.283185307179586;

// Model space, and on a unit sphere that IS the direction. Captured in `vertex()` because `VERTEX` inside
// `fragment()` is in VIEW space.
varying vec3 unit_position;


void vertex() {
	unit_position = normalize(VERTEX);
}


vec2 equirect(vec3 direction) {
	return vec2(
		0.5 + atan(direction.z, direction.x) / OCEAN_TAU,
		0.5 - asin(clamp(direction.y, -1.0, 1.0)) / OCEAN_PI
	);
}


void fragment() {
	vec3 up = unit_position;
	vec2 uv = equirect(up);
	float height = texture(height_map, uv).r;

	// **The near field**, the same table the land shader reads and in the same order — finest first, first match
	// wins, feathered to the whole-body map at the tile's edge. Without this the sea's threshold would be the base
	// map's while the land's was the tile's, and the coast would be a band where both layers drew or neither did.
	for (int i = 0; i < tile_count; i++) {
		vec4 tile = tile_rect[i];
		if (uv.x >= tile.x && uv.x <= tile.z && uv.y >= tile.y && uv.y <= tile.w) {
			vec2 local = (uv - tile.xy) / max(tile.zw - tile.xy, vec2(1.0e-6));
			vec2 edge = smoothstep(vec2(0.0), vec2(0.02), local)
				* (1.0 - smoothstep(vec2(0.98), vec2(1.0), local));
			height = mix(height, texture(tile_map, vec3(local, float(tile_layer[i]))).r, edge.x * edge.y);
			break;
		}
	}

	// **Land is not this shader's business.** The complementary test to the land's own discard, on the same
	// value and the same map: exactly one of the two layers survives per pixel, so the two are disjoint and
	// coplanar and nothing can z-fight.
	if (height >= sea_level) {
		discard;
	}

	// **The depth**, in metres — the map is a height field, and everything below sea level is water over
	// ground. This is what the shallow end of the ramp is made of.
	float depth = (sea_level - height) * field_amplitude;
	float fill = smoothstep(shallow_metres, max(deep_metres, shallow_metres * 1.01), depth);
	ALBEDO = mix(shallow_color, deep_color, fill);
	ROUGHNESS = roughness_value;
	SPECULAR = specular_value;

	// **The waves.** Flat by default; a ripple only where a pixel spans metres. The sea's ripple is not an octave
	// of the planet's height field, so it is expressed as its own ladder of the same generator: octave 0 sits at
	// `1 / wave_feature`, and `wave_relief` is the amplitude that makes it a sea rather than a landscape.
	if (wave_octaves > 0 && wave_feature > 0.0) {
		float footprint_angle = max(length(dFdx(up)), length(dFdy(up)));
		float pixel_metres = footprint_angle * planet_radius;
		float wave_fade = 1.0 - smoothstep(wave_near, wave_far, pixel_metres);
		float wave_height = surface_detail(
			up, wave_seed, 1.0 / wave_feature, 0, wave_octaves,
			wave_gain, wave_lacunarity, 1.0, footprint_angle
		);
		if (wave_height != 0.0 && wave_fade > 0.0) {
			// **The same slope the land's relief uses** — metres of height per metre of water — divided by the
			// ground a pixel spans, so a small ripple stays small however the view grazes.
			vec3 view_x = dFdx(VERTEX);
			vec3 view_y = dFdy(VERTEX);
			vec3 normal_view = normalize((VIEW_MATRIX * vec4(up, 0.0)).xyz);
			vec3 tangent = normalize(cross(normal_view, view_y));
			vec3 bitangent = normalize(cross(view_x, normal_view));
			vec2 gradient = vec2(
				dFdx(wave_height) / max(length(view_x), 1.0e-4),
				dFdy(wave_height) / max(length(view_y), 1.0e-4)
			) * field_amplitude * wave_relief * wave_fade;
			NORMAL = normalize(normal_view - (tangent * gradient.x + bitangent * gradient.y));
		}
	}
}
