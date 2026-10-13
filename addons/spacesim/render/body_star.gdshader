shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

// The star's own surface.
//
// **Unshaded, because a star is a source and not a reflector.** It was previously drawn with the
// ordinary surface material, which meant it was lit by its own light — and the light travels from the
// star toward the observer, so the near face was back-lit and rendered black.
//
// The colour is multiplied well past 1.0 on purpose: that is what puts it above the environment's
// `glow_hdr_threshold`, and bloom is how a star should read. Left at 1.0 it is simply a bright dot.
//
// Ponytail note: no limb darkening and no corona — both are real and both are later. This is a disc
// that glows.

uniform vec3 star_color : source_color = vec3(1.0);
// The bloom knob. The glow threshold is 1.0, so this is how far clear of it the star sits.
uniform float intensity = 24.0;

void fragment() {
	ALBEDO = star_color * intensity;
}
