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
// `SpacesimCloudField.EDDY_STRETCH`
const float CLOUD_EDDY_STRETCH = 3.0;
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
float cloud_eddy_at(vec3 unit, float feature, CloudNoise noise) {
	if (feature <= 0.0) {
		return 0.5;
	}
	vec3 stretched = normalize(vec3(
		unit.x / CLOUD_EDDY_STRETCH, unit.y, unit.z / CLOUD_EDDY_STRETCH));
	return (fnl_fbm3(
		stretched / feature, noise.seed, noise.frequency, noise.octaves,
		noise.gain, noise.lacunarity, noise.bounding
	) + 1.0) * 0.5;
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
float cloud_intensity_at(
	vec3 direction, CloudField field, CloudNoise coarse, bool has_coarse, CloudNoise fine, bool has_fine,
	int count
) {
	vec3 unit = normalize(direction);
	vec3 carried = cloud_advect(unit, count);
	float envelope = field.mix_value + (1.0 - field.mix_value) * cloud_bands_at(
		carried, field.cells, field.ratio, field.phase, field.meander);
	if (!has_coarse || field.mix_value <= 0.0) {
		return envelope;
	}
	float eddy = cloud_eddy_at(carried, field.feature, coarse);
	if (has_fine) {
		eddy = clamp(eddy + (cloud_eddy_at(unit, field.feature, fine) - 0.5) * CLOUD_FINE_SHARE, 0.0, 1.0);
	}
	return cloud_soft_ceiling(envelope * (1.0 - field.mix_value + field.mix_value * eddy * 2.0));
}
