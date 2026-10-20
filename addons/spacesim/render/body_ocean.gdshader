shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://addons/spacesim/system/model/noise.gdshaderinc"
#include "res://addons/spacesim/system/model/surface_field.gdshaderinc"
// **The deck above, as a shadow** — the same law the land uses, so a shadowed shore meets a shadowed sea.
#include "res://addons/spacesim/render/deck_shadow.gdshaderinc"

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
uniform float wave_relief = 0.0015;
// **The wind's stretch**, along the east tangent: 3 means a swell three times longer than it is wide. See
// `OCEAN_WAVE_STRETCH` — an isotropic sea is indistinguishable from ground.
uniform float wave_stretch = 1.0;

// ===== THE SEA'S OWN COLOUR STRUCTURE =====
//
// **Waves are geometry, so nothing under a few hundred metres can be seen from orbit** — and the far sea was one
// flat colour because of it. What an ocean actually shows at range is its *colour*: eddies, fronts, slicks at
// tens of kilometres. Same ladder, same band-limit, different mechanism: this one modulates the water's albedo
// rather than its normal.
uniform int tone_octaves = 0;
uniform int tone_seed = 0;
uniform float tone_gain = 0.5;
uniform float tone_lacunarity = 2.0;
uniform float tone_variation : hint_range(0.0, 1.0) = 0.0;

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
	// **The deck's shadow, on the sea as on the land** — the same transmittance, the same uniform, one law in
	// `deck_shadow.gdshaderinc`. A shadowed shore beside an unshadowed sea would be worse than no shadow.
	if (deck_shadow_present()) {
		AO = deck_shadow_factor(normalize(unit_position), planet_radius);
		AO_LIGHT_AFFECT = 1.0;
	}
	SPECULAR = specular_value;

	// **One sampling law for everything here**: a feature is drawn while a pixel holds at least four samples of
	// it, gone by two. There is no near/far gate — there was, `wave_fade = 1 - smoothstep(1 m, 25 m, pixel)`, and it
	// decided when the sea appeared rather than the law doing it: full below 0.8 km and zero above 20.8 km, which
	// is why a descent saw nothing until 10 km. See `OCEAN_WAVE_OCTAVES`.
	float footprint_angle = max(length(dFdx(up)), length(dFdy(up)));

	// **The swell runs downwind, so the domain is drawn out along one axis** — the same trick the cloud field uses
	// for zonal stretching, in the tangent plane instead of in latitude. Without it the sea is an isotropic fbm,
	// which is exactly what the land's detail is, and it reads as ground.
	vec3 polar = abs(up.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 east = normalize(cross(up, polar));
	float along = dot(up, east);
	vec3 wave_point = up + east * (along * (1.0 / max(wave_stretch, 1.0) - 1.0));

	// **The waves**: a fraction of a degree of tilt, from a 400 m swell down to metres of chop.
	if (wave_octaves > 0 && wave_feature > 0.0) {
		float wave_height = surface_detail(
			wave_point, wave_seed, 1.0 / wave_feature, 0, wave_octaves,
			wave_gain, wave_gain, wave_lacunarity, 1.0, footprint_angle
		);
		if (wave_height != 0.0) {
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
			) * field_amplitude * wave_relief;
			NORMAL = normalize(normal_view - (tangent * gradient.x + bitangent * gradient.y));
		}
	}

	// **The sea's colour structure**: eddies, fronts and slicks, and it is drawn at EVERY distance on purpose.
	// Evert, 2026-10-19: *"We can live with the aliasing... Mottling on land now has no aliasing, because it is
	// implemented correctly."*
	//
	// **This is the one place in the project that deliberately breaks the band-limit, and the reason it may.**
	// Land's detail drives *shading*, so detail below the sampling rate moves the normal and becomes shimmer — the
	// near ground's carpet. This is a static *albedo* modulation: sub-pixel detail in it averages to a slightly
	// noisier colour rather than to crawling light, so the cost of drawing it far out is small and the gain is a sea
	// that is not one flat colour from orbit. `footprint` is passed as 0.0, which makes every rung's fade exactly
	// 1 — full amplitude at any distance — and `tone_variation` is the only strength knob.
	//
	// **`first_feature` is still two texels of the map in hand**, so the pattern's *scale* follows the raster and
	// the two layers share one notion of "finest thing on the surface".
	if (tone_octaves > 0) {
		float first_feature = 2.0 * OCEAN_TAU / float(max(map_width, 1));
		float tone = surface_detail(
			wave_point, tone_seed, 1.0 / first_feature, 0, tone_octaves,
			tone_gain, tone_gain, tone_lacunarity, 1.0, 0.0
		);
		ALBEDO *= 1.0 + tone * tone_variation;
	}
}
