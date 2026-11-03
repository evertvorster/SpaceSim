shader_type spatial;
// **The opaque interior of a body with no surface** — the floor under a gas giant's cloud stack.
//
// Evert, 2026-11-03: *"the planet does not have any core, so the see-through parts of the cloud deck you can see
// right through the planet. We need something to be opaque there under the clouds, even if it's a shell deep in
// the planet or something."*
//
// **And a giant's interior IS opaque**, so this is not a patch over a hole in the geometry — it is the fact the
// hole was showing. The deep envelope is optically thick long before anything you would call a surface, so a gap
// between two decks shows *darkness*, never stars.
//
// `cull_disabled` because the eye can end up INSIDE this shell (a descent below the level it is drawn at), and a
// single-sided sphere would then vanish and the see-through would come straight back.
//
// `unshaded` because it has no normal worth lighting: it is a deep, flat, dark thing whose only light is what the
// star sent down through the air, and that is `star_transmission` × the air's own transmittance — the same two
// terms every other layer here is lit by, so the floor darkens into the terminator instead of glowing at night.
render_mode cull_disabled, unshaded, specular_disabled;

#include "res://addons/spacesim/render/star_transmission.gdshaderinc"

// The deepest layer's own colour, dimmed — see `SpacesimBodyRenderer.INTERIOR_DIM`.
uniform vec3 interior_color = vec3(0.2);
// The body's own radius, in metres, and the origin the vertices are measured from — the deck shader's two, for
// the same reasons: `VERTEX` is metres from a near-eye point, so both are needed to turn it into a direction.
uniform float planet_radius = 1.0;
uniform vec3 patch_origin = vec3(0.0);

varying vec3 local_position;


void vertex() {
	local_position = (VERTEX + patch_origin) / max(planet_radius, 1.0);
}


void fragment() {
	vec3 p = normalize(local_position);
	// One measurement of what a pixel spans, for the star's own occlusion: a star narrower than a pixel must be
	// drawn as the step it averages to rather than sampled.
	float footprint = length(fwidth(local_position));
	vec3 air_through = star_air_transmittance(p, body_sun, air_altitude, planet_radius);
	ALBEDO = interior_color * air_through * star_transmission(p, body_sun, footprint);
}
