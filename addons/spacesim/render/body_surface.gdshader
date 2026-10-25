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

// **`filter_linear_mipmap`, and the two hints are not the same thing.** `filter_linear` sets the sampler's
// `max_lod` to 0 (`material_storage.cpp:2666-2692`), so the pyramid the build-time map carries
// (`generate_mipmaps()`) is generated, uploaded and **never read** — and what minified ground does instead is
// alias, which reads as detail. The lod comes from the screen-space derivatives of the sampling coordinates,
// which on an equirect map is correct except at the poles, where the longitude derivative blows up and the map
// is read at its coarsest level: that failure mode is *blur*, which is the safe direction, and the fine detail
// at the poles comes from the ladder rather than from the map.
//
// **The refined maps and the tiles carry no pyramid on purpose** (they are only ever magnified, so the hint
// costs nothing on them), which is why this is a hint and not an assumption about the texture.
uniform sampler2D height_map : filter_linear_mipmap, repeat_enable, hint_default_black;
// **One height map, and no window.** There was a second texture here — a sub-rectangle of the same equirect at a
// finer raster, blended over the base map — and it is gone: its gate compared the cap's desired *pixels* against
// the whole map's *texel count*, so it could never fire below a 4K render, and where it could it asked for a
// raster four times coarser than the map it layered on. The base map's width follows the distance instead (a
// ladder, `SpacesimSurfaceMaps`), and a second resolution to keep in step with the picture is exactly the thing
// this shader has twice been bitten by. The near field is the tiles' business, not a window's.
// The colour ramp: **1-D, indexed by field value over [-1, 1]**, built from the derived bands and the
// measured quantiles. Clamped, because a value past either end is a coast or a peak and not a wrap.
uniform sampler2D colour_ramp : filter_linear, repeat_disable, hint_default_black;
// **The tiles over the cap the eye can see**, as one array with a table of rectangles — the map's near field,
// refined where the eye is looking (`SpacesimSurfaceTiles`). `tile_count` is zero when no tile is in hand, which is
// the far case and the headless one.
uniform sampler2DArray tile_map : filter_linear, repeat_disable, hint_default_black;
uniform vec4 tile_rect[32];
uniform int tile_layer[32];
uniform int tile_count = 0;

// ===== THE LADDER =================================================================================
//
// **The field's own octaves, below what the map could hold** — not a second generator. `surface_height` is a
// sum of octaves, the bake stops at the one its width resolves, and this evaluates the ones above it: the same
// seed lineage, the same frequencies, and `gain^octave` amplitudes, so the fine detail IS the field's small
// features rather than noise laid over them. See `surface_field.gdshaderinc` for the correction this replaced.
//
// **The DEPTH available, not the count that runs.** The count is derived per pixel below, because the pixel is
// the only thing that knows how deep the ladder needs to go.
uniform int detail_max_rungs = 0;
// **Where the field's octave 0 sits**: `plan.seed`, whose octave `j` is `seed + j` at `base_frequency * 2^j`.
uniform int detail_seed = 0;
uniform float detail_base_frequency = 1.0;
// **The first octave the map did not carry**, from `log2(width / (2 * base_frequency))` on the host — the map's
// two-texel feature. The ladder starts there and walks up.
uniform int detail_first_octave = 0;
// The fbm's own normaliser and spectrum, straight off the plan, so the ladder's weights are the map's.
uniform float detail_bounding = 1.0;
uniform float detail_gain = 0.5;
// The falloff of the octaves the map never carried — the field's own `gain` for the ones it did.
uniform float detail_tail_gain = 0.5;
uniform float detail_lacunarity = 2.0;
// How much the detail moves the *colour*, as a fraction of the band's own. **Now scaled by the field's own
// amplitude at that octave**, which for fine octaves is a fraction of a percent — this is a knob that only
// becomes visible again if the field's spectrum gets rougher.
//
// **The defaults below are the host's own values**, and that is a rule rather than a coincidence: a uniform's
// default is the picture a material that missed its publish will draw, so it has to move when the constant
// behind it moves. These were 0.0/0.0, which is a surface that runs the whole 18-rung ladder and shows none
// of it — cost with no picture. `tests/test_render.gd` pins each one against `SpacesimBodyRenderer`.
uniform float detail_variation : hint_range(0.0, 1.0) = 0.18;
// How much the detail tilts the normal, per unit of height difference across a pixel. A look number, and the
// one place the ladder's relief is calibrated.
uniform float detail_relief = 1.0;
// **Whether this body has an ocean at all**, which decides whether the discard below exists. A body with no
// liquid on its surface — Mercury, Luna, Io, Europa, Venus — has no sea layer, and `sea_level` then resolves to
// the field's own minimum; a naive `height < sea_level` discard would punch a hole in whatever ground sits at
// the bottom of the distribution. So the test is switched off rather than made true by luck.
uniform float has_ocean = 0.0;
// **A ceiling on the tilt**, in the same units as the slope: a normal may lean only so far before the fiction
// becomes a hole. A bump's dark side drawn as absolute black is the missing sky as much as the relief — with no
// air above it, nothing lifts a shadow — and that is S4's to fix.
uniform float relief_max_tilt = 0.6;

// **Where the sea is**, in field units — `value_at(ocean_fraction)` off the measured quantiles. The land is
// culled below it; the ocean draws below it. One value, one authority.
uniform float sea_level = 0.0;
// The field's own value times this is metres, and the metres are what the normal needs. From the plan.
uniform float field_amplitude = 1.0;
uniform float planet_radius = 1.0;
// How much the normal is tilted by the gradient — see the header. The one number here that is a look rather
// than a derivation, and it is a *uniform* so the host owns it. The default is the host's, for the reason
// above: 12.0 was 2.4x what anything publishes.
uniform float relief_exaggeration = 5.0;
// The detail map's width, which is what turns a texel into an angle.
uniform int map_width = 1024;


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

	// **The near field: the finest tile that contains this pixel.** The rects arrive finest-first, so the first
	// match is the finest and the loop stops there. Cross-faded to the whole-body map over 2 % of the tile's edge,
	// because a pixel just inside a boundary must not jump between two rasters; with 512-texel tiles that band is
	// ten texels, which reads as softness rather than as a seam.
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

	// **Land is not under water, and below the water line there is a different shader entirely.** Evert,
	// 2026-10-19: water and land are fundamentally different things. So the ground below sea level is culled
	// here — which also means the eight-rung ladder only runs on the 29 % of a planet that is land — and
	// `body_ocean.gdshader` draws the complement from the same map and the same threshold. Exactly one layer
	// survives each pixel, so two coplanar surfaces cannot fight.
	if (has_ocean > 0.5 && height < sea_level) {
		discard;
	}

	// The colour, from the ramp the derivation built, indexed by the same height.
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
	//
	// **The footprint is measured here because it is needed by both halves.** This factor is filtered by the
	// pixel (a penumbra narrower than one is drawn as the step it averages to), and the ladder below is
	// band-limited by it. One measurement, one currency: the angle one pixel spans.
	// **The LONGEST of the two screen derivatives, not the sum of them.** `fwidth` adds the magnitudes per
	// component, which at a grazing angle — the whole far half of a planet's surface — is dominated by the
	// direction the surface recedes in, and a footprint that large fades rungs that are still resolvable
	// across the view. The other way round is the moiré: a rung drawn where a pixel spans several features.
	float footprint_angle = max(length(dFdx(up)), length(dFdy(up)));
	AO = star_transmission(up, body_sun, footprint_angle);
	AO_LIGHT_AFFECT = 1.0;
	// **A cloud's shadow multiplies the star's rather than replacing it** — a deck cannot make the sun rise.
	if (deck_shadow_present()) {
		AO *= deck_shadow_factor(up, planet_radius);
	}
	SPECULAR = land_specular;

	// **The relief, from four taps of the same map.** The tap distance is a multiple of one texel of *that*
	// map, because a fixed epsilon would sample detail the map in hand does not hold and read as noise on
	// distant ground.
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
	// **Two ceilings, and they are deliberately different numbers.** This one bounds the MAP's slope: 0.35 is
	// about 19° and already steeper than real terrain at a 19 km sampling scale. `relief_max_tilt` below bounds
	// the ladder's fine bumps instead, which are a shading fiction at pixel scale and bear a steeper lean.
	// Tuning the uniform does not move this one — they answer different questions, and naming the literal is
	// what says so.
	//
	// **A clamp was never the guard against the dark side, and that is the correction.** It bounds how far a
	// normal may lean and says nothing about which way the star is: 0.35 still faces the sun from 19° past the
	// terminator, so the coastlines came back after 2026-10-19 and again on 2026-10-25. What stops them is
	// `star_transmission()` above — the light is zero where the geometry says the star is below the horizon,
	// whatever the normal claims. The clamps stay for their own reason (a fiction may not outshout the
	// geometry it decorates), and the honest fix for the fiction itself is displacement — `Surface.md` S5.
	slope_east = clamp(slope_east, -MAP_MAX_TILT, MAP_MAX_TILT);
	slope_north = clamp(slope_north, -MAP_MAX_TILT, MAP_MAX_TILT);

	// **The ladder, from the map's nyquist down to what this pixel can resolve.** `footprint` is the angle one
	// pixel spans — measured above, where the star's own occlusion is filtered by it — so the fade needs no
	// distance and nothing to keep in step with the camera.
float detail = 0.0;
	if (detail_max_rungs > 0 && detail_first_octave >= 0 && detail_base_frequency > 0.0) {
		// **The ladder's first feature**, in radians: octave `first_octave` of the field. Everything below is the
		// sampling law, unchanged — the count is `ceil(F / 2*fp)` so it matches the band the fade draws.
		float first_feature = 1.0 / (detail_base_frequency * exp2(float(detail_first_octave)));
		int rungs = int(ceil(log2(max(first_feature / max(2.0 * footprint_angle, 1.0e-9), 1.0))));
		rungs = clamp(rungs, 0, detail_max_rungs);
		if (rungs > 0) {
			detail = surface_detail(
				up, detail_seed, detail_base_frequency, detail_first_octave, rungs,
				detail_gain, detail_tail_gain, detail_lacunarity, detail_bounding, footprint_angle
			);
		}
	}

	// A tangent basis on the sphere: east from the polar axis, north from the two.
	// **`east` must be the direction `slope_east` was measured in, and it was not.** The slopes above come from
	// `texture(uv + vec2(texel, 0.0))` — that is **+u**, increasing longitude — while `cross(polar, up)` is the
	// **−u** direction: at the +X equator `cross(Y, X)` is −Z, and `equirect` puts +u on +Z. Measured against the
	// true basis the old line was `dot(shader_east, +u) = −1.00` at every latitude, so the relief's east–west
	// tilt was inverted and its north–south tilt was right — which is exactly an Evert report of *"shadows on the
	// wrong side of the high areas"* that also looks half-correct, and why it does not read as a clean inversion.
	// The two lines change together: `north` is derived from `east`, so flipping one would invert both.
	// (`cross(up, polar)` is +u, and `cross(east, up)` is then +north.)
	vec3 polar = abs(up.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 east = normalize(cross(up, polar));
	vec3 north = cross(east, up);
	vec3 tilted = normalize(up - east * slope_east - north * slope_north);
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
		// **The relief as a SLOPE — metres of height per metre of ground — and that is the whole fix for the
		// black dots and the horizon moiré.** The screen-space derivative of the relief height, divided by the
		// ground the pixel spans in that direction, is the surface's real gradient: it does not grow as the view
		// grazes (both the derivative and the step grow together) and it does not shrink as the pixel grows, so a
		// bump shades by its own steepness wherever it is seen. The envelope of a fixed near/far fade could not
		// do this: it drew a pixel covered in many bumps as if it were one.
		float step_east = max(length(view_x), 1.0e-4);
		float step_north = max(length(view_y), 1.0e-4);
		vec2 gradient = vec2(dFdx(detail) / step_east, dFdy(detail) / step_north)
			* field_amplitude * detail_relief;
		// A bump may lean only so far — see `relief_max_tilt`.
		float magnitude = length(gradient);
		if (magnitude > relief_max_tilt) {
			gradient *= relief_max_tilt / magnitude;
		}
		NORMAL = normalize(NORMAL - (tangent * gradient.x + bitangent * gradient.y));
		// And the colour, zero-mean and small — so the band's mean cannot drift from the measured distribution
		// it was placed with.
		ALBEDO *= 1.0 + detail * detail_variation;
	}
}
