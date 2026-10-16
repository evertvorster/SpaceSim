shader_type spatial;
// `cull_disabled` because one shell has to serve both sides of itself: from space you see the deck's
// TOP, and from the ground the same sphere is your ceiling. Drawing both faces lets depth decide —
// the far side is behind the planet from outside, and behind nothing from inside. It also means a
// grazing ray at the limb crosses the shell twice and blends twice, which is roughly what a long
// tangential path through cloud should do.
render_mode blend_mix, cull_disabled, specular_disabled;

// The cloud deck: one shell of noise, drawn where the noise says there is cloud.
//
// ---------------------------------------------------------------- WHAT IT IS NOT
//
// **Not additive.** The air is `blend_add` because a sky is something you look *through*; a deck is
// something you look *at*, and it has to **occlude** what is behind it. That is the whole reason this
// is a second material rather than another term in the atmosphere's.
//
// **Not at `radius * 1.012`.** That is a fraction of the body, and it is what made the previous deck
// the outermost silhouette of every world — 76 km above Earth against a real cloud top of 10–12.
// **The altitude is derived**: it is the condensation level, so it is a real height above a real
// surface, and it moves with the air rather than with the planet's size.
//
// ---------------------------------------------------------------- COVERAGE
//
// **`threshold` is a PERCENTILE of this field, not `1 - cover`.** A threshold gives the fraction of the
// field *above* it, which is the authored fraction only if the distribution is known — so the host
// measures the field and hands over the percentile, and a test asserts that the achieved coverage is
// the requested one. Assuming it was what made the first deck's coverage a guess.
//
// **The field is sampled on the UNIT SPHERE, and only mapped into the texture — never scaled by it.**
// Sampling in world metres puts every pixel in an arbitrary voxel (a field of dots), and *scaling* the
// direction before sampling wraps the texture, which at scale 4 repeats as a visible 8x8 grid of
// patches. `direction * 0.25 + 0.5` uses a quarter of the texture and cannot wrap; the detail comes
// from what the texture itself holds. Same mapping as the surface shader, and the same two traps.

uniform vec3 cloud_color : source_color = vec3(1.0);
// The thin edge and the shadowed underside. Derived from `cloud_color` by the host rather than
// hand-picked, so a deck keeps its identity while gaining structure.
uniform vec3 edge_color : source_color = vec3(0.7);
uniform float threshold : hint_range(0.0, 1.0) = 0.5;
uniform float softness : hint_range(0.001, 0.5) = 0.06;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
uniform float noise_scale : hint_range(0.1, 2.0) = 1.0;
uniform vec3 noise_offset = vec3(0.0);
uniform sampler3D noise_field : filter_linear, repeat_enable;

// Model space, the offset from the body's centre — which for a unit sphere IS its direction. Captured
// in `vertex()` because **`VERTEX` inside `fragment()` is in VIEW space**.
varying vec3 local_position;


void vertex() {
	local_position = VERTEX;
}


// The field at a unit direction, shifted so each body gets its own place in it. Identical to the
// surface shader's, and it has to be: the deck's shadow is sampled from this same field.
float field(vec3 direction) {
	return texture(noise_field, direction * (0.25 * noise_scale) + vec3(0.5) + noise_offset).r;
}


void fragment() {
	vec3 p = normalize(local_position);
	float height = field(p);
	// Coverage, with a soft edge of its own width so the deck has a boundary rather than a stencil.
	float cover = smoothstep(threshold - softness, threshold + softness, height);
	// The edge of a cloud is its thinnest part, so the same number drives colour and alpha: a soft
	// boundary is also a thin one, which is what makes a deck read as cloud rather than as cut paper.
	ALBEDO = mix(edge_color, cloud_color, cover);
	ALPHA = cover * opacity;
	ROUGHNESS = 0.9;
}
