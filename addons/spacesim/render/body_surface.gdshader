shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// The surface layer: **a flat Lambertian in the body's derived albedo**, and nothing else.
//
// There is no mapping here and none is disabled. The previous attempt varied this albedo over a 3D noise
// field, blended two colour stops by the field's height and bumped the normal with its gradient — and it
// was the documented cause of a **black surface**, on airless bodies and on Earth alike. It went first to
// zero (`relief` 0, both stops the same colour) and then out entirely, so it cannot come back by a default.
//
// A surface mapping is a feature to be designed, with its own document, on a surface that subdivides —
// and the two things this shader is not allowed to do again are worth stating while the old code is still
// in recent memory:
//
//   * **do not sample the field in world metres.** A planet is millions of metres across and the field is
//     tens of voxels, so adjacent pixels land ~64 km apart in it: a dense cloud of dots rather than
//     structure, made worse by float32 spacing at astronomical coordinates. If a field is sampled at all,
//     it is sampled at a **unit direction**.
//   * **do not put the air's arithmetic in a material.** Air is one integral in one place; a per-material
//     approximation beside it applies the same air twice, and the two cannot be tuned together.

uniform vec3 base_color : source_color = vec3(0.5, 0.5, 0.5);
// **The debug tint, as a multiplier** — `render.depth_tint` publishes 1.0 or 0.0, so the picture is unchanged when it is
// off and the tree is legible when it is on. The colour itself is a vertex colour per patch (`SpacesimPatches.depth_tint`),
// so this shader does not need to know what a depth is.
uniform float tint_amount : hint_range(0.0, 1.0) = 0.0;

varying vec3 patch_tint;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.9;
uniform float specular_value : hint_range(0.0, 1.0) = 0.2;

// **The point the vertices are measured from**, in model space — the node's own origin, published with the transform.
// The mesh carries no normal array: on a unit sphere a point's direction from the centre IS its normal, and the centre
// is at `-patch_origin` in these coordinates, so the direction is `VERTEX + patch_origin`. That saves a normal per
// vertex in every upload, and it cannot disagree with the geometry because it is derived from it.
uniform vec3 patch_origin = vec3(0.0);

void vertex() {
	// The vertex colour, which is white on any mesh that supplies none.
	patch_tint = COLOR.rgb;
	// Normalising a 6,371 km vector is fine in float32: the *direction* only needs relative precision.
	NORMAL = normalize(VERTEX + patch_origin);
}


void fragment() {
	// **One line, and it is the only place the debug tint can change the picture.**
	ALBEDO = base_color.rgb * mix(vec3(1.0), patch_tint, tint_amount);
	ROUGHNESS = roughness_value;
	SPECULAR = specular_value;
}
