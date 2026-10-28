shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// **The field, in a fragment shader.** `noise.gdshaderinc` is FastNoiseLite in GLSL with no `shared` memory —
// which is exactly what makes it legal here — and `surface_field.gdshaderinc` is the same generator the bake
// compiles, so the detail below the map's texel belongs to the map's spectrum rather than being a second
// geology. The include is the whole mechanism: one field, two compilers.
#include "res://addons/spacesim/system/model/noise.gdshaderinc"
#include "res://addons/spacesim/system/model/surface_field.gdshaderinc"
// **The star: where it is, how wide it looks, and what the air leaves of it.** First, because it declares
// `body_sun` and the include below reads it — a shader compiles top to bottom.
#include "res://addons/spacesim/render/star_transmission.gdshaderinc"
// **The deck above, as a shadow.** One law, shared with the sea, so the two cannot disagree.
#include "res://addons/spacesim/render/deck_shadow.gdshaderinc"

// **The ground: the field itself, in a fragment shader, with no raster anywhere.**
//
// ---------------------------------------------------------------- NO RASTER
//
// **The height is `surface_height` — the same function the bake compiles — evaluated per pixel**, at the resolution
// that pixel can resolve. Evert, 2026-10-28: *"I would like to stop having a raster at all."*
//
// Everything that used to stand between the field and the picture is gone with the raster, and each of them was a
// symptom rather than a mechanism: a whole-body map with a ladder of refinement rungs, a quadtree of tiles over the
// visible cap, a 4×4 Catmull-Rom reconstruction to smooth a bilinear raster's corners, a sub-texel grain to fill what
// a texel hides, and the field's own crests continued below the map. **A coastline is a level set of the height**, so
// it was exactly as smooth as the raster holding that height, and a raster is a grid: one texel wide, corners at
// every texel boundary, ~2.4 km at 212 km altitude.
//
// **The octave count is the pixel's, not a constant**, which is what makes this affordable: `surface_height` fades
// each octave a pixel cannot resolve, so a 20-pixel moon pays for one and the ground at walking height pays for
// eighteen, and neither aliases. The work follows what is *resolvable*.
//
// ---------------------------------------------------------------- WHAT IT IS GIVEN
//
// **Nothing here derives anything.** The field's numbers are `SpacesimSurfaceField.plan()`'s, published as uniforms;
// the colours are `SpacesimSurfaceModel.bands()`'s, with each band's luminance set to its own albedo; and the ramp's
// ends are the field's own *measured* distribution, which the build-time bake still provides — a formula cannot tell
// you its own percentile. The shader places them and shades them.
//
// **The one sampler left is a colour table**: 256 texels of band colour, indexed by the field's value. There is no
// height texture in this shader at all.
//
// ---------------------------------------------------------------- THE RELIEF IS A SHADING TRICK
//
// A real planet's relief is 0.14 % of its radius, so its true slopes are a fraction of a degree and the shading they
// produce is invisible at any distance. `relief_exaggeration` is the named concession: the normal is tilted by the
// field's own gradient times it. **The silhouette does not change** — that is the mesh's business, and displacement is
// its own rung; when the vertices carry the relief, the exaggeration goes to 1.0, the surface shading as steep as it is.
//
// The colour ramp: **1-D, indexed by field value over [-1, 1]**, built from the derived bands and the
// measured quantiles. Clamped, because a value past either end is a coast or a peak and not a wrap.
//
// **This is a TABLE, not a raster of the planet** — 256 texels of colour, and the field's own value indexes it. There
// is no height texture in this shader at all.
uniform sampler2D colour_ramp : filter_linear, repeat_disable, hint_default_black;

// ===== THE FIELD ==================================================================================
//
// **Every number `SpacesimSurfaceField.plan()` derives, published so the SHADER can be the ground's only height
// source.** These are the same values the bake compiles — one field, two compilers — and `surface_plan()` assembles
// them into the struct `surface_field.gdshaderinc` expects. `tests/test_render.gd` fails if one the shader declares
// is not published, because an unpublished uniform is silently the shader's own default and that default is a
// different planet.
uniform int field_seed = 0;
uniform float field_continent_frequency = 2.0;
uniform int field_continent_octaves = 5;
uniform float field_continent_share = 0.35;
uniform float field_continent_bounding = 1.0;
uniform float field_ridge_frequency = 11.0;
uniform int field_ridge_octaves = 4;
uniform float field_ridge_strength = 0.5;
uniform float field_warp_frequency = 3.0;
uniform int field_warp_octaves = 3;
uniform float field_warp_strength = 0.35;
uniform float field_warp_bounding = 0.5714;
uniform float field_region_frequency = 1.5;
uniform int field_region_octaves = 3;
uniform float field_region_share = 0.4;
uniform float field_region_bounding = 1.0;
uniform float field_plate_bias_share = 0.5;
uniform float field_belt_width = 0.08;
uniform float field_plate_phase = 0.0;
uniform float field_mottle_plain_gain = 0.25;
uniform float field_gain = 0.5;
uniform float field_lacunarity = 2.0;

// **A ceiling on the tilt**, in the same units as the slope: a normal may lean only so far before the fiction
// becomes a hole. A bump's dark side drawn as absolute black is the missing sky as much as the relief — with no
// air above it, nothing lifts a shadow — and that is S4's to fix.
uniform float relief_max_tilt = 0.6;

// **Where the sea would be**, in field units — `value_at(ocean_fraction)` off the measured quantiles.
//
// **Nothing culls on it any more.** It used to be the threshold that split the planet into two layers, the land and
// the sea layer drew the complement; both went on 2026-10-28 because a liquid is a level and a second field of
// coplanar triangles is not how one is drawn on a lattice that carries metres. **It stays because it is the DATUM**,
// and the next thing this shader does is displace the surface by `height - sea_level`: with a bare `height` the land
// would stand up to 1.56 km above the sphere that the ship's altitude, the framings' bands and a deck's condensation
// level all still measure from.
uniform float sea_level = 0.0;
// The field's own value times this is metres, and the metres are what the normal needs. From the plan.
uniform float field_amplitude = 1.0;
uniform float planet_radius = 1.0;
// How much the normal is tilted by the gradient — see the header. The one number here that is a look rather
// than a derivation, and it is a *uniform* so the host owns it. The default is the host's, for the reason
// above: 12.0 was 2.4x what anything publishes.
uniform float relief_exaggeration = 5.0;


// The land's shading. **A liquid is not this shader's business** — it has its own, and this one is rock,
// vegetation and ice.
uniform float land_roughness : hint_range(0.0, 1.0) = 0.9;
uniform float land_specular : hint_range(0.0, 1.0) = 0.15;

const float SURFACE_PI = 3.141592653589793;
const float SURFACE_TAU = 6.283185307179586;

// **The map's own tilt ceiling**, and it is NOT `relief_max_tilt` — see the clamp below. 0.35 is about 19°:
// steeper than real terrain at a 19 km sampling scale. **It bounds the lean; it never was the guard against
// the dark side** — the star's own occlusion is (`star_transmission.gdshaderinc`), because only light that
// reaches a point can be invented by its normal.
const float MAP_MAX_TILT = 0.35;

// Model space, and **on this lattice it is METRES, not a unit sphere**: a vertex is measured from an origin near the
// eye, so a point's direction from the body's centre is `VERTEX + patch_origin` — which is why the normal is derived
// here rather than uploaded (a normal per vertex in every upload was 12.9-13.5 ms of `mesh_from` on the device).
// Captured in `vertex()` because `VERTEX` inside `fragment()` is in VIEW space.
varying vec3 unit_position;

// The mapping, and it must be the exact inverse of the bake's — `u` around the equator, `v` north-at-the-top.
// A mismatch here does not look like an error, it looks like bad geography.
vec2 equirect(vec3 direction) {
	return vec2(
		0.5 + atan(direction.z, direction.x) / SURFACE_TAU,
		0.5 - asin(clamp(direction.y, -1.0, 1.0)) / SURFACE_PI
	);
}

// **The field's plan, assembled from the uniforms above.** One place, so every reader of the field — the height now,
// and the displacement later — sees the same numbers the bake compiles.
SurfacePlan surface_plan() {
	SurfacePlan plan;
	plan.seed = field_seed;
	plan.continent_frequency = field_continent_frequency;
	plan.continent_octaves = field_continent_octaves;
	plan.continent_share = field_continent_share;
	plan.continent_bounding = field_continent_bounding;
	plan.ridge_frequency = field_ridge_frequency;
	plan.ridge_octaves = field_ridge_octaves;
	plan.ridge_strength = field_ridge_strength;
	plan.warp_frequency = field_warp_frequency;
	plan.warp_octaves = field_warp_octaves;
	plan.warp_strength = field_warp_strength;
	plan.warp_bounding = field_warp_bounding;
	plan.region_frequency = field_region_frequency;
	plan.region_octaves = field_region_octaves;
	plan.region_share = field_region_share;
	plan.region_bounding = field_region_bounding;
	plan.plate_bias_share = field_plate_bias_share;
	plan.belt_width = field_belt_width;
	plan.plate_phase = field_plate_phase;
	plan.mottle_plain_gain = field_mottle_plain_gain;
	plan.gain = field_gain;
	plan.lacunarity = field_lacunarity;
	return plan;
}


// **The point the vertices are measured from**, in model space — the node's own origin, published with the transform.
// The mesh carries no normal array: on a unit sphere a point's direction from the centre IS its normal, and the centre
// is at `-patch_origin` in these coordinates, so the direction is `VERTEX + patch_origin`. That saves a normal per
// vertex in every upload, and it cannot disagree with the geometry because it is derived from it.
uniform vec3 patch_origin = vec3(0.0);

// **The platform's `flat` mode, as one uniform rather than a second material.** `render.mode` is `wireframe`, `flat` or
// `rendered`, and `wireframe` is a different material (unshaded lines); `flat` is this shader with every texture read
// short-circuited to the derived albedo, which is what the ground drew before it had a surface stack.
uniform float flat_mode : hint_range(0.0, 1.0) = 0.0;
// The body's derived colour, which is what `flat` draws.
//
// **The name is `flat_mode` and not `flat`: `flat` is a GLSL interpolation qualifier** — a uniform called `flat`
// fails to compile with "Expected an identifier", which reads as a syntax error halfway up the file.
uniform vec3 base_color : source_color = vec3(0.5, 0.5, 0.5);
// **The debug tint, as a multiplier** — `render.depth_tint` publishes 1.0 or 0.0, so the picture is unchanged when it is
// off and the tree is legible when it is on. The colour itself is a vertex colour per patch (`SpacesimPatches.depth_tint`),
// so this shader does not need to know what a depth is.
uniform float tint_amount : hint_range(0.0, 1.0) = 0.0;
varying vec3 patch_tint;


void vertex() {
	// The vertex colour, which is white on any mesh that supplies none.
	patch_tint = COLOR.rgb;
	// **The direction, from the lattice's own origin.** Normalising a 6,371 km vector is fine in float32: the
	// *direction* only needs relative precision.
	unit_position = normalize(VERTEX + patch_origin);
}


void fragment() {
	// **`flat` is the platform's mode, and it short-circuits every texture read in this shader** — no map, no tile
	// loop, no ladder. What it draws is the body's derived albedo, which is what the ground looked like before it had a
	// surface stack; the debug tint is the one thing it shares with `rendered`, because the tint is about the tree.
	if (flat_mode > 0.5) {
		ALBEDO = base_color * mix(vec3(1.0), patch_tint, tint_amount);
		ROUGHNESS = land_roughness;
		SPECULAR = land_specular;
	} else {
		vec3 up = unit_position;
		// **The angle one pixel spans, and it is the ONE currency resolution is measured in here**: the field's own
		// octaves are faded by it, and the star's transmission is filtered by it.
		// **The LONGEST of the two screen derivatives, not the sum of them.** `fwidth` adds the magnitudes per
		// component, which at a grazing angle — the whole far half of a planet's surface — is dominated by the
		// direction the surface recedes in, and a footprint that large fades octaves that are still resolvable
		// across the view. The other way round is the moiré: an octave drawn where a pixel spans several features.
		float footprint_angle = max(length(dFdx(up)), length(dFdy(up)));

		// ===== THE GROUND, AS ITS OWN FUNCTION ====================================================
		//
		// **No raster.** The height is `surface_height` itself — the same function the bake compiles — evaluated here
		// at the resolution *this pixel* can resolve. So there is no texel grid to staircase a coastline, no near
		// field to seam against a coarse base, and nothing to keep in step as the eye moves. Evert, 2026-10-28:
		// *"I would like to stop having a raster at all."*
		//
		// **What that removed, and why each one was a symptom rather than a mechanism**: the whole-body map and its
		// ladder of rungs, the quadtree of tiles over the visible cap, the 4x4 Catmull-Rom reconstruction that
		// smoothed a raster's bilinear corners, the sub-texel grain that filled the gap a texel hides, and the crests
		// below the map that carried 2 cm of a 8.9 km range. Every one of them existed to work around a raster.
		//
		// **The octave count is the footprint's, not a constant.** `surface_height` fades each octave a pixel cannot
		// resolve, so a 20-pixel moon pays for one and the ground at walking height pays for eighteen, and neither
		// aliases. That is also what makes this affordable: the work follows what is *resolvable*, and a distant
		// body has almost no pixels to spend it on.
		SurfacePlan plan = surface_plan();
		float height = surface_height(up, plan, footprint_angle);

		// The colour, from the ramp the derivation built, indexed by the field's own value.
		float ramp_position = clamp(height * 0.5 + 0.5, 0.0, 1.0);
		ALBEDO = texture(colour_ramp, vec2(ramp_position, 0.5)).rgb;
		// **The light has crossed the air before it got here**, and that is per channel: blue first, then green,
		// then red — which is what makes a ridge near the terminator orange rather than white.
		//
		// **Split into brightness and hue, because a specular lobe is built from the LIGHT and not from `ALBEDO`.**
		// Scaling the albedo alone left the sun's glint shining through the air at full strength — Evert, flying,
		// 2026-10-25, on the sun's path over water at sunset: *"light reflecting off the surface passes unhindered
		// through the cloud layer"*. So the transmittance's **brightness** goes into `AO`, which the engine applies
		// to the whole light contribution — diffuse and specular together — and only its **hue** stays on the
		// reflectance, at unit brightness. The product is unchanged for the diffuse:
		// `albedo·light·AO × (t/L) × L = albedo·light·t`, exactly the per-channel transmittance.
		//
		// **What is left imperfect**: a scalar `AO` cannot redden, so the glint dims but keeps the sun's white. A
		// `light()` override is the only honest fix and it costs the PBR this surface was tuned with; a dim white
		// glint at sunset is the better trade than a blinding one.
		vec3 air_through = star_air_transmittance(up, body_sun, air_altitude, planet_radius);
		float air_brightness = dot(air_through, vec3(0.2126, 0.7152, 0.0722));
		ALBEDO *= air_through / max(air_brightness, 1.0e-3);
		AO *= air_brightness;
		ROUGHNESS = land_roughness;
		// **Everything that decides how much of the star reaches this point, in one slot** — and it is `AO`
		// because the engine turns that into a *direct-light* occlusion before the light loop, which is exactly
		// what a shadow is and needs no BRDF of our own. See `deck_shadow.gdshaderinc`.
		//
		// **The star's own transmission is the load-bearing one.** The body occludes itself, so a point past the
		// geometric terminator receives no starlight whatever its shading normal says — and the relief below is a
		// fiction that leans up to a clamped 19°, far enough to face the sun from well into the dark half. That is
		// the artefact this factor exists to kill: thin lit outlines tracing every coastline on the night side.
		// It is applied to the LIGHT and not to the normal on purpose — the tilt is the ground.
		AO = star_transmission(up, body_sun, footprint_angle);
		AO_LIGHT_AFFECT = 1.0;
		// **A cloud's shadow multiplies the star's rather than replacing it** — a deck cannot make the sun rise.
		if (deck_shadow_present()) {
			AO *= deck_shadow_factor(up, planet_radius);
		}
		SPECULAR = land_specular;
		// **A specular highlight is a BEAM, and the composite's `1 - alpha` is the deck's DIFFUSE transmittance.**
		// Right for the ground's own colour; thousands of times too much for the sun's reflection on water behind a
		// solid deck. `deck_specular_share` is the ratio of the two, at the same `deck_tau · path` the shadow casts
		// with, so this corrects *which* transmittance applies rather than adding a second law about the cloud.
		if (deck_shadow_present()) {
			SPECULAR *= deck_specular_share(
				up, normalize(body_eye_local - up), planet_radius
			);
		}

		// ===== THE NORMAL, FROM THE FIELD'S OWN GRADIENT ===========================================
		//
		// **The height's screen-space derivative IS the slope**, so the relief costs no second evaluation of the
		// field: `dFdx(height)` and `dFdy(height)` are already there, and the only work is decomposing the pixel's own
		// step in the tangent basis so a height difference becomes a lean.
		//
		//     [ dFdx(up) ] . (p·east + q·north) = dFdx(height)
		//     [ dFdy(up) ] . (p·east + q·north) = dFdy(height)      →  a 2x2 solve for (p, q)
		//
		// **Two screen steps, and both are in direction units**, which is why the result is field-units per radian and
		// the conversion to a slope is `field_amplitude / planet_radius`. A degenerate quad (zero determinant) keeps
		// the geometric normal rather than dividing by it — the one case where a derivative is not defined.
		vec3 polar = abs(up.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		vec3 east = normalize(cross(up, polar));
		vec3 north = cross(east, up);
		vec2 step_x = vec2(dot(dFdx(up), east), dot(dFdx(up), north));
		vec2 step_y = vec2(dot(dFdy(up), east), dot(dFdy(up), north));
		float determinant = step_x.x * step_y.y - step_x.y * step_y.x;
		vec2 slope = vec2(0.0);
		if (abs(determinant) > 1.0e-20) {
			float height_dx = dFdx(height);
			float height_dy = dFdy(height);
			slope = vec2(
				step_y.y * height_dx - step_x.y * height_dy,
				step_x.x * height_dy - step_y.x * height_dx
			) / determinant;
		}
		slope *= field_amplitude / max(planet_radius, 1.0) * relief_exaggeration;
		// **The one ceiling that matters here.** A normal may lean only so far before the shading outshouts the
		// geometry it decorates, and — for the reason the star's transmission above exists — the guard against the
		// dark side was never this clamp.
		slope = clamp(slope, vec2(-relief_max_tilt), vec2(relief_max_tilt));
		vec3 tilted = normalize(up - east * slope.x - north * slope.y);
		// Model space in, view space out: `NORMAL` is a view-space quantity in a spatial shader, and the fragment
		// stage has `VIEW_MATRIX` rather than `MODELVIEW_MATRIX`. A body's node carries no rotation, so its model
		// space and world space are the same space — which is why this one matrix is enough.
		NORMAL = normalize((VIEW_MATRIX * vec4(tilted, 0.0)).xyz);

		// **The debug tint**, the one place it can change the picture.
		ALBEDO *= mix(vec3(1.0), patch_tint, tint_amount);
	}
}
