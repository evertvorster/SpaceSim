shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// **The field, in a fragment shader.** `noise.gdshaderinc` is FastNoiseLite in GLSL with no `shared` memory —
// which is exactly what makes it legal here — and `surface_field.gdshaderinc` is the same generator the bake
// compiles, so the detail below the map's texel belongs to the map's spectrum rather than being a second
// geology. The include is the whole mechanism: one field, two compilers.
#include "res://addons/spacesim/system/model/noise.gdshaderinc"
#include "res://addons/spacesim/system/model/surface_field.gdshaderinc"
// **The parameters and the plan they assemble, beside the field rather than inside it** — an include reachable from a
// compute assembly may not carry uniforms, and this one is. See the file's own header.
#include "res://addons/spacesim/system/model/surface_plan.gdshaderinc"
// **The star: where it is, how wide it looks, and what the air leaves of it.** First, because it declares
// `body_sun` and the include below reads it — a shader compiles top to bottom.
#include "res://addons/spacesim/render/star_transmission.gdshaderinc"
// **The deck above, as a shadow.** One law, shared with the sea, so the two cannot disagree.
#include "res://addons/spacesim/render/cloud_coverage.gdshaderinc"
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
// ---------------------------------------------------------------- THE RELIEF IS THE GEOMETRY'S, AND NOTHING ELSE
//
// **This shader draws a flat picture of the field and nothing more.** The height it evaluates per pixel colours the
// ground; it does not lean the normal and it does not move the vertex. Both of those were stand-ins for geometry that
// did not exist yet, and both are now the mesh's business: a vertex's height is translated into its POSITION on the
// CPU, so the silhouette is the terrain's and the light falls on the real slope.
//
// The one thing that made this look like a ball with hills on it was `relief_exaggeration`, which tilted the normal by
// the field's own gradient. Evert, 2026-11-01: *"the surface shader here is still trying to do that fake height thing.
// ... A few commits it was just producing a flat texture, with some colors applied to it. That flat texture is what we
// are after."* With real geometry a tilted normal counts the mountain twice, and without it the picture is honest
// about what is drawn.
//
// The colour ramp: **1-D, indexed by field value over [-1, 1]**, built from the derived bands and the
// measured quantiles. Clamped, because a value past either end is a coast or a peak and not a wrap.
//
// **This is a TABLE, not a raster of the planet** — 256 texels of colour, and the field's own value indexes it. There
// is no height texture in this shader at all, and nothing here is sampled by the geometry.
uniform sampler2D colour_ramp : filter_linear, repeat_disable, hint_default_black;

// ===== THE FIELD ==================================================================================
//
// **Every number `SpacesimSurfaceField.plan()` derives, published so the SHADER can be the ground's only height
// source.** These are the same values the bake compiles — one field, two compilers — and `surface_plan()` assembles
// them into the struct `surface_field.gdshaderinc` expects. `tests/test_render.gd` fails if one the shader declares
// is not published, because an unpublished uniform is silently the shader's own default and that default is a
// different planet.

// **Where the sea would be**, in field units — `value_at(ocean_fraction)` off the measured quantiles.
//
// **Nothing culls on it any more.** It used to be the threshold that split the planet into two layers, the land and
// the sea layer drew the complement; both went on 2026-10-28 because a liquid is a level and a second field of
// coplanar triangles is not how one is drawn on a lattice that carries metres. **It stays because it is the DATUM**,
// and the datum is what a translated vertex will measure from: `height - sea_level`, radial, so the land stands above
// the sphere that the ship's altitude, the framings' bands and a deck's condensation level all still measure from.
// With a bare `height` the land stood up to 1.56 km above that sphere, which was a flown fault on 2026-10-27.
uniform float sea_level = 0.0;
uniform float planet_radius = 1.0;
// **The angle one pixel of the render target spans at the centre of the frame** — `SpacesimLod.pixel_angle`, the
// same number the patch walk is given, published per frame because it follows the fov and the render resolution.
//
// **The default is an honest 1080-line 70-degree frame**, not zero: a material that missed its publish then draws
// detail at a plausible resolution rather than an unbounded amount of it.
uniform float pixel_angle = 0.0012966806;

// The land's shading. **A liquid is not this shader's business** — it has its own, and this one is rock,
// vegetation and ice.
uniform float land_roughness : hint_range(0.0, 1.0) = 0.9;

// **A very slight grain, only where the eye is close enough to see the surface rather than the field.** Evert,
// 2026-11-01: *"some very slight noise when I am very near the texture, it looks a bit too clean."*
//
// It is a dither and not a detail term: the field's own octaves fade by the ANGULAR footprint, which does not shrink
// as the camera descends — so up close the ground is as smooth as it is from orbit, and the last thing with any
// variation in it was deleted with the raster. This puts a fraction of a percent back, keyed on the ground's own
// direction at a frequency no eye will read as terrain, and it fades out by 300 m so it can never become texture.
uniform float ground_grain : hint_range(0.0, 0.2) = 0.05;
uniform float land_specular : hint_range(0.0, 1.0) = 0.15;

const float SURFACE_PI = 3.141592653589793;
const float SURFACE_TAU = 6.283185307179586;

// **The map's own tilt ceiling**, and it is NOT `relief_max_tilt` — see the clamp below. 0.35 is about 19°:
// steeper than real terrain at a 19 km sampling scale. **It bounds the lean; it never was the guard against
// the dark side** — the star's own occlusion is (`star_transmission.gdshaderinc`), because only light that
// reaches a point can be invented by its normal.
const float MAP_MAX_TILT = 0.35;

// **How hard the light is told about hills the geometry does not carry.** Evert, 2026-11-01: *"I liked that shading
// trick, we can put some of that back in."* With a displaced mesh the shape is real, so this is no longer standing in
// for absent geometry — it is an *exaggeration* of the shape that is there, and it has to stay small enough that the
// mountain is not counted twice. **1.0 since 2026-11-01**: at 2.0 Evert flew it and asked for *"about half"* — it
// leans the normal by at most `atan(MAP_MAX_TILT)` ~ 19 degrees.
//
// **Two things the first version did that this one must not**, both recorded where it was deleted:
//
// 1. it took the gradient from a SECOND evaluation of the height at an octave count that stepped with the pixel
//    footprint, so the shading jumped in rings around the sub-camera point — *"little black triangles in rings"*.
//    Here the gradient is of the height already computed for the colour: one sampling, one octave set, nothing to
//    step.
// 2. it tilted by `max(height - sea_level, 0)`, which is C0 but not C1 — the slope at a coastline is enormous, the
//    normal tips past vertical, and the shore drew as a black ring. The field itself is smooth, so the tilt uses the
//    field and the coastline has no kink to fall into.
uniform float relief_exaggeration : hint_range(0.0, 6.0) = 1.0;

// Model space, and **on this lattice it is METRES, not a unit sphere**: a vertex is measured from an origin near the
// eye, so a point's direction from the body's centre is `VERTEX + patch_origin` — which is why the normal is derived
// here rather than uploaded (a normal per vertex in every upload was 12.9-13.5 ms of `mesh_from` on the device).
// Captured in `vertex()` because `VERTEX` inside `fragment()` is in VIEW space.
varying vec3 unit_position;
// **This vertex's height above the datum, in metres**, taken in `vertex()` where `VERTEX` is in MODEL space. It has to
// be a varying: in `fragment()` `VERTEX` is in view space, so a radius measured there is a distance from the camera,
// not from the body's centre — which is how the first version of the shadow's base cull ended up doing nothing.
varying float surface_altitude;

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


// **The point the vertices are measured from**, in model space — the node's own origin, published with the transform.
// The mesh carries no normal array: on a unit sphere a point's direction from the centre IS its normal, and the centre
// is at `-patch_origin` in these coordinates, so the direction is `VERTEX + patch_origin`. That saves a normal per
// vertex in every upload, and it cannot disagree with the geometry because it is derived from it.
uniform vec3 patch_origin = vec3(0.0);

// **The platform's `flat` mode, as one uniform rather than a second material.** `render.mode` is `wireframe`, `flat` or
// `rendered`, and `wireframe` is a different material (unshaded lines); `flat` is this shader with every texture read
// short-circuited to the derived albedo, which is what the ground drew before it had a surface stack.
uniform float flat_mode : hint_range(0.0, 1.0) = 0.0;
// **Whether this body HAS a surface at all** — a gas giant does not: what you see is its deck, and the sphere
// beneath is an interior that the deck is drawn on. So the field is not evaluated for it and the sphere draws
// `base_color` flat, which is exactly what `flat_mode` draws and why the two share one branch rather than
// getting a second copy of it. Evert, 2026-11-02: *"we need the vertex sphere to be generated, as the clouds are
// drawn on copies of it. However, we don't need to draw the displacement map on to it when the planet has no
// surface."*
uniform float has_surface = 1.0;
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
	surface_altitude = length(VERTEX + patch_origin) - planet_radius;
	// **The normal IS the direction, because the mesh carries no normal array.** On a sphere the position is the
	// direction, so this is exact for the geometry that is drawn — and it has to be set here, because `NORMAL` inside
	// `fragment()` is in VIEW space and read-only. **The relief is not added to it**: a vertex's height is in its
	// POSITION (translated on the CPU, see `SpacesimPatches`), so the face the light falls on is the real one, and
	// tilting the normal on top of that would count the mountain twice.
	NORMAL = unit_position;
}


void fragment() {
	// **`flat` is the platform's mode, and it short-circuits every texture read in this shader** — no map, no tile
	// loop, no ladder. What it draws is the body's derived albedo, which is what the ground looked like before it had a
	// surface stack; the debug tint is the one thing it shares with `rendered`, because the tint is about the tree.
	if (flat_mode > 0.5 || has_surface < 0.5) {
		// A surface-less body stops here: no field, no ramp, no relief — the interior an atmosphere is drawn on.
		ALBEDO = base_color * mix(vec3(1.0), patch_tint, tint_amount);
		ROUGHNESS = land_roughness;
		SPECULAR = land_specular;
	} else {
		vec3 up = unit_position;
		// **The angle one pixel spans on THIS surface, and it is the ONE currency resolution is measured in here**: the
		// field's own octaves are faded by it, and the star's transmission is filtered by it.
		//
		//     footprint = pixel_angle / cos(tilt),   tilt from the surface point to the EYE
		//
		// **Not taken from `dFdx(up)`**, which measures the same quantity but only as faithfully as the mesh does: a
		// derivative of an interpolated varying depends on the TRIANGULATION, so re-selecting the patches changes it
		// at a fixed pixel — and with it the octave count, the height, the colour ramp's index and the relief normal.
		// That is a texture that moves while the geometry does not, which is what the ground was doing when flown
		// towards. `body_eye_local` is the eye in the body's own frame, so this is one normalize and one dot, and it
		// is the same foreshortening the patch walk's apparent-size limit now holds constant.
		//
		// **The floor is the silhouette's**: at the limb a pixel covers thousands of times the surface it does under
		// the eye, and the honest answer there is a coarse footprint — but not an unbounded one.
		vec3 eye_direction = normalize(body_eye_local - up);
		float footprint_angle = pixel_angle / max(dot(up, eye_direction), 0.02);

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

		// ===== THE RELIEF, LEANING THE LIGHT =====================================================
		//
		// **The gradient of the height already in hand**, projected onto the tangent plane and taken off the normal.
		// `dFdx(up)` and `dFdy(up)` are the screen-space steps across the sphere, so a 2x2 solve turns the height's
		// screen derivatives into a gradient *on the surface* — no tangent attribute, and no second sampling of the
		// field. Length-clamped, because a slope steeper than `MAP_MAX_TILT` is one the geometry is already showing.
		if (relief_exaggeration > 0.0) {
			vec3 n = NORMAL;
			vec3 t1 = normalize(cross(n, abs(n.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
			vec3 t2 = cross(n, t1);
			vec3 dux = dFdx(up);
			vec3 duy = dFdy(up);
			float a = dot(dux, t1);
			float b = dot(dux, t2);
			float c = dot(duy, t1);
			float d = dot(duy, t2);
			float det = a * d - b * c;
			if (abs(det) > 1.0e-12) {
				float dhx = dFdx(height);
				float dhy = dFdy(height);
				vec3 gradient = ((d * dhx - b * dhy) / det) * t1 + ((a * dhy - c * dhx) / det) * t2;
				float lean = length(gradient);
				if (lean > MAP_MAX_TILT) {
					gradient *= MAP_MAX_TILT / lean;
				}
				NORMAL = normalize(n - relief_exaggeration * gradient);
			}
		}

		// The colour, from the ramp the derivation built, indexed by the field's own value.
		float ramp_position = clamp(height * 0.5 + 0.5, 0.0, 1.0);
		ALBEDO = texture(colour_ramp, vec2(ramp_position, 0.5)).rgb;

		// **The grain, faded in by how close the eye is.** The altitude is the camera's, in metres — the fragment's
		// own direction is a unit vector, so its distance from the eye is the eye's radius less one, times the
		// planet's. Keyed on `FRAGCOORD` so it is a per-pixel dither rather than a feature that would crawl.
		float eye_altitude_m = (length(body_eye_local) - 1.0) * planet_radius;
		float grain_fade = 1.0 - smoothstep(50.0, 300.0, eye_altitude_m);
		if (ground_grain > 0.0 && grain_fade > 0.001) {
			float grain_noise = fract(52.9829189 * fract(0.06711056 * FRAGCOORD.x + 0.00583715 * FRAGCOORD.y));
			ALBEDO *= 1.0 + ground_grain * grain_fade * (grain_noise - 0.5);
		}
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
		// **This point's own height above the datum**, which is what tells the shadow whether this ground is under
		// the cloud or standing up through it. Interpolated from the vertex stage — see the varying's note.
		if (deck_shadow_present()) {
			AO *= deck_shadow_factor(up, planet_radius, surface_altitude);
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

		// ===== THE NORMAL ==========================================================================
		//
		// **It is the geometric normal, and that is the whole of it** — set in `vertex()` from the direction, which on
		// a sphere IS the normal, and interpolated across the face for free. There is no tilt: the relief this shader
		// used to fake by leaning the normal at the field's own gradient is now in the vertex POSITIONS, translated on
		// the CPU, so the light here falls on the slope that was actually drawn.
		//
		// **THE FIELD'S SLOPE AS A NORMAL WAS TRIED, FLOWN AND REVERTED** (2026-11-01, `fab2dbd` -> `15df4d8`). It is
		// the obvious idea — the analytic normal of the surface the mesh samples, continuous where the mesh is not — and
		// it failed for two reasons that are both IN THE FIELD, not in the solve, so a better solve will not rescue it:
		//
		// 1. **The octave count steps with the pixel footprint**, so the height's derivative jumps in *rings* around the
		//    sub-camera point and the shading steps with it. Flown as "little black triangles in rings".
		// 2. **`max(height - sea_level, 0)` is C0 but not C1** — a liquid is a LEVEL, so the field has a kink at exactly
		//    the coastline, the sharpest thing on the whole surface. The slope there is enormous, the normal tips past
		//    vertical, and the coast draws as a black ring.
		//
		// **And it did not make the ground look smoother at any altitude**, which is the finding that matters more: the
		// harshness was never the shading. A facet's edge is visible because of its SILHOUETTE and its neighbours, and no
		// normal can hide that. If the ground needs to look smoother it needs smaller facets — `lod.error_budget` — not a
		// cleverer normal.
		//
		// Deleted with it (2026-11-01): the 2x2 tangent-basis solve on `dFdx`/`dFdy` of the height, the
		// `field_amplitude / planet_radius` slope conversion, `relief_exaggeration` and its `relief_max_tilt` clamp.
		// All four existed only to make a smooth sphere read as three-dimensional, and a mountain counted twice is a
		// crumpled paper mountain.

		// ===== MOONLIGHT =================================================================================
		//
		// **A second Lambert lobe, computed here rather than by a light Godot owns.** The light a moon reflects is
		// `E * albedo / PI * cos(theta)`, and the air takes its share on the way in exactly as it does for the star —
		// `star_air_transmittance` per channel, then `star_transmission` for the moon's own horizon, so the terminator
		// this lobe gives is the moon's and not a plane.
		//
		// **Written to `EMISSION`**, which is added after the light loop: this is light the PBR loop does not know
		// about, so handing it to ALBEDO would have multiplied an unlit surface's colour by nothing.
		if (dot(moon_irradiance, vec3(1.0)) > 0.0) {
			float moon_facing = max(dot(up, body_moon), 0.0);
			if (moon_facing > 0.0) {
				vec3 moon_through = star_air_transmittance(up, body_moon, air_altitude, planet_radius);
				float moon_up = star_transmission(up, body_moon, footprint_angle);
				EMISSION += ALBEDO * moon_irradiance * moon_through * moon_up * moon_facing / SURFACE_PI;
			}
		}

		// **The debug tint**, the one place it can change the picture.
		ALBEDO *= mix(vec3(1.0), patch_tint, tint_amount);
	}

}
