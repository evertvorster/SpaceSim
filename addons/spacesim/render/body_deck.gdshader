shader_type spatial;
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
uniform float optical_depth = 0.0;

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
// `base_ratio` is `R_base / R_top`, which is all the geometry the shader needs: both radii are on the same
// node, so the top is 1.0 in model space.
uniform float base_ratio : hint_range(0.0, 1.0) = 1.0;
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

#include "res://addons/spacesim/system/model/noise.gdshaderinc"

// Rungs in the ladder below the map. Six reaches from two texels of an 8k map (9.8 km on Earth) down to about
// 300 m, which is past anything the map can hold and past where the near regime takes over.
const int DETAIL_RUNGS = 6;

// Model space, the offset from the body's centre — which for a unit sphere IS its direction. Captured in
// `vertex()` because **`VERTEX` inside `fragment()` is in VIEW space**.
varying vec3 local_position;


vec2 cloud_map_uv(vec3 p) {
	return vec2(0.5 + atan(p.z, p.x) / TAU, 0.5 - asin(clamp(p.y, -1.0, 1.0)) / PI);
}


// One octave per rung, each faded out where a pixel spans more than a quarter of its feature.
float cloud_detail(vec3 p, float footprint, int seed, float feature, float strength) {
	float total = 0.0;
	float weight = 0.0;
	float amplitude = 1.0;
	float size = feature;
	for (int rung = 0; rung < DETAIL_RUNGS; rung++) {
		float audible = 1.0 - smoothstep(0.25, 0.5, footprint / size);
		total += fnl_os2s3(seed + rung * 1013, p / size) * amplitude * audible;
		weight += amplitude;
		amplitude *= 0.5;
		size *= 0.5;
	}
	// Normalised by the weight it RAN, so the ladder's statistics do not change with the rung count.
	return weight > 0.0 ? total / weight * strength : 0.0;
}


void vertex() {
	local_position = VERTEX;
}


void fragment() {
	vec3 p = normalize(local_position);
	float eye_radius = length(eye_local);
	vec3 to_eye = normalize(eye_local - p);
	bool from_below = eye_radius < base_ratio;

	// **The base's own crossing of this eye ray.** For an eye under the deck the near intersection with the
	// base sphere is what the sky shows through, and it is a different direction from the top's by exactly
	// the slab's thickness. `ray_sphere`'s convention here is Godot's: the eye is the origin and the sphere
	// is centred on the body, so `c = |eye|^2 - r^2` and a positive discriminant means the ray meets it.
	vec3 sample_direction = p;
	if (from_below) {
		vec3 ray = normalize(p - eye_local);
		float half_b = dot(eye_local, ray);
		float discriminant = half_b * half_b - (dot(eye_local, eye_local) - base_ratio * base_ratio);
		if (discriminant > 0.0) {
			sample_direction = normalize(eye_local + ray * (-half_b + sqrt(discriminant)));
		}
	}

	float field = texture(cover, cloud_map_uv(sample_direction)).r;
	// **And the structure the map is too coarse to hold below the map's own texel.**
	//
	// **The footprint has to be in the same frame as the feature sizes, and that was a real bug.** `fwidth`
	// gives the angle a pixel spans **at the eye**; every `size` in the ladder is an arc **on the unit sphere**,
	// i.e. measured at the planet's centre. The two agree only when the eye is about a radius away — which is
	// why the ladder worked from orbit and was dead from 700 m, where they differ by R/distance ≈ 9,000 and
	// every rung faded out. Converting the footprint into sphere-arc units is one factor: the eye's distance to
	// the shell, in radii. **From underneath, that made the difference between "one map texel and no detail"
	// and a sky with structure in it.**
	float eye_to_shell = max(abs(1.0 - eye_radius), 1.0e-7);
	float sphere_footprint = length(fwidth(local_position)) * eye_to_shell;
	if (detail_strength > 0.0 && detail_feature > 0.0) {
		field = clamp(
			field + cloud_detail(
				sample_direction, sphere_footprint, detail_seed, detail_feature, detail_strength
			),
			0.0, 1.0
		);
	}

	// **The percentile as a step, softened**, then the thickness above it. `threshold = 0` makes the whole
	// field cloud, which is what a body the model calls FEATURELESS should be and what a one-texel white map
	// produces.
	float covered = smoothstep(threshold - softness, threshold + softness, field);
	float thickness = clamp((field - threshold) / max(1.0 - threshold, 1.0e-4), 0.0, 1.0);

	// **The slant path.** `to_eye` is the direction out of the slab, so its cosine against the normal is
	// `mu` — 1 at the sub-solar point, 0 at the limb.
	float mu = clamp(dot(p, to_eye), 0.03, 1.0);
	float alpha = covered * veil * thickness;
	if (optical_depth > 0.0) {
		alpha = covered * veil * (1.0 - exp(-optical_depth * thickness / mu));
	}
	// **Inside the slab there is no way round it**: the deck is between the eye and everything, so cover is
	// the whole story. This is what stops punching through a deck from being a sudden bright flash.
	if (eye_radius < 1.0 && eye_radius >= base_ratio) {
		alpha = covered;
	}

	vec3 radiance = cloud_color * ramp_gain;
	if (from_below) {
		// **Multiple scattering, not single.** The first version of this multiplied the radiance by
		// `exp(-tau / mu_sun)`, which is what a *beam* loses crossing the slab — and it made the underside
		// collapse towards the horizon and go black near it. A real cloud's base is a **diffuse source**: light
		// enters the top, scatters many times, and leaves the base in every direction, which is why the base of
		// a cumulus is bright grey at any viewing angle. So the underside gets a stated share of the top's
		// reflectance and the *angle* is not in it.
		//
		// **Day and night are still the light loop's**, which multiplies by the surface's own cosine to the
		// star — so a night-side base stays dark without this number having to know about it.
		//
		// 0.35 is a look number, named here rather than buried: a water cloud's base runs about a third to a
		// half of its top's brightness, and an *under*-side that reads as thinner than the top is the physical
		// direction to err in. `tests/shader_check.sh` is what says it compiles; only a flight says whether it
		// reads.
		const float UNDERSIDE_SHARE = 0.35;
		radiance *= UNDERSIDE_SHARE;
	}

	ALBEDO = radiance;
	ALPHA = alpha;
	ROUGHNESS = 0.9;
	if (from_below) {
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
