shader_type spatial;
render_mode blend_mix, cull_back, diffuse_burley, specular_schlick_ggx;

// The cloud deck, drawn on its own sphere a little above the surface.
//
// **The authored cloud fraction is the coverage, directly.** Noise above a threshold is cloud, and the
// threshold is set from the fraction, so a body content says is 60% covered is 60% covered — rather
// than the fraction being a number the shader ignores while a hand-tuned constant does the real work.
//
// **The field is sampled on the unit sphere, not in world metres** — see the long note in
// `body_surface.gdshader`. Sampling world position on a body millions of metres across puts every
// pixel in an arbitrary voxel, which is what a dense cloud of dots *is*.

uniform vec3 cloud_color : source_color = vec3(1.0);
uniform float coverage : hint_range(0.0, 1.0) = 0.0;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
uniform float edge_softness : hint_range(0.001, 0.5) = 0.12;
uniform float noise_scale : hint_range(0.1, 32.0) = 4.0;
uniform vec3 noise_offset = vec3(0.0);
uniform sampler3D noise_field : filter_linear, repeat_enable;

// Model space: the offset from the body's centre.
varying vec3 local_position;

void vertex() {
	local_position = VERTEX;
}

void fragment() {
	vec3 direction = normalize(local_position);
	float n = texture(noise_field, (direction + noise_offset) * noise_scale).r;

	// More coverage means a lower bar for what counts as cloud.
	float threshold = 1.0 - coverage;
	float cloud = smoothstep(threshold - edge_softness, threshold + edge_softness, n);

	ALBEDO = cloud_color;
	ALPHA = cloud * opacity;
	ROUGHNESS = 0.9;
	SPECULAR = 0.1;
}
