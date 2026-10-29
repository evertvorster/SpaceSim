// **The cloud field, as GLSL** — the GPU twin of `SpacesimCloudField.intensity_at()`, and the reason it
// takes plain numbers rather than a `Morphology`.
//
// This file is not a `Shader`: it is read as TEXT, prepended with `#version 450` and a compute `main()`,
// and compiled through `RenderingDevice.shader_compile_spirv_from_source()`. That is why it carries no
// `#version`, no layout qualifiers and no entry point — and why the file is a `.gdshaderinc`, which is
// what tells Godot not to try to compile it on its own.
//
// **The noise is not here.** `fnl_os2s3`/`fnl_fbm3` and their tables live in `noise.gdshaderinc`, one home
// for two consumers: a compute source string gets no preprocessor, so `SpacesimCloudGpu._source()`
// concatenates that file in front of this one. A copy here as well would be a second noise that agrees
// until the day it does not.
//
// ## The CPU path is the reference, and it stays
//
// `SpacesimCloudField.bake()` is not going away: it is the headless test surface for a
// visually-significant thing, and the thing this file is checked against. `tests/test_cloud_gpu.gd`
// bakes the same small map through both and compares byte for byte, so a divergence here is a test
// failure rather than a picture nobody can explain.

// ===== THE FIELD =====================================================================================
//
// From here down this is `SpacesimCloudField`, mirrored. The constants are duplicated by hand and the
// test is what keeps them honest: `tests/test_cloud_gpu.gd` bakes through both paths and compares. The
// comment on each says what the GDScript constant is.

const float CLOUD_PI = 3.141592653589793;
const float CLOUD_TAU = 6.283185307179586;
// `SpacesimCloudField.EDDY_STRETCH` — **1.0, isotropic, and it was 3.0.**
//
// A factor of three squeezes this domain east-west and therefore *manufactures* filaments: that is cirrus, and it was
// the wrong mechanism for a moisture layer. Evert, 2026-10-29: *"the shader should look more like cumulus, and less
// like cirrus type clouds, since we are doing the moisture layer now, and might make an ice type layer for the cirrus
// clouds later."* A cumulus clump is round; cirrus returns as an ice layer's own stretch and soft edge, not as a
// compromise here.
const float CLOUD_EDDY_STRETCH = 1.0;
// `SpacesimCloudField.SHEAR` — **the differential rotation, in radians of longitude at its strongest.**
//
// The mechanism the vortex stack was standing in for, and it is nearly free: a zonal wind profile displaces longitude by
// an amount that depends on latitude, so a band is dragged against its neighbour and its parcels smear *along* it. That
// is what makes a belt read as a belt, and it is what a 3:1 texture stretch was faking badly — the stretch made every
// parcel a filament everywhere, while shear makes the elongation a property of *where the parcel is*.
const float CLOUD_SHEAR = 0.35;
// `SpacesimCloudField.CURL_STRENGTH`, `CURL_SCALE`, `CURL_STRETCH`, `CURL_EPSILON` — **the local swirl, as curl noise.**
//
// The curl of a scalar field in the tangent plane, which is **divergence-free**: material is carried rather than created
// or destroyed, and that is the property that makes it read as flow instead of as a warp. It costs three noise samples
// (one value and two forward differences polarisations) rather than 96 vortices.
const float CLOUD_CURL_STRENGTH = 0.03;
const float CLOUD_CURL_SCALE = 2.0;
const float CLOUD_CURL_STRETCH = 1.6;
// **The difference step, as a FRACTION OF THE FEATURE.** A fixed step was the bug: 0.02 rad against a parcel-scale
// noise (feature 0.06, sampled at `1/feature` ≈ 16 rad⁻¹) moves the sample a *third of a feature*, so the "gradient"
// was a noise difference rather than a derivative — an unbounded number that displaced the sample by tens of degrees.
// A forward difference is only a derivative while `step × frequency ≪ 1`, and that is a statement about the feature.
const float CLOUD_CURL_STEP = 0.05;

// `SpacesimCloudField.CUMULUS_EDGE` — **how sharp a clump's edge is**, as a fraction of the field's range.
//
// This is residence time: a cell that rains out in an hour has a crisp boundary and ice that persists for a day is
// smeared. The model does not carry residence time, so this is the constant that stands in for it, and it is named
// here so the next reader knows what it is waiting for.
const float CLOUD_CUMULUS_EDGE = 0.12;
// `SpacesimCloudField.MEANDER_SECOND`, `MEANDER_SECOND_SHARE`
const float CLOUD_MEANDER_SECOND = 0.618;
const float CLOUD_MEANDER_SECOND_SHARE = 0.6;
// `SpacesimCloudField.FINE_SHARE`
const float CLOUD_FINE_SHARE = 0.55;
// `SpacesimCloudField.SOFT_KNEE`
const float CLOUD_SOFT_KNEE = 0.85;
// `SpacesimCloudField.VORTEX_BUDGET` — a cross-language invariant, like `cell_of` in the star
// catalogue: the runner refuses a stack larger than this rather than quietly dropping vortices.
const int CLOUD_VORTEX_MAX = 96;

// The four derived numbers `SpacesimCloudField.intensity_at()` now takes as scalars.
struct CloudField {
	float mix_value;
	float cells;
	float ratio;
	float feature;
	float phase;
	float meander;
};

// The generator's parameters, from `noise_for()` / `fine_for()`.
struct CloudNoise {
	int seed;
	float frequency;
	int octaves;
	float gain;
	float lacunarity;
	float bounding;
};


// `SpacesimCloudModel.condensation_favouring()`: 0 at sinking air, 1 at rising, one cosine per cell.
float cloud_condensation_favouring(float latitude, float cells) {
	if (cells <= 0.0) {
		return 1.0;
	}
	float span = (CLOUD_PI * 0.5) / cells;
	float turn = CLOUD_PI * abs(latitude) / span;
	return (1.0 + cos(turn)) * 0.5;
}


// `SpacesimCloudField.bands_at()`: the bands, with the meander that makes them weather rather than a
// valance. The wavenumber is **rounded to a whole number** because only whole waves close round a
// planet — that is a physical constraint, not a tidy-up, and the seam test is what found it.
float cloud_bands_at(vec3 direction, float cells, float ratio, float phase, float meander) {
	float latitude = asin(clamp(direction.y, -1.0, 1.0));
	if (cells <= 0.0) {
		return 1.0;
	}
	if (ratio <= 0.0 || meander <= 0.0) {
		return cloud_condensation_favouring(latitude, cells);
	}
	float longitude = atan(direction.z, direction.x);
	float band_width = (CLOUD_PI * 0.5) / cells;
	float wavenumber = max(1.0, round(max(cos(latitude), 0.0) / ratio));
	float first = sin(wavenumber * longitude + phase);
	float second = sin(wavenumber * CLOUD_MEANDER_SECOND * longitude + phase * 1.7);
	float offset = meander * band_width * (first + CLOUD_MEANDER_SECOND_SHARE * second)
		/ (1.0 + CLOUD_MEANDER_SECOND_SHARE);
	return cloud_condensation_favouring(latitude + offset, cells);
}


// **The eddy stack lives in WORKGROUP memory, and the kernel stages it there.** Every texel in a thread's
// work needs all 96 vortices, so an `std430` read per texel per vortex is ~3 GB of buffer traffic for one
// 8192x4096 map — and it measured as **82% of the kernel's cost** (5.65 ns/texel, against 1.01 with the
// stack bypassed). A dozen lines in the kernel load it once per 64-texel tile instead.
//
// `shared` is compute-only, so **this include is now compute-only too** — which it always was in practice:
// nothing else compiles it.
shared vec4 cloud_centres[CLOUD_VORTEX_MAX];
shared vec4 cloud_twists[CLOUD_VORTEX_MAX];


// `SpacesimCloudField.advect()`: the tangential turn each vortex applies, summed over the stack. A turn
// and not a push — a translation can wave a field but never spiral it.
//
// `cloud_centres` carries the centre in `xyz` and `1 - cos(reach)` in `w`; `cloud_twists` carries the
// radians in `x`. Two arrays rather than one struct array because that is what an `std430` buffer of
// `vec4`s is, and it keeps every entry 16-byte aligned — the staging loop in the kernel copies one into
// the other unchanged.
//
// **The arrays are globals rather than parameters**, and that is the point: an array parameter is passed
// by value, so passing the shared arrays in would copy 3 KB into private memory on every call and cost
// more than it saved.
vec3 cloud_advect(vec3 unit, int count) {
	vec3 twist = vec3(0.0);
	for (int index = 0; index < count; index++) {
		vec3 centre = cloud_centres[index].xyz;
		float falloff = 1.0 - (1.0 - dot(unit, centre)) / cloud_centres[index].w;
		if (falloff <= 0.0) {
			continue;
		}
		twist += cross(centre, unit) * (cloud_twists[index].x * falloff * falloff);
	}
	return normalize(unit + twist);
}


// `SpacesimCloudField.eddy_at()`: the noise at a unit direction, 0 to 1 with its mean at a half, squeezed
// in the equatorial components so the features are stretched **east-west**. Dividing `y` instead made
// vertical fibre, which is the opposite of what a zonal jet does.
//
// **`footprint` is the angle one pixel spans, and `0.0` means no limit** — which is what a bake passes, because a bake's
// own raster is its resolution. A *drawing* caller passes its pixel and gets the eddies faded where they are finer than
// it can resolve; that is the band limit every mechanism here obeys, and it is what makes the field affordable to
// evaluate per pixel instead of caching it in a map.
float cloud_eddy_at(vec3 unit, float feature, CloudNoise noise, float footprint) {
	if (feature <= 0.0) {
		return 0.5;
	}
	vec3 stretched = normalize(vec3(
		unit.x / CLOUD_EDDY_STRETCH, unit.y, unit.z / CLOUD_EDDY_STRETCH));
	return (fnl_fbm3_banded(
		stretched / feature, noise.seed, noise.frequency, noise.octaves,
		noise.gain, noise.lacunarity, noise.bounding, footprint
	) + 1.0) * 0.5;
}


// **Differential rotation**: longitude displaced by a latitude-dependent angle, so bands drag against each other.
//
// The form uses the band wave itself — `sin(cells · lat)` is one turn per circulation cell, which is the shape a zonal
// wind profile has (eastward in a zone, reversing between) — so the shear is strongest where the bands meet and zero at
// a band's centre. **The bands stay where they are; their contents are dragged along them.** That is the difference
// between this and a texture stretch: the stretch is uniform, this is a property of latitude.
vec3 cloud_sheared(vec3 unit, float cells, float phase) {
	if (CLOUD_SHEAR == 0.0) {
		return unit;
	}
	float latitude = asin(clamp(unit.y, -1.0, 1.0));
	float longitude = atan(unit.z, unit.x) + CLOUD_SHEAR * sin(cells * latitude * CLOUD_PI + phase);
	float ring = sqrt(max(1.0 - unit.y * unit.y, 0.0));
	return vec3(ring * cos(longitude), unit.y, ring * sin(longitude));
}


// The scalar the curl is taken of: the same generator, at `CURL_SCALE` times the parcel frequency, mildly anisotropic
// so the swirl is longer east-west than north-south — a zonal flow, not an isotropic fizz.
float cloud_swirl_at(vec3 unit, float feature, CloudNoise noise, float footprint) {
	vec3 stretched = normalize(vec3(
		unit.x / CLOUD_CURL_STRETCH, unit.y, unit.z / CLOUD_CURL_STRETCH));
	// **The swirl lives at the parcel scale**, so its frequency is the parcel's — `1/feature`, times the one look
	// constant that makes the swirl slightly larger than a parcel. `noise.seed + 4001` is this body's generator at a
	// second seed, which is what `SpacesimCloudField.swirl_for()` builds on the CPU side.
	float scale = CLOUD_CURL_SCALE / max(feature, 1.0e-4);
	return fnl_fbm3_banded(
		stretched * scale, noise.seed + 4001, 1.0, noise.octaves,
		noise.gain, noise.lacunarity, noise.bounding, footprint
	);
}


// **Curl noise**: the curl of a scalar field in the tangent plane — **divergence-free**, so it carries material instead
// of creating or destroying it, which is why it reads as flow rather than as a warp. Forward differences, so three
// samples of one generator rather than an analytic derivative the noise does not carry.
vec3 cloud_swirled(vec3 unit, float feature, CloudNoise noise, float footprint) {
	if (feature <= 0.0) {
		return unit;
	}
	vec3 polar = abs(unit.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 east = normalize(cross(unit, polar));
	vec3 north = cross(east, unit);
	float step = max(feature * CLOUD_CURL_STEP, 1.0e-5);
	float value_here = cloud_swirl_at(unit, feature, noise, footprint);
	float value_east = cloud_swirl_at(normalize(unit + east * step), feature, noise, footprint);
	float value_north = cloud_swirl_at(normalize(unit + north * step), feature, noise, footprint);
	vec3 gradient = (
		east * (value_east - value_here) + north * (value_north - value_here)
	) / step;
	// Rotating the gradient a quarter turn in the tangent plane IS the curl of a 2-D scalar.
	//
	// **The displacement is bounded by `CLOUD_CURL_STRENGTH`** through `x / (1 + |x|)`: the gradient's magnitude is
	// `1/feature` — sixteen per radian on Earth — so scaling it directly would move the sample by half a radian. The
	// saturation keeps most of the *variation* (a strong curl still moves further than a weak one) while making the
	// number in the constant mean what it says: radians.
	vec3 swirl = cross(unit, gradient);
	return normalize(unit + CLOUD_CURL_STRENGTH * (swirl / (1.0 + length(swirl))));
}




// `SpacesimCloudField._soft_ceiling()`: below the knee nothing changes; above it the excess is mapped
// asymptotically into the rest of the range, so the top stays ordered instead of piling onto one value.
// A hard clamp was tried and broke the percentile threshold; normalising by `1 + mix` was tried and broke
// the light budget.
float cloud_soft_ceiling(float value) {
	if (value <= CLOUD_SOFT_KNEE) {
		return max(value, 0.0);
	}
	return CLOUD_SOFT_KNEE + (1.0 - CLOUD_SOFT_KNEE) * (
		1.0 - exp(-(value - CLOUD_SOFT_KNEE) / (1.0 - CLOUD_SOFT_KNEE)));
}


// **`SpacesimCloudField.intensity_at()`**, in the order the physics puts it: carry the sample with the
// eddies, read the bands at the carried position so an arm can drag cloud across a lane, and read the
// eddies at the carried position too so the texture inside the arm is the arm's own. The fine half is
// sampled at the **still** direction, which is what lets detail sit still while the shapes swirl.
//
// `has_fine` is the C++'s `fine != null`: a caller with one generator gets no high half, not a quiet one.
float cloud_intensity_from(
	vec3 unit, vec3 carried, CloudField field, CloudNoise coarse, bool has_coarse, CloudNoise fine,
	bool has_fine, float footprint
) {
	float envelope = field.mix_value + (1.0 - field.mix_value) * cloud_bands_at(
		carried, field.cells, field.ratio, field.phase, field.meander);
	if (!has_coarse || field.mix_value <= 0.0) {
		return envelope;
	}
	// **The flow first, then the parcels.** Shear is the large scale (a band drags its own contents), the curl is the
	// local swirl, and the clump is what both are applied to. The fine half stays at the *still* direction, as it always
	// has: detail that swirls with the coarse field was the baroque filigree `Cloud Layers` §10 warned about.
	vec3 sheared = cloud_sheared(carried, field.cells, field.phase);
	vec3 shaped = cloud_swirled(sheared, field.feature, coarse, footprint);
	float clump = cloud_eddy_at(shaped, field.feature, coarse, footprint);
	if (has_fine) {
		clump = clamp(
			clump + (cloud_eddy_at(unit, field.feature, fine, footprint) - 0.5) * CLOUD_FINE_SHARE,
			0.0, 1.0
		);
	}
	// **THE CLUMP CARVES THE PARCELS; THE ENVELOPE SETS HOW THICK EACH ONE IS.**
	//
	// Cumulus is air lifting in parcels, so the *parcel* has to be a crisp-edged thing and the moisture has to be the
	// depth of it. Two lines, in that order:
	//
	// 1. **the clump is thresholded at its own middle**, with `CLOUD_CUMULUS_EDGE` as the width — that is the crisp
	//    edge, and residence time is what would set it;
	// 2. **the envelope multiplies it**, so a belt is a thick parcel and a lane is a thin one. That is what makes
	//    belts visible as belts: same parcels, different depths.
	//
	// **The first version of this law thresholded at `1 - envelope`, and the probe caught it in one run.** For Earth the
	// floor is high, so the envelope is ~0.9 everywhere, `1 - envelope` is ~0.1, and against a bell-shaped clump
	// almost the entire distribution sat above it: p10 came out at **0.851** and the variogram at **0.0005** — a field
	// with no contrast at all, which reads as a flat veil. **A threshold that is meant to be a coverage has to be a
	// QUANTILE, not a level**, and the quantile is already the deck's business: `threshold_for()` picks it from the
	// measured distribution so the drawn coverage is the authored one. So the field's job is the *pattern* — crisp
	// parcels, graded by moisture — and the calibration's job is how much of the sky they cover.
	float parcel = smoothstep(
		0.5 - CLOUD_CUMULUS_EDGE, 0.5 + CLOUD_CUMULUS_EDGE, clump
	);
	return cloud_soft_ceiling(parcel * envelope);
}


float cloud_intensity_at(
	vec3 direction, CloudField field, CloudNoise coarse, bool has_coarse, CloudNoise fine, bool has_fine,
	int count
) {
	// The exact path: compute the flow here. This is what a bake uses, and it is the reference the cached flow is
	// checked against — `tests/test_cloud_gpu.gd` compares the two texel for texel.
	return cloud_intensity_from(
		normalize(direction), cloud_advect(normalize(direction), count),
		field, coarse, has_coarse, fine, has_fine, 0.0
	);
}


// **The same field, with the flow SUPPLIED** — the carried direction, already advected.
//
// This is the split that makes the field affordable per pixel, and it is a split by *scale*, not an approximation:
//
// - **the flow is smooth.** Its finest structure is the smallest vortex's reach — about 9° of arc — so it does not
//   need the pixel, and it does not depend on the layer's coverage, albedo or optical depth. Baked once per body it is
//   a 512-texel map that is never refined, which is why the deck can stop carrying a coverage map that refines.
// - **the texture needs the pixel.** The bands are closed form and the eddies are noise; both are what change when the
//   eye comes close, and both are band-limited by `footprint`.
//
// **`footprint` is the drawing caller's pixel angle, and `0.0` means no limit.** A bake passes 0 so the statistics it
// measures are the field's own — the percentiles the colour and the opacity are fitted to must not depend on what some
// frame happened to resolve.
