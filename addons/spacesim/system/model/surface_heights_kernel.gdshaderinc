// **The surface field's heights, asked at a list of DIRECTIONS** — the field evaluated where the geometry needs it,
// rather than rasterised onto a grid and read back off one.
//
// **Why this exists.** A map answers "the height near (u, v)" on a lattice; a mesh has a few tens of thousands of
// explicit directions and no use for the rest. At 1 km altitude a facet is about 35 m across, so a global map fine
// enough to carry the mesh would be 10^12 texels — the arithmetic is in
// [[SpaceSim/Cloud Decks — the Ground's Mesh]]'s sibling note and in MemPalace, and it is why the refining raster
// went on 2026-10-28. This kernel evaluates `surface_height` — **the same GLSL the draw shader runs** — at exactly
// the directions the lattice holds, so the geometry and the colour cannot disagree by a texel or drift apart as two
// implementations.
//
// **No band limit, deliberately.** `footprint` is 0, which `surface_height` reads as *no limit*: a point's height is
// then a pure function of its direction and never changes when the LOD does, so refining a patch only adds points
// and never moves the ones already there. Band-limiting it later is a decision with a pop attached, not a default.
//
// Includes `surface_params.gdshaderinc` for the plan's block, so the numbers here are the bake's and the draw
// shader's, field for field.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// **`vec4` per direction, not `vec3`.** std430 gives a `vec3` a 16-byte stride anyway, and an explicit `vec4` says
// so out loud instead of relying on the caller to pad it.
layout(set = 0, binding = 0, std430) readonly buffer Directions {
	vec4 dirs[];
} input_dirs;

layout(set = 0, binding = 1, std430) writeonly buffer Heights {
	float values[];
} output_heights;


void main() {
	uint index = gl_GlobalInvocationID.x;
	// **The buffer is padded up to the workgroup size**, so the last group has threads with nothing to say — and a
	// bound here would need a number in the push-constant block, which the bake's layout owns. The host allocates
	// the padding and discards the tail, so there is no branch and nothing to get wrong.
	vec3 unit = normalize(input_dirs.dirs[index].xyz);
	output_heights.values[index] = surface_height(unit, surface_plan_params(), 0.0);
}
