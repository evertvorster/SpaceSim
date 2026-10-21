shader_type spatial;
// **`cull_disabled` is not a detail, it is the whole of "a deck seen from underneath".** A spherical shell
// shows FRONT faces from outside and BACK faces from inside, so Godot's default `cull_back` draws the deck
// from above and **deletes it from below** — the mesh is there, the map is there, and there is nothing to
// rasterise. That is exactly the fault Evert reported twice and photographed: drawn at 4.7 km from above,
// absent at 696 m from below. The line was designed, written down in this file's own reasoning, and then
// left out of the file — so every version of this shader until 2026-10-20 had it missing.
//
// `blend_mix` because a deck occludes rather than adds (the air adds; a cloud is something you look *at*),
// `depth_draw_always` because it writes depth where it has cloud and `discard`s where it has none — which is
// what lets the air pass end its march at the first thing drawn — and `specular_disabled` because a cloud's
// highlight is not a specular lobe.
render_mode blend_mix, cull_disabled, depth_draw_always, specular_disabled;

// **The far regime's cloud: a baked coverage map on a shell, with its thickness as shading.**
//
// A deck is the body's own patch mesh, scaled — not a second mesh and not a second walk — so its triangles
// are the planet's by construction and the two cannot disagree about where the surface is. What is drawn
// here is a picture of a field that was already computed: `SpacesimCloudField` baked it, `SpacesimCloudMaps`
// measured its percentile threshold and its mean exceedance, and this shader's whole job is to place the map
// on the sphere, turn it into a slab, and let the air pass dim it.
//
// ---------------------------------------------------------------- THE MAPPING
//
// **This must be the exact inverse of `SpacesimCloudField.bake`, or the bands land mirrored or off by a
// hemisphere** — a bug that reads as bad geography rather than as an error. The bake walks
// `longitude = (u − 0.5)·TAU`, `latitude = PI/2 − v·PI`, and builds
// `direction = (cos lat cos lon, sin lat, cos lat sin lon)`; so:
//
//     u = 0.5 + atan2(z, x) / TAU
//     v = 0.5 - asin(y) / PI
//
// with `v = 0` the north pole, which is the map's top row. **The two are one fact in two languages.**
//
// `repeat_enable` on `u` is deliberate: at `u = 1.0` exactly, which the seam produces, a clamped sampler
// would pick the wrong edge.
uniform sampler2D cover : filter_linear, repeat_enable;

// Where the layer's coverage puts the threshold, as a percentile of the map — from
// `SpacesimCloudMaps.threshold_for()`, so the drawn coverage is the one that was asked for.
uniform float threshold : hint_range(0.0, 1.0) = 0.0;
// The width of a cloud's edge, in field units. One number drives the coverage and nothing else: the deck has
// no separate alpha channel, because a cloud's boundary being soft and being thin are the same fact.
uniform float softness : hint_range(0.001, 0.5) = 0.05;
// **For a deck with no map to threshold.** A `FEATURELESS` body has no map because there is no noise to bake,
// and a uniform field cannot express partial *area* coverage — every texel would land on the same side of
// the threshold. So the coverage comes in here and the result is a veil, which is the honest picture of a
// hazy world rather than an absent one. 1.0 on a mapped deck.
uniform float veil : hint_range(0.0, 1.0) = 1.0;
// **Linear, and already scaled to the deck's own albedo by the host** — the hue only. The reflectance is
// `ramp_gain`, because what a texel draws is `ALBEDO * ALPHA` and the mean of that has to be the calibrated
// albedo. See `ramp_gain`.
uniform vec3 cloud_color = vec3(1.0);

// **One reflectance, as near white as the light budget allows.** Thin cloud is *both* less reflective and
// more transparent, so the variation lives in the alpha and the brightness does not have to vary:
//
//     ALPHA  = covered * veil * thickness          (or the slab law below)
//     ALBEDO = cloud_color * ramp_gain
//
// and the host sets `ramp_gain = target / mean(thickness)` from the map's own measured distribution, so the
// deck's average drawn reflectance is the calibrated albedo exactly and the field's *shape* can only
// redistribute the whiteness. Measured when this was last built: 0.419 over the area, 0.746 at the tops.
uniform float ramp_gain : hint_range(0.0, 1.0) = 1.0;

// **The layer's optical depth at full thickness, or 0 to keep the ramp path.** With a tau the deck is drawn
// as a slab: `ALPHA = 1 − exp(−tau · thickness / mu)` with `mu` the view cosine, so the same cloud is
// *thicker at the limb* because the line of sight through it is longer. That is the difference between a
// deck that is transparent because a number said so and one that is transparent because it is thin.
// **The vertical optical depth of a full column**, from the host — `SpacesimSystemScene._deck_tau_full`. The
// shader multiplies it by the thickness it samples, so opacity and the base's transmittance are the same law
// from the same texel.
uniform float tau_full = 0.0;

// ===== THE SLAB, AND ITS TWO SIDES ==================================================
//
// **A shell has no thickness, so its thickness is a place to SAMPLE from instead of a volume to march.**
// The layer's base is a derived condensation level and its top is `base + thickness`, so both radii are
// real and the shader can ask what the same eye ray sees at each:
//
//   * eye above the top  — sample at the shell: the TOPS, lit by the star;
//   * eye below the base — sample where the ray crosses the BASE sphere, which is genuine parallax of
//                          thickness rather than a fudge, and light the fragment by what got THROUGH the
//                          slab;
//   * eye inside it      — everything is cloud, because it is.
//

// ===== THE BASE'S LIGHT =============================================================
//
// **What "lit from behind" is, mathematically** — `Cloud Decks Plan` §D6, and the law itself is
// `SpacesimCloudBand.two_flux`, `henyey_greenstein` and `sky_radiance`, tested headlessly. The shader carries
// the arithmetic, as it does for the band laws.
//
// A cloud scatters conservatively, so its two faces are **complements**: `R(tau) + T(tau) = 1`. The top's
// reflectance saturates while the base's transmittance falls to nothing, at the same tau — which is why one
// texture serves both faces, and why the thick centres darken by exactly the amount the tops whiten.
//
// The light a base transmits is the sky above it, and that is **derived**, not authored: the same Rayleigh and
// Mie coefficients the sky shader takes, in the closed form of its own single-scatter loop. `beta * H` is a
// vec3 because beta is, so the colour is the Rayleigh ratio and there is no blue constant to guess.
uniform vec3 sky_rayleigh_tau = vec3(0.0);
uniform float sky_mie_tau = 0.0;
uniform float sky_intensity = 0.0;
uniform float sky_anisotropy = 0.758;
// The cloud's own multiply-scattered light: what a base shows once `T -> 0`. A stated interim, scaled as a
// Lambertian surface of the cloud's own reflectance would be — see §D6's "what is approximated".
uniform vec3 scattered_grey = vec3(0.0);
// The star, in the deck's model space — the same convention `eye_local` uses.
uniform vec3 sun_local = vec3(0.0, 1.0, 0.0);
// The eye's offset from the body's centre, **in top radii and in model space** — divided on the host, where
// the numbers are doubles. Its length picks which of the three cases above this fragment is in.
uniform vec3 eye_local = vec3(0.0, 0.0, 2.0);

// ===== THE DETAIL BELOW THE MAP =====================================================
//
// **The map is a sample of a field that is still a formula**, and this reads the same generator beneath the
// map's own resolution. It cannot come from the map: 8,192 wide is 4.9 km a texel on Earth, so from low
// altitude the visible cap is a hundred texels of flat colour.
//
// **Same generator, not a second kind of weather.** `noise.gdshaderinc` is the FastNoiseLite the field was
// baked from, so the detail belongs to the same spectrum. It declares no `shared` memory, which is what makes
// it legal in a fragment shader — the field's vortex stack is why *that* file stays compute-only.
//
// **Band-limited by the PIXEL FOOTPRINT, never by distance.** Each octave fades out where the pixel is too
// big to resolve it; an unfiltered octave would not be "more detail", it would be sparkle and moiré, because
// detail finer than the sampling rate is a mathematical defect and not a visual style. It is also what makes
// a distant deck free: the fade kills every octave long before the fragment does the work.
//
// **Zero-mean, and small.** `fnl_os2s3` is already centred on zero, so the ladder adds the same amount either
// side of the map's value. That matters because the threshold is a percentile of the *map's* distribution and
// `ramp_gain` is fitted to its mean: a biased term would move the drawn coverage and the average with it.
uniform int detail_seed = 0;
// **The coarsest detail feature, in radians on the unit sphere** — two texels of the map *in hand*, set on
// every publish, so the ladder starts exactly where the map stops and can never duplicate it.
uniform float detail_feature = 0.0;
uniform float detail_strength : hint_range(0.0, 0.5) = 0.0;

#include "res://addons/spacesim/render/cloud_detail.gdshaderinc"

// Model space, the offset from the body's centre — which for a unit sphere IS its direction. Captured in
// `vertex()` because **`VERTEX` inside `fragment()` is in VIEW space**.
varying vec3 local_position;


vec2 cloud_map_uv(vec3 p) {
	return vec2(0.5 + atan(p.z, p.x) / TAU, 0.5 - asin(clamp(p.y, -1.0, 1.0)) / PI);
}


void vertex() {
	local_position = VERTEX;
}


void fragment() {
	vec3 p = normalize(local_position);
	// **Inside the deck's sphere** — the only boundary this surface has, since the node is scaled to its TOP.
	float eye_radius = length(eye_local);
	vec3 to_eye = normalize(eye_local - p);

	// **ONE SAMPLE, ON THE TOP SPHERE, ALWAYS.** Evert, 2026-10-21: *"strip the blending code, and map the
	// texture to the top of the deck, always."*
	//
	// So there is no base-sphere projection and no crossfade: the mesh is a sphere at the deck's TOP radius and
	// the map is painted on it, which is all this ever was. Above the deck you see the outside of that sphere;
	// below it you see the inside of the same sphere, which is why the pattern is mirrored and stretched toward
	// the horizon — the parallax a painted surface has, and no attempt is made to hide it.
	//
	// Two things went with the stripping: the base crossing (which displaced the sample to the slab's OTHER
	// face, and is how the deck came to be base-mapped from below) and the blend across the slab (which averaged
	// two decorrelated samplings into a featureless wash — visible as the smooth mid-slab frame). Both are in
	// the history if the mapping ever needs to be revisited; neither is here.
	float field = texture(cover, cloud_map_uv(p)).r;
	// **And the structure the map is too coarse to hold.** `fwidth` of the model-space direction is the angle
	// one pixel spans, so the fade is in the units the feature sizes are in: no distance, no scale factor, and
	// nothing to keep in sync with the camera.
	if (detail_strength > 0.0 && detail_feature > 0.0) {
		field = clamp(
			field + cloud_detail(
				p, length(fwidth(local_position)),
				detail_seed, detail_feature, detail_strength
			),
			0.0, 1.0
		);
	}

	// **The percentile as a step, softened**, then the thickness above it. `threshold = 0` makes the whole
	// field cloud, which is what a body the model calls FEATURELESS should be and what a one-texel white map
	// produces.
	float covered = smoothstep(threshold - softness, threshold + softness, field);
	float thickness = clamp((field - threshold) / max(1.0 - threshold, 1.0e-4), 0.0, 1.0);

	// **The slant path, and it must be the UNSIGNED cosine.** `to_eye` is the direction from this point to the
	// eye, so from outside the slab `dot(p, to_eye)` is the cosine of the view zenith — but from INSIDE the
	// sphere the surface being drawn is the far side, `to_eye` points back inward, and the dot product is
	// negative. Clamped at 0.03 that drove every texel to full opacity and the deck became a smooth white slab
	// with the map's structure invisible inside it — Evert's two screenshots, top and bottom of one cloud.
	// The slab is crossed at the same angle from either face, so the magnitude is the right cosine.
	float mu = clamp(abs(dot(p, to_eye)), 0.03, 1.0);
	// **Opacity is `R(tau)`, the complement of what the base transmits.** The old form was a reflectance ramp —
	// the column's normalised thickness — which saturated at 1, so this face hid everything while the base let a
	// fifth of the sky through at the same texel. Evert: *"there is a lot of alpha applied that seems to be
	// missing from the bottom up."* One law, one texel, both faces: `alpha + transmit = 1`.
	float column_tau = tau_full * thickness / mu;
	float transmit = 1.0 / (1.0 + max(column_tau, 0.0));
	float alpha = covered * veil * (1.0 - transmit);
	// **The inside-the-slab branch is GONE, and deleting it is what removes the flash at the deck's top.** It
	// used to set `alpha = covered` for an eye between the base and the top — a step by construction, where
	// what should change continuously is the cross-section of cloud along the ray. Evert saw it as "at 3k
	// altitude there is a flash again" (2026-10-20), 3,040 m being this deck's top exactly: the shell's own
	// alpha jumped from `covered * thickness` to `covered` on the way in. The inside case is now the pass's,
	// which integrates the cross-section instead of switching pictures.

	vec3 radiance = cloud_color * ramp_gain;

	// **Both faces draw the same way**: the same albedo, the same alpha, the same engine light. On this branch
	// the only thing that distinguishes them is the normal, and that only because a surface seen from the inside
	// has its normal pointing away from the viewer.
	ALBEDO = radiance;
	ALPHA = alpha;
	ROUGHNESS = 0.9;
	// **The normal flips at the TOP, which is the only boundary there is.** Evert, 2026-10-21: *"that flip needs
	// to occur as we cross the upper bound, as I now see no clouds from below at any altitude."*
	//
	// It used to flip at the BASE, which is a radius with no surface on it — so it stepped the lighting at 1,436 m
	// and was still wrong everywhere else. Inside the sphere every fragment is a BACK face whose normal points
	// away from the viewer, and without the flip the underside is lit as though it faced away and goes black.
	// Crossing the top is exactly when that starts, so that is where the flip belongs.
	if (eye_radius < 1.0) {
		NORMAL = -NORMAL;
	}
	// **Depth is written where there IS cloud, and nowhere else.** The air pass clips its march at the first
	// thing drawn, so a gap that wrote depth would lose the air that is properly above the ground; this
	// discard is what keeps the gaps honest. It also stops the sphere blending its own far side through its
	// near side, because the near side's depth then rejects it.
	if (alpha < 0.004) {
		discard;
	}
}
