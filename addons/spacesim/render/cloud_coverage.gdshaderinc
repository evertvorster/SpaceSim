// ===== THE COVERAGE, RECONSTRUCTED RATHER THAN INTERPOLATED ======================================
//
// **A cloud's edge is a LEVEL SET of the coverage field, so it is exactly as smooth as the reconstruction of that
// field — and bilinear is not smooth.** Bilinear filtering is C⁰: its gradient jumps at every texel boundary, so a
// level set of it is a polyline with a corner at each one. On the ground that was the coastline staircase, and the
// deck's edge is the same quantity: `covered = smoothstep(threshold ± softness, field)`, a threshold on the field.
// Evert, 2026-10-29, on the decks once they drew again: *"they have the same issue as the land shader with walking a
// ladder and rasterizing."* The ladder is gone; this is the rasterizing.
//
// **The field underneath is smooth; the faceting is the filter's.** So the fix is not resolution — no map width
// removes a corner that is not in the data — it is to reconstruct the stored samples with a kernel that is at least
// C¹: Catmull-Rom, four taps an axis, sixteen a sample.
//
// **Both consumers must use it, and that is the point of it being here.** The deck draws the cloud and the ground's
// shadow is the *image* of the same cloud, so a shadow reconstructing its sampling differently from the deck would be
// a slightly different cloud from the one overhead — the fault `deck_shadow.gdshaderinc` exists to prevent.
//
// **It costs texture fetches and no arithmetic worth naming**, and minification stays the mip pyramid's business: the
// LOD is passed in, so a distant deck reads its coarse mip and pays four times one fetch.
//
// ===== THE LOD IS EXPLICIT, AND THAT IS WHAT KILLS THE SEAM LINE ==================================
//
// **`texture()` picks its mip from the screen-space derivative of the uv it is given — and this uv wraps.** `u` is
// built from `atan(z, x)`, so at the antimeridian it passes from 1 to 0 inside one pixel: `dFdx(u)` is ~1.0 there
// instead of ~0.001, the sampler reads the whole map as sub-pixel, and that ONE COLUMN is drawn from the coarsest
// mip while its neighbours are not. A single, faint, one-pixel-wide vertical line down the disc — and one pixel wide
// at every distance, because it is a screen-space artefact rather than a feature of the map.
//
// Evert, 2026-11-03: *"The one vertical line is still there, and goes away when I turn off rendering of cloud decks.
// It seems to be one pixel wide, from far away and up close."* The field was ruled out by measurement — the baked map
// is continuous at the wrap **at every mip level** — which leaves the sampler's choice of mip, and this is the only
// place the deck's uv wraps.
//
// So the mip is chosen from the SPHERE'S OWN footprint, which is continuous everywhere, and never from a derivative
// of a wrapping coordinate. `textureLod` then ignores the derivatives entirely.
float cloud_uv_lod(vec3 direction, float footprint_angle, float map_width) {
	// `u = 0.5 + atan(z, x)/TAU` so |grad u| = 1/(TAU * sqrt(x^2 + z^2)); `v = 0.5 - asin(y)/PI` so
	// |grad v| = 1/(PI * sqrt(1 - y^2)). The denominators are the same quantity, so one `sqrt` serves both, and both
	// blow up at the pole — which is honest, an equirect map has no resolution there.
	float across = max(1.0 - direction.y * direction.y, 1.0e-6);
	float texels_along = footprint_angle * map_width / (TAU * sqrt(across));
	float texels_across = footprint_angle * (map_width * 0.5) / (PI * sqrt(across));
	return max(log2(max(texels_along, texels_across)), 0.0);
}
//
// **`texel` is the map's own texel in uv** — `(1/w, 2/w)` for a 2:1 equirect — because a kernel that assumed a square
// texel would reconstruct a different surface on a 2:1 map than it does on a square one.
vec4 cloud_rom_weights(float t) {
	// `a = -0.5`, the standard Catmull-Rom tension: no overshoot beyond a texel's own swing on smooth data, and the
	// weights sum to exactly 1 so a constant field reconstructs as that constant.
	float t2 = t * t;
	float t3 = t2 * t;
	return vec4(
		-0.5 * t3 + t2 - 0.5 * t,
		1.5 * t3 - 2.5 * t2 + 1.0,
		-1.5 * t3 + 2.0 * t2 + 0.5 * t,
		0.5 * t3 - 0.5 * t2
	);
}


// One 2-D Catmull-Rom sample of a coverage map. Values can overshoot a texel's own range by a few per cent on a sharp
// edge, which for a coverage field is the point — a smoothed step is what a bilinear tap cannot give.
float cloud_coverage(sampler2D map, vec2 uv, vec2 texel, float lod) {
	vec2 pos = uv / texel - 0.5;
	vec2 base = floor(pos);
	vec4 weights_x = cloud_rom_weights(pos.x - base.x);
	vec4 weights_y = cloud_rom_weights(pos.y - base.y);
	float total = 0.0;
	for (int row = 0; row < 4; row++) {
		for (int column = 0; column < 4; column++) {
			vec2 at = (base + vec2(float(column) - 1.0, float(row) - 1.0) + 0.5) * texel;
			total += textureLod(map, at, lod).r * weights_x[column] * weights_y[row];
		}
	}
	return total;
}
