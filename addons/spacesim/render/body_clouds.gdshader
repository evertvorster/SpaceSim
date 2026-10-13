shader_type spatial;
render_mode blend_mix, cull_back, diffuse_burley, specular_schlick_ggx;

// The cloud deck, drawn on its own sphere a little above the surface.
//
// **The authored cloud fraction is the coverage, directly.** Noise above a threshold is cloud, and
// the threshold is set from the fraction, so a body content says is 60% covered is 60% covered —
// rather than the fraction being a number the shader ignores while a hand-tuned constant does the
// real work.
//
// Ponytail note: the threshold assumes the noise is roughly evenly distributed, which FastNoiseLite
// is close enough to. A body whose fraction looks wrong is a sign the noise is being asked for
// something its distribution does not give, not a reason to fudge the fraction.

uniform vec3 cloud_color : source_color = vec3(1.0);
uniform float coverage : hint_range(0.0, 1.0) = 0.0;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
uniform float edge_softness : hint_range(0.001, 0.5) = 0.12;
uniform float noise_scale : hint_range(0.1, 64.0) = 4.0;
uniform vec3 noise_offset = vec3(0.0);
uniform sampler3D noise_field : filter_linear, repeat_enable;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float n = texture(noise_field, (world_position + noise_offset) * noise_scale).r;

	// More coverage means a lower bar for what counts as cloud.
	float threshold = 1.0 - coverage;
	float cloud = smoothstep(threshold - edge_softness, threshold + edge_softness, n);

	ALBEDO = cloud_color;
	ALPHA = cloud * opacity;
	ROUGHNESS = 0.9;
	SPECULAR = 0.1;
}
