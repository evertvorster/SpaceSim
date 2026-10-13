shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// The surface layer. What a body is *made of* arrives as colours; this turns one flat albedo into a
// planet by varying it over a noise field and giving the variation relief.
//
// **THE NOISE IS SAMPLED ON THE UNIT SPHERE, NOT IN WORLD METRES.** That is not a detail — sampling
// world position makes every pixel land on an arbitrary voxel, because a planet is millions of metres
// across and the field is 64 voxels: adjacent pixels differ by ~64 km, which is ~160,000 texture units
// at any usable scale. The result is a dense cloud of dots rather than structure, and float32 spacing
// at astronomical coordinates (~32,768) makes it worse. Planet 3D normalises for exactly this reason.
// A unit direction puts adjacent pixels 0.06 of a voxel apart instead.
//
// The local position is captured in `vertex()` because **`VERTEX` inside `fragment()` is in VIEW
// space**, not model space.

uniform vec3 base_color : source_color = vec3(0.5, 0.5, 0.5);
uniform vec3 detail_color : source_color = vec3(0.5, 0.5, 0.5);
// Where the blend sits, and how soft it is: a two-stop height gradient.
uniform float detail_mix : hint_range(0.0, 1.0) = 0.5;
uniform float detail_softness : hint_range(0.001, 0.5) = 0.15;
uniform float noise_scale : hint_range(0.1, 32.0) = 6.0;
// The knob for how pronounced the relief is. It multiplies a true gradient, so it is small.
uniform float relief : hint_range(0.0, 0.5) = 0.05;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.9;
uniform float specular_value : hint_range(0.0, 1.0) = 0.2;
// A per-body offset, so two bodies with the same settings do not wear the same surface.
uniform vec3 noise_offset = vec3(0.0);
uniform sampler3D noise_field : filter_linear, repeat_enable;

// Model space: the offset from the body's centre.
varying vec3 local_position;

void vertex() {
	local_position = VERTEX;
}

// The field at a unit direction, shifted so each body gets its own place in it.
float field(vec3 direction) {
	return texture(noise_field, (direction + noise_offset) * noise_scale).r;
}

void fragment() {
	// One direction per surface point, and the same one for every pixel that shares it.
	vec3 p = normalize(local_position);
	float height = field(p);

	// Colour by height — the gradient, in its simplest honest form: two stops.
	float blend = smoothstep(detail_mix - detail_softness, detail_mix + detail_softness, height);
	ALBEDO = mix(base_color, detail_color, blend);
	ROUGHNESS = roughness_value;
	SPECULAR = specular_value;

	// Relief from the field's gradient, projected onto the surface so it perturbs the normal without
	// tilting it off the sphere. Finite differences in direction space; `e` is chosen so the step in
	// the *texture* stays constant however the scale is set.
	float e = 0.02 / max(noise_scale, 0.001);
	vec3 gradient = vec3(field(p + vec3(e, 0.0, 0.0)) - height,
		field(p + vec3(0.0, e, 0.0)) - height,
		field(p + vec3(0.0, 0.0, e)) - height) / e;

	vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	gradient -= world_normal * dot(gradient, world_normal);
	vec3 bumped = normalize(world_normal - gradient * relief);
	NORMAL = normalize((VIEW_MATRIX * vec4(bumped, 0.0)).xyz);
}
