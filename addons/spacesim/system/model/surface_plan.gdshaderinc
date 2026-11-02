// **The field's PARAMETERS as uniforms, and the plan they assemble — a DRAW-shader file, and that is the point.**
//
// One home for the numbers the land and the sea both evaluate: a copy in a second shader would drift, which is what
// moved them here from `body_surface.gdshader` on 2026-11-01 when the ocean needed to know where the waterline is.
//
// **Why it is not in `surface_field.gdshaderinc`, where it spent a day**: that include is not only `#include`d by
// draw shaders — `SpacesimSurfaceField._assemble()` CONCATENATES it into a Vulkan compute source for
// `RenderingDevice`, for the bake and for the heights kernel. glslang refuses a non-opaque uniform outside a block
// there (`ERROR: 0:558: 'non-opaque uniforms outside a block' : not allowed when using GLSL for Vulkan`), so both
// kernels stopped compiling. The heights are the ground's only source of vertex displacement, so the surface
// silently published untranslated for the whole of 2026-11-01 — `heights()` returned empty and `_translate_surface`
// returned without a word.
//
// **The rule that follows**: an include reachable from a compute assembly may carry STRUCTS and FUNCTIONS and must
// carry no uniforms. A uniform is a draw-path fact, and this file is the boundary. `tests/test_render.gd` pins the
// split, because the failure mode is silence in one path and a perfectly good picture in the other.

uniform int field_seed = 0;
uniform float field_continent_frequency = 2.0;
uniform int field_continent_octaves = 5;
uniform float field_continent_share = 0.35;
uniform float field_continent_bounding = 1.0;
uniform float field_ridge_frequency = 11.0;
uniform int field_ridge_octaves = 4;
uniform float field_ridge_strength = 0.5;
uniform float field_warp_frequency = 3.0;
uniform int field_warp_octaves = 3;
uniform float field_warp_strength = 0.35;
uniform float field_warp_bounding = 0.5714;
uniform float field_region_frequency = 1.5;
uniform int field_region_octaves = 3;
uniform float field_region_share = 0.4;
uniform float field_region_bounding = 1.0;
uniform float field_plate_bias_share = 0.5;
uniform float field_belt_width = 0.08;
uniform float field_plate_phase = 0.0;
uniform float field_mottle_plain_gain = 0.25;
uniform float field_gain = 0.5;
uniform float field_lacunarity = 2.0;

SurfacePlan surface_plan() {
	SurfacePlan plan;
	plan.seed = field_seed;
	plan.continent_frequency = field_continent_frequency;
	plan.continent_octaves = field_continent_octaves;
	plan.continent_share = field_continent_share;
	plan.continent_bounding = field_continent_bounding;
	plan.ridge_frequency = field_ridge_frequency;
	plan.ridge_octaves = field_ridge_octaves;
	plan.ridge_strength = field_ridge_strength;
	plan.warp_frequency = field_warp_frequency;
	plan.warp_octaves = field_warp_octaves;
	plan.warp_strength = field_warp_strength;
	plan.warp_bounding = field_warp_bounding;
	plan.region_frequency = field_region_frequency;
	plan.region_octaves = field_region_octaves;
	plan.region_share = field_region_share;
	plan.region_bounding = field_region_bounding;
	plan.plate_bias_share = field_plate_bias_share;
	plan.belt_width = field_belt_width;
	plan.plate_phase = field_plate_phase;
	plan.mottle_plain_gain = field_mottle_plain_gain;
	plan.gain = field_gain;
	plan.lacunarity = field_lacunarity;
	return plan;
}
