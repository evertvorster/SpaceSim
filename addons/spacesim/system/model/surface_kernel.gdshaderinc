// **The surface field's compute kernel** — the storage image, the plan's numbers, and the row/column to
// direction mapping the shader inverts.
//
// **Its own file because two bakes compile it**: `SpacesimSurfaceGpu` for the build-time map (which is read
// back so the field's distribution can be *measured*), and `SpacesimSurfaceBakePass`, which dispatches it on
// the **render thread** as the eye approaches. One text, two callers — a second copy here is a second field.
//
// No `#version` and no `#[compute]` marker: it is concatenated after the noise and the field includes and
// handed to `shader_compile_spirv_from_source()`, which processes no directives, so `#version` must be first
// in the assembled string and this file must not carry one.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r16f, set = 0, binding = 0) uniform image2D out_map;

layout(push_constant, std430) uniform Params {
	ivec2 size;
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
} params;

const float SURFACE_PI = 3.141592653589793;
const float SURFACE_TAU = 6.283185307179586;

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (pos.x >= params.size.x || pos.y >= params.size.y) {
		return;
	}
	// The map's own `(u, v)`: `u` around the equator, `v` pole to pole, north at the top row. **Pixel
	// centres, half a texel in**, so the seam and the poles land where the CPU path puts them and the
	// shader's inverse is exact.
	float u = (float(pos.x) + 0.5) / float(params.size.x);
	float v = (float(pos.y) + 0.5) / float(params.size.y);
	float latitude = SURFACE_PI * 0.5 - v * SURFACE_PI;
	float longitude = (u - 0.5) * SURFACE_TAU;
	float cos_latitude = cos(latitude);
	// Unit by construction: every direction is on the sphere the field is a function of.
	vec3 direction = vec3(
		cos_latitude * cos(longitude), sin(latitude), cos_latitude * sin(longitude));

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

	imageStore(out_map, pos, vec4(surface_height(direction, plan), 0.0, 0.0, 1.0));
}
