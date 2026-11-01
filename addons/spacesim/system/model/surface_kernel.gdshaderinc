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

// **The plan's block and its assembly** live in `surface_params.gdshaderinc`, which the ASSEMBLER places immediately
// before this file (`SpacesimSurfaceField.source()`) — **not a `#include`**, because a source string handed to
// `shader_compile_spirv_from_source()` gets no preprocessor: the concatenation is the include mechanism. The same
// file is placed before `surface_heights_kernel.gdshaderinc`, so the two kernels read one block.

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
	float u = params.uv_origin.x + (float(pos.x) + 0.5) / float(params.size.x) * params.uv_size.x;
	float v = params.uv_origin.y + (float(pos.y) + 0.5) / float(params.size.y) * params.uv_size.y;
	float latitude = SURFACE_PI * 0.5 - v * SURFACE_PI;
	float longitude = (u - 0.5) * SURFACE_TAU;
	float cos_latitude = cos(latitude);
	// Unit by construction: every direction is on the sphere the field is a function of.
	vec3 direction = vec3(
		cos_latitude * cos(longitude), sin(latitude), cos_latitude * sin(longitude));

	// **The plan, from the shared block** — see `surface_params.gdshaderinc`. Twenty-two assignments used to live
	// here and in the heights kernel would have been a second copy of them.
	SurfacePlan plan = surface_plan_params();

	imageStore(out_map, pos, vec4(surface_height(direction, plan, 0.0), 0.0, 0.0, 1.0));
}
