// **FastNoiseLite in GLSL** — the noise half of the field generator, on its own so that more than one
// consumer reaches it. **One copy of the noise, two ways in.**
//
// It lives in its own file because the two consumers compile differently:
//
//  - `SpacesimCloudGpu`/`SpacesimSurfaceGpu` assemble it as TEXT with a kernel and hand the result to
//    `shader_compile_spirv_from_source()`, which processes no directives — so `_source()` concatenates
//    this file in front of the kernel on purpose;
//  - a Godot fragment shader reaches it with `#include`, and will, when the surface's detail ladder lands.
//
// **It declares no `shared` memory, which is what makes it legal in a fragment shader at all.** The cloud
// field's vortex stack does not have that luxury and stays compute-only.
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
// The subset is **OpenSimplex2S in 3D**, FBM with `fractal_octaves`, `fractal_gain` and
// `fractal_lacunarity`, weighted strength 0, no domain warp. `NOISE_TYPE = TYPE_SIMPLEX_SMOOTH` is
// `NoiseType_OpenSimplex2S`, and the 3D transform for it is `TransformType3D_DefaultOpenSimplex2` — the
// R3 rotation, which the C++ keeps in `TransformNoiseCoordinate` and which `fnl_fbm3()` applies before
// the octave loop.
//
// **Precision**: the CPU runs `FastNoiseLite` in `double` (this build has `precision=double`), the GPU in
// `float`. The comparison tolerance is therefore set by the format the consumer writes, not by this file;
// `tests/test_cloud_gpu.gd` compares one level of a baked byte, and the surface's R16F map compares at
// half precision.

const int FNL_PRIME_X = 501125321;
const int FNL_PRIME_Y = 1136930381;
const int FNL_PRIME_Z = 1720413743;

// `Lookup<float>::Gradients3D` verbatim: 64 gradient triplets, each padded to four entries, indexed by
// `hash & (63 << 2)` so the padding is part of the layout and not removable.
const float FNL_GRADIENTS_3D[256] = float[256](
	0.0, 1.0, 1.0, 0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, -1.0, -1.0, 0.0,
	1.0, 0.0, 1.0, 0.0, -1.0, 0.0, 1.0, 0.0, 1.0, 0.0, -1.0, 0.0, -1.0, 0.0, -1.0, 0.0,
	1.0, 1.0, 0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, -1.0, -1.0, 0.0, 0.0,
	0.0, 1.0, 1.0, 0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, -1.0, -1.0, 0.0,
	1.0, 0.0, 1.0, 0.0, -1.0, 0.0, 1.0, 0.0, 1.0, 0.0, -1.0, 0.0, -1.0, 0.0, -1.0, 0.0,
	1.0, 1.0, 0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, -1.0, -1.0, 0.0, 0.0,
	0.0, 1.0, 1.0, 0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, -1.0, -1.0, 0.0,
	1.0, 0.0, 1.0, 0.0, -1.0, 0.0, 1.0, 0.0, 1.0, 0.0, -1.0, 0.0, -1.0, 0.0, -1.0, 0.0,
	1.0, 1.0, 0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, -1.0, -1.0, 0.0, 0.0,
	0.0, 1.0, 1.0, 0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, -1.0, -1.0, 0.0,
	1.0, 0.0, 1.0, 0.0, -1.0, 0.0, 1.0, 0.0, 1.0, 0.0, -1.0, 0.0, -1.0, 0.0, -1.0, 0.0,
	1.0, 1.0, 0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, -1.0, -1.0, 0.0, 0.0,
	0.0, 1.0, 1.0, 0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, -1.0, -1.0, 0.0,
	1.0, 0.0, 1.0, 0.0, -1.0, 0.0, 1.0, 0.0, 1.0, 0.0, -1.0, 0.0, -1.0, 0.0, -1.0, 0.0,
	1.0, 1.0, 0.0, 0.0, -1.0, 1.0, 0.0, 0.0, 1.0, -1.0, 0.0, 0.0, -1.0, -1.0, 0.0, 0.0,
	1.0, 1.0, 0.0, 0.0, 0.0, -1.0, 1.0, 0.0, -1.0, 1.0, 0.0, 0.0, 0.0, -1.0, -1.0, 0.0
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
