// **Detail below whatever raster is in hand — the ladder, in one place, for every consumer.**
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

// **The rungs are at ABSOLUTE sizes, and that is what stops the ground re-noising itself.**
//
// Rung `i` is `DETAIL_ANCHOR · 2^-i` radians — a fixed sequence, independent of whatever raster is in hand. What the
// caller changes is only **which** rungs are drawn: `coarsest` is the raster's own two-texel feature, so a finer map
// or a landing tile *drops* the coarse end of the sequence rather than sliding the whole ladder up or down.
//
// The version before this scaled every rung to the raster in hand (`feature = 2·TAU/width_now`), which meant every
// rung that landed **rescaled the noise field**: the ground visibly re-textured each time the map climbed, and until
// the first rung landed the ladder was anchored to a 256-wide map's 313 km features. Evert, 2026-10-26: *"areas where
// a clipmap has not been rendered yet show up completely smooth, and the noise value for the texture changes."*
// One bug, two symptoms, and the fix is an anchor that does not move.
const float DETAIL_ANCHOR = 1.0;
// From a whole-radian feature down to a pixel at walking height is about twenty doublings; this is the ceiling on the
// sequence, not a count that runs.
const int DETAIL_RUNGS_MAX = 24;


float banded_detail(vec3 p, float footprint, float coarsest, int seed, float strength) {
	if (coarsest <= 0.0 || strength <= 0.0) {
		return 0.0;
	}
	// The first rung the raster in hand did not carry, and where the sequence starts — a `log2`, not a rescale.
	int first = max(int(ceil(log2(DETAIL_ANCHOR / coarsest))), 0);
	float total = 0.0;
	float weight = 0.0;
	for (int rung = first; rung < DETAIL_RUNGS_MAX; rung++) {
		float size = DETAIL_ANCHOR * exp2(-float(rung));
		// **Faded out where a pixel spans more than a quarter of it** — band-limited by the sampling rate, which is
		// the law every mechanism here obeys — and the loop stops at the first rung that is inaudible, because the
		// ones below it are finer still.
		float audible = 1.0 - smoothstep(0.25, 0.5, footprint / size);
		if (audible <= 0.0) {
			break;
		}
		// **The amplitude belongs to the rung, not to the count that ran**, so a rung appearing cannot change the
		// strength of its neighbours.
		float amplitude = exp2(-float(rung));
		total += fnl_os2s3(seed + rung * 1013, p / size) * amplitude * audible;
		weight += amplitude * audible;
	}
	// Normalised by what was audible, so the ladder's *contrast* is `strength` whatever the raster and whatever the
	// altitude — which is what lets the same number serve a 256-wide map and a 512-texel tile.
	return weight > 0.0 ? total / weight * strength : 0.0;
}
