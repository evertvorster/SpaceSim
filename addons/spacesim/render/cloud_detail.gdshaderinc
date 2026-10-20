// **The cloud field's detail below the map — the ladder, in one place.**
//
// The map is a sample of a field that is still a formula, and this reads the same generator beneath the
// map's own resolution. **Two consumers need the same field**: the deck, which draws it, and the shadow,
// which is the image of the same cloud on the ground. A shadow that sampled only the map would be a
// different cloud from the one casting it — blotchy where the cloud is whispy — which is exactly what
// Evert saw in flight.
//
// **Band-limited by the PIXEL FOOTPRINT, never by distance.** Each rung fades out where the pixel is too big
// to resolve it; an unfiltered octave would not be "more detail", it would be sparkle and moiré, because
// detail finer than the sampling rate is a mathematical defect and not a visual style.
//
// **The footprint must be in SPHERE-ARC units, and that was a real bug.** `fwidth` gives the angle a pixel
// spans *at the eye*; every `size` here is an arc *on the unit sphere*, measured at the planet's centre. The
// two agree only when the eye is about a radius away — so a caller close to the shell must scale the
// footprint by its distance to the shell in radii (`|1 − eye_radius|` for the deck, `deck_height / R` for a
// shadow on the ground). Without that the ladder is silently dead at close range.
//
// **Zero-mean**, because `fnl_os2s3` is centred on zero: the threshold is a percentile of the *map's*
// distribution and the ramp gain is fitted to its mean, so a biased term would move the drawn coverage and
// the average with it.
#include "res://addons/spacesim/system/model/noise.gdshaderinc"

// Rungs in the ladder below the map. Six reaches from two texels of an 8k map (9.8 km on Earth) down to
// about 300 m, which is past anything the map can hold and past where the near regime takes over.
const int DETAIL_RUNGS = 6;


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
