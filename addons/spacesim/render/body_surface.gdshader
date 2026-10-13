shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// The surface layer. What a body is *made of* arrives as colours; this turns one flat albedo into a
// planet by varying it over a noise field and giving the variation relief.
//
// The shape follows Planet 3D: a height field, colour and roughness by height. The height here comes
// from Godot's own 3D noise rather than a hand-written GLSL one — the engine already has it, and a
// re-implementation would only be a slower copy.
//
// Ponytail note: no vertex displacement yet. Relief is in the normal only, which costs nothing and
// removes the "painted ball" look; displacement is what the terrain/LOD work will want.

uniform vec3 base_color : source_color = vec3(0.5, 0.5, 0.5);
uniform vec3 detail_color : source_color = vec3(0.5, 0.5, 0.5);
// Where the blend sits, and how soft it is: a two-stop height gradient.
uniform float detail_mix : hint_range(0.0, 1.0) = 0.5;
uniform float detail_softness : hint_range(0.001, 0.5) = 0.15;
uniform float noise_scale : hint_range(0.1, 64.0) = 3.0;
uniform float relief : hint_range(0.0, 4.0) = 1.0;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.9;
uniform float specular_value : hint_range(0.0, 1.0) = 0.2;
// A per-body offset, so two bodies with the same settings do not wear the same surface.
uniform vec3 noise_offset = vec3(0.0);
uniform sampler3D noise_field : filter_linear, repeat_enable;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// The noise field sampled at a point, shifted so each body gets its own.
float field(vec3 p) {
	return texture(noise_field, (p + noise_offset) * noise_scale).r;
}

void fragment() {
	vec3 p = world_position;
	float height = field(p);

	// Colour by height — the gradient, in its simplest honest form: two stops.
	float blend = smoothstep(detail_mix - detail_softness, detail_mix + detail_softness, height);
	ALBEDO = mix(base_color, detail_color, blend);
	ROUGHNESS = roughness_value;
	SPECULAR = specular_value;

	// Relief from the field's gradient, projected onto the surface so it perturbs the normal without
	// tilting it off the sphere. Finite differences, one epsilon, three taps.
	float e = 0.02 / max(noise_scale, 0.001);
	vec3 gradient = vec3(field(p + vec3(e, 0.0, 0.0)) - height,
		field(p + vec3(0.0, e, 0.0)) - height,
		field(p + vec3(0.0, 0.0, e)) - height);

	vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	gradient -= world_normal * dot(gradient, world_normal);
	vec3 bumped = normalize(world_normal - gradient * relief);
	NORMAL = normalize((VIEW_MATRIX * vec4(bumped, 0.0)).xyz);
}
