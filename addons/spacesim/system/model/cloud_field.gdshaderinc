// **The cloud field, as GLSL** — the GPU twin of `SpacesimCloudField.intensity_at()`, and the reason it
// takes plain numbers rather than a `Morphology`.
//
// This file is not a `Shader`: it is read as TEXT, prepended with `#version 450` and a compute `main()`,
// and compiled through `RenderingDevice.shader_compile_spirv_from_source()`. That is why it carries no
// `#version`, no layout qualifiers and no entry point — and why the file is a `.gdshaderinc`, which is
// what tells Godot not to try to compile it on its own.
//
// ## The CPU path is the reference, and it stays
//
// `SpacesimCloudField.bake()` is not going away: it is the headless test surface for a
// visually-significant thing, and the thing this file is checked against. `tests/test_cloud_gpu.gd`
// bakes the same small map through both and compares byte for byte, so a divergence here is a test
// failure rather than a picture nobody can explain.
//
// ## The noise is a PORT, not an approximation
//
// GLSL has no usable noise built-ins — the language declares `noise3`, but the result is
// implementation-defined, the functions are deprecated, and **Vulkan has no noise instruction at all**,
// which is what this runs on. So `fnl_*` below is FastNoiseLite itself, transcribed from **the version
// Godot vendors** (`thirdparty/misc/FastNoiseLite.h` in the 4.7.2 source tree) rather than from the
// project's official GLSL port: the port tracks a newer release, and a subtle disagreement in a hash or
// a gradient table would be a field that looks plausible and does not match.
//
// The subset is exactly what `SpacesimCloudField.noise_for()` configures: **OpenSimplex2S in 3D**, FBM
// with `fractal_octaves`, `fractal_gain` and `fractal_lacunarity`, weighted strength 0, no domain warp.
// `NOISE_TYPE = TYPE_SIMPLEX_SMOOTH` is `NoiseType_OpenSimplex2S`, and the 3D transform for it is
// `TransformType3D_DefaultOpenSimplex2` — the R3 rotation, which the C++ keeps in
// `TransformNoiseCoordinate` and which `fnl_fbm3()` applies before the octave loop.
//
// **Precision**: the CPU runs this in `double` (this build has `precision=double`), the GPU in `float`.
// The comparison tolerance is therefore ±1 level on the baked byte, and the test reports the count.

const int FNL_PRIME_X = 501125321;
const int FNL_PRIME_Y = 1136930381;
const int FNL_PRIME_Z = 1720413743;

// `Lookup<float>::Gradients3D` verbatim: 64 gradient triplets, each padded to four entries, indexed by
// `hash & (63 << 2)` so the padding is part of the layout and not removable.
const float FNL_GRADIENTS_3D[256] = float[256](
	0, 1, 1, 0, 0, -1, 1, 0, 0, 1, -1, 0, 0, -1, -1, 0,
	1, 0, 1, 0, -1, 0, 1, 0, 1, 0, -1, 0, -1, 0, -1, 0,
	1, 1, 0, 0, -1, 1, 0, 0, 1, -1, 0, 0, -1, -1, 0, 0,
	0, 1, 1, 0, 0, -1, 1, 0, 0, 1, -1, 0, 0, -1, -1, 0,
	1, 0, 1, 0, -1, 0, 1, 0, 1, 0, -1, 0, -1, 0, -1, 0,
	1, 1, 0, 0, -1, 1, 0, 0, 1, -1, 0, 0, -1, -1, 0, 0,
	0, 1, 1, 0, 0, -1, 1, 0, 0, 1, -1, 0, 0, -1, -1, 0,
	1, 0, 1, 0, -1, 0, 1, 0, 1, 0, -1, 0, -1, 0, -1, 0,
	1, 1, 0, 0, -1, 1, 0, 0, 1, -1, 0, 0, -1, -1, 0, 0,
	0, 1, 1, 0, 0, -1, 1, 0, 0, 1, -1, 0, 0, -1, -1, 0,
	1, 0, 1, 0, -1, 0, 1, 0, 1, 0, -1, 0, -1, 0, -1, 0,
	1, 1, 0, 0, -1, 1, 0, 0, 1, -1, 0, 0, -1, -1, 0, 0,
	0, 1, 1, 0, 0, -1, 1, 0, 0, 1, -1, 0, 0, -1, -1, 0,
	1, 0, 1, 0, -1, 0, 1, 0, 1, 0, -1, 0, -1, 0, -1, 0,
	1, 1, 0, 0, -1, 1, 0, 0, 1, -1, 0, 0, -1, -1, 0, 0,
	1, 1, 0, 0, 0, -1, 1, 0, -1, 1, 0, 0, 0, -1, -1, 0
);


// `FastFloor`: truncation toward zero for positives, one less for negatives — i.e. `floor`.
int fnl_fast_floor(float f) {
	return int(floor(f));
}


int fnl_hash(int seed, int x_primed, int y_primed, int z_primed) {
	int hash = seed ^ x_primed ^ y_primed ^ z_primed;
	hash *= 0x27d4eb2d;
	return hash;
}


// The dot product with the table's gradient at `hash & (63 << 2)`.
float fnl_grad_coord(int seed, int x_primed, int y_primed, int z_primed, vec3 d) {
	int hash = fnl_hash(seed, x_primed, y_primed, z_primed);
	hash ^= hash >> 15;
	hash &= 63 << 2;
	return d.x * FNL_GRADIENTS_3D[hash]
		+ d.y * FNL_GRADIENTS_3D[hash | 1]
		+ d.z * FNL_GRADIENTS_3D[hash | 2];
}


// `SingleOpenSimplex2S` in 3D: two offset rotated cube grids. Transcribed statement for statement, because
// a tidier form is a different field — the masks, the `skip` flags and the two seeds are the algorithm.
float fnl_os2s3(int seed, vec3 p) {
	int i = fnl_fast_floor(p.x);
	int j = fnl_fast_floor(p.y);
	int k = fnl_fast_floor(p.z);
	float xi = p.x - float(i);
	float yi = p.y - float(j);
	float zi = p.z - float(k);

	i *= FNL_PRIME_X;
	j *= FNL_PRIME_Y;
	k *= FNL_PRIME_Z;
	int seed2 = seed + 1293373;

	int x_n_mask = int(-0.5 - xi);
	int y_n_mask = int(-0.5 - yi);
	int z_n_mask = int(-0.5 - zi);

	float x0 = xi + float(x_n_mask);
	float y0 = yi + float(y_n_mask);
	float z0 = zi + float(z_n_mask);
	float a0 = 0.75 - x0 * x0 - y0 * y0 - z0 * z0;
	float value = (a0 * a0) * (a0 * a0) * fnl_grad_coord(
		seed, i + (x_n_mask & FNL_PRIME_X), j + (y_n_mask & FNL_PRIME_Y),
		k + (z_n_mask & FNL_PRIME_Z), vec3(x0, y0, z0));

	float x1 = xi - 0.5;
	float y1 = yi - 0.5;
	float z1 = zi - 0.5;
	float a1 = 0.75 - x1 * x1 - y1 * y1 - z1 * z1;
	value += (a1 * a1) * (a1 * a1) * fnl_grad_coord(
		seed2, i + FNL_PRIME_X, j + FNL_PRIME_Y, k + FNL_PRIME_Z, vec3(x1, y1, z1));

	float x_a_flip0 = float(((x_n_mask | 1) << 1)) * x1;
	float y_a_flip0 = float(((y_n_mask | 1) << 1)) * y1;
	float z_a_flip0 = float(((z_n_mask | 1) << 1)) * z1;
	float x_a_flip1 = float(-2 - (x_n_mask << 2)) * x1 - 1.0;
	float y_a_flip1 = float(-2 - (y_n_mask << 2)) * y1 - 1.0;
	float z_a_flip1 = float(-2 - (z_n_mask << 2)) * z1 - 1.0;

	bool skip5 = false;
	float a2 = x_a_flip0 + a0;
	if (a2 > 0.0) {
		value += (a2 * a2) * (a2 * a2) * fnl_grad_coord(
			seed, i + (~x_n_mask & FNL_PRIME_X), j + (y_n_mask & FNL_PRIME_Y),
			k + (z_n_mask & FNL_PRIME_Z), vec3(x0 - float(x_n_mask | 1), y0, z0));
	} else {
		float a3 = y_a_flip0 + z_a_flip0 + a0;
		if (a3 > 0.0) {
			value += (a3 * a3) * (a3 * a3) * fnl_grad_coord(
				seed, i + (x_n_mask & FNL_PRIME_X), j + (~y_n_mask & FNL_PRIME_Y),
				k + (~z_n_mask & FNL_PRIME_Z),
				vec3(x0, y0 - float(y_n_mask | 1), z0 - float(z_n_mask | 1)));
		}

		float a4 = x_a_flip1 + a1;
		if (a4 > 0.0) {
			value += (a4 * a4) * (a4 * a4) * fnl_grad_coord(
				seed2, i + (x_n_mask & (FNL_PRIME_X * 2)), j + FNL_PRIME_Y, k + FNL_PRIME_Z,
				vec3(float(x_n_mask | 1) + x1, y1, z1));
			skip5 = true;
		}
	}

	bool skip9 = false;
	float a6 = y_a_flip0 + a0;
	if (a6 > 0.0) {
		value += (a6 * a6) * (a6 * a6) * fnl_grad_coord(
			seed, i + (x_n_mask & FNL_PRIME_X), j + (~y_n_mask & FNL_PRIME_Y),
			k + (z_n_mask & FNL_PRIME_Z), vec3(x0, y0 - float(y_n_mask | 1), z0));
	} else {
		float a7 = x_a_flip0 + z_a_flip0 + a0;
		if (a7 > 0.0) {
			value += (a7 * a7) * (a7 * a7) * fnl_grad_coord(
				seed, i + (~x_n_mask & FNL_PRIME_X), j + (y_n_mask & FNL_PRIME_Y),
				k + (~z_n_mask & FNL_PRIME_Z),
				vec3(x0 - float(x_n_mask | 1), y0, z0 - float(z_n_mask | 1)));
		}

		float a8 = y_a_flip1 + a1;
		if (a8 > 0.0) {
			value += (a8 * a8) * (a8 * a8) * fnl_grad_coord(
				seed2, i + FNL_PRIME_X, j + (y_n_mask & (FNL_PRIME_Y << 1)), k + FNL_PRIME_Z,
				vec3(x1, float(y_n_mask | 1) + y1, z1));
			skip9 = true;
		}
	}

	bool skip_d = false;
	float a_a = z_a_flip0 + a0;
	if (a_a > 0.0) {
		value += (a_a * a_a) * (a_a * a_a) * fnl_grad_coord(
			seed, i + (x_n_mask & FNL_PRIME_X), j + (y_n_mask & FNL_PRIME_Y),
			k + (~z_n_mask & FNL_PRIME_Z), vec3(x0, y0, z0 - float(z_n_mask | 1)));
	} else {
		float a_b = x_a_flip0 + y_a_flip0 + a0;
		if (a_b > 0.0) {
			value += (a_b * a_b) * (a_b * a_b) * fnl_grad_coord(
				seed, i + (~x_n_mask & FNL_PRIME_X), j + (~y_n_mask & FNL_PRIME_Y),
				k + (z_n_mask & FNL_PRIME_Z),
				vec3(x0 - float(x_n_mask | 1), y0 - float(y_n_mask | 1), z0));
		}

		float a_c = z_a_flip1 + a1;
		if (a_c > 0.0) {
			value += (a_c * a_c) * (a_c * a_c) * fnl_grad_coord(
				seed2, i + FNL_PRIME_X, j + FNL_PRIME_Y, k + (z_n_mask & (FNL_PRIME_Z << 1)),
				vec3(x1, y1, float(z_n_mask | 1) + z1));
			skip_d = true;
		}
	}

	if (!skip5) {
		float a5 = y_a_flip1 + z_a_flip1 + a1;
		if (a5 > 0.0) {
			value += (a5 * a5) * (a5 * a5) * fnl_grad_coord(
				seed2, i + FNL_PRIME_X, j + (y_n_mask & (FNL_PRIME_Y << 1)),
				k + (z_n_mask & (FNL_PRIME_Z << 1)),
				vec3(x1, float(y_n_mask | 1) + y1, float(z_n_mask | 1) + z1));
		}
	}

	if (!skip9) {
		float a9 = x_a_flip1 + z_a_flip1 + a1;
		if (a9 > 0.0) {
			value += (a9 * a9) * (a9 * a9) * fnl_grad_coord(
				seed2, i + (x_n_mask & (FNL_PRIME_X * 2)), j + FNL_PRIME_Y,
				k + (z_n_mask & (FNL_PRIME_Z << 1)),
				vec3(float(x_n_mask | 1) + x1, y1, float(z_n_mask | 1) + z1));
		}
	}

	if (!skip_d) {
		float a_d = x_a_flip1 + y_a_flip1 + a1;
		if (a_d > 0.0) {
			value += (a_d * a_d) * (a_d * a_d) * fnl_grad_coord(
				seed2, i + (x_n_mask & (FNL_PRIME_X << 1)), j + (y_n_mask & (FNL_PRIME_Y << 1)),
				k + FNL_PRIME_Z, vec3(float(x_n_mask | 1) + x1, float(y_n_mask | 1) + y1, z1));
		}
	}

	return value * 9.046026385208288;
}


// **`GetNoise(x, y, z)` with FBM**, which is what `FastNoiseLite.get_noise_3d()` is: the coordinate
// transform, then `GenFractalFBm()`. Two things the C++ does that a tidier port would lose:
//
//  - the **R3 rotation** (the `TransformType3D_DefaultOpenSimplex2` case) happens once, before the octave
//    loop, and only on the *first* octave's coordinates; the loop then scales by the lacunarity;
//  - the **seed advances per octave** (`seed++`), so the octaves are not the same field at two scales.
//
// `fractal_bounding` is `1 / (1 + g + g² + …)` over the octaves — computed on the host from the same two
// constants, so it cannot drift from the generator's.
//
// Weighted strength is 0 in Godot's default, which is what makes the amplitude a plain `amp *= gain`; a
// non-zero one would multiply it by `lerp(1, (noise + 1) * 0.5, weight)` and there is no caller for it.
float fnl_fbm3(
	vec3 p, int seed, float frequency, int octaves, float gain, float lacunarity, float fractal_bounding
) {
	p *= frequency;
	// `TransformType3D_DefaultOpenSimplex2`: rotation, not skew.
	float r = (p.x + p.y + p.z) * (2.0 / 3.0);
	p = vec3(r - p.x, r - p.y, r - p.z);

	float sum = 0.0;
	float amp = fractal_bounding;
	for (int octave = 0; octave < octaves; octave++) {
		sum += fnl_os2s3(seed + octave, p) * amp;
		p *= lacunarity;
		amp *= gain;
	}
	return sum;
}



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
