// **The plan's numbers, as a compute kernel receives them** — the push-constant block and the `SurfacePlan`
// assembly, in one place because two kernels read them: the map bake (`surface_kernel.gdshaderinc`) and the
// per-direction heights (`surface_heights_kernel.gdshaderinc`).
//
// **A second copy of this block would be a second field.** The block's layout is byte-for-byte what
// `SpacesimSurfaceField.push_constants()` writes — 112 bytes, `ivec2`, two `vec2`, then twenty-two 4-byte fields —
// and the driver rejects both more and less, so a copy that drifted would fail loudly rather than quietly. The
// assembly is the part that would not: twenty-two assignments, and one of them left out is a field with a zero.
//
// **`size` and the two `vec2`s belong to the BAKE**, not to the field: a heights dispatch passes zeros and never
// reads them. They stay in the block because the offsets after them are the block's identity.
//
// No `#version`: this is concatenated after the noise and the field includes, and `#version` must be first in the
// assembled string.

layout(push_constant, std430) uniform Params {
	ivec2 size;
	// **The window**: a sub-rectangle of the same equirect space, so one field can be rasterised over the whole
	// sphere or over the cap the eye can actually see. `(0, 0, 1, 1)` is the whole map, which is what the
	// build-time bake asks for — **the window LAYERS on the base map, it never replaces it**, which is the fault
	// the cloud version had.
	vec2 uv_origin;
	vec2 uv_size;
	int seed;
	float continent_frequency;
	int continent_octaves;
	float ridge_frequency;
	int ridge_octaves;
	float warp_frequency;
	int warp_octaves;
	float warp_strength;
	float ridge_strength;
	float continent_share;
	float plate_bias_share;
	float belt_width;
	float plate_phase;
	float gain;
	float lacunarity;
	float continent_bounding;
	float warp_bounding;
	float region_frequency;
	int region_octaves;
	float region_share;
	float region_bounding;
	float mottle_plain_gain;
} params;


SurfacePlan surface_plan_params() {
	SurfacePlan plan;
	plan.seed = params.seed;
	plan.continent_frequency = params.continent_frequency;
	plan.continent_octaves = params.continent_octaves;
	plan.ridge_frequency = params.ridge_frequency;
	plan.ridge_octaves = params.ridge_octaves;
	plan.warp_frequency = params.warp_frequency;
	plan.warp_octaves = params.warp_octaves;
	plan.warp_strength = params.warp_strength;
	plan.ridge_strength = params.ridge_strength;
	plan.continent_share = params.continent_share;
	plan.plate_bias_share = params.plate_bias_share;
	plan.belt_width = params.belt_width;
	plan.plate_phase = params.plate_phase;
	plan.gain = params.gain;
	plan.lacunarity = params.lacunarity;
	plan.continent_bounding = params.continent_bounding;
	plan.warp_bounding = params.warp_bounding;
	plan.region_frequency = params.region_frequency;
	plan.region_octaves = params.region_octaves;
	plan.region_share = params.region_share;
	plan.region_bounding = params.region_bounding;
	plan.mottle_plain_gain = params.mottle_plain_gain;
	return plan;
}
