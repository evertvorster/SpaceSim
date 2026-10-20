// **A cloud deck's shadow, as transmittance along the star's ray.** Included by the land and the sea, so the
// two cannot disagree about it — a shadowed shore beside an unshadowed sea would be worse than no shadow.
//
// ---------------------------------------------------------------- what this is
//
// The deck's map is a *coverage field*, and its layer states how optically deep the cloud is where it covers
// that field. Together those make it a **transmittance map**, which is what a shadow is: not "is this point
// under a cloud" but "how much of the star's light got through the cloud in the way".
//
// So the lookup is the deck's own map, sampled where the *star's* ray crosses the deck's shell rather than
// where the eye's ray does — a horizontal offset of `height · tan(zenith)` from the point being shaded, along
// the star's azimuth. Which means the shadow moves as the star moves, and it is long at sunrise without any
// of it being authored.
//
// ---------------------------------------------------------------- why AO and not light()
//
// Godot's clustered renderer turns ambient occlusion into a *direct-light* occlusion with
// `ao = mix(1.0, ao, ao_light_affect)` **before** the light loop (`scene_forward_clustered.glsl`), so writing
// `AO` and `AO_LIGHT_AFFECT = 1.0` dims the star without taking over the BRDF. A `void light()` would be the
// other route and would mean reimplementing the PBR the surface was tuned with.
//
// **It dims the ambient too, and that is a choice rather than an oversight**: a deck does block part of the
// sky, so its underside of the light budget is smaller. If it reads wrong, `AO_LIGHT_AFFECT` is the knob that
// separates the two, and a `light()` override is the last resort.

uniform sampler2D deck_cover : filter_linear, repeat_enable, hint_default_black;
// The percentile the deck's own coverage implies — the same number the deck draws with, so the shadow is
// where the cloud is and not where the field merely has a value.
uniform float deck_threshold : hint_range(0.0, 1.0) = 1.0;
// **Zero means there is no deck above this surface**, which is the honest state for most bodies and makes the
// whole path a uniform branch. Where a layer states no optical depth it is derived from its opacity,
// `τ = −ln(1 − opacity)`, because that is what "how opaque it is where it covers" already means.
uniform float deck_tau = 0.0;
// Metres from this surface to the deck's TOP — the length of the shadow's lever arm.
uniform float deck_height = 0.0;
// The star's direction in the body's own frame, which is the frame `unit_position` is in.
uniform vec3 deck_sun = vec3(0.0, 1.0, 0.0);

// **The deck's detail ladder, so the shadow is the image of the SAME field the cloud draws.** These are the
// deck's own numbers, published beside the map: a shadow that sampled only the map would be blotchy where the
// cloud is whispy, because the whispy detail below the map's texel is this ladder — six octaves of the same
// generator, evaluated per pixel. Evert, 2026-10-20: *"the detail ladder makes the texture — why can't we use
// the texture, which is the output of the detail ladder?"*
uniform int deck_detail_seed = 0;
uniform float deck_detail_feature = 0.0;
uniform float deck_detail_strength : hint_range(0.0, 0.5) = 0.0;

#include "res://addons/spacesim/render/cloud_detail.gdshaderinc"


bool deck_shadow_present() {
	return deck_tau > 0.0 && deck_height > 0.0;
}


// The deck's map is equirect, `u` around the equator and `v` from the north pole — the bake's exact inverse,
// as everywhere else this map is read.
vec2 deck_shadow_uv(vec3 direction) {
	return vec2(0.5 + atan(direction.z, direction.x) / TAU, 0.5 - asin(clamp(direction.y, -1.0, 1.0)) / PI);
}


// How much of the star's light reaches a point whose unit direction is `p`.
float deck_transmittance(vec3 p, float planet_radius) {
    float mu = dot(p, deck_sun);
    // The star is at or below this point's horizon: there is no direct light to shadow.
    if (mu <= 0.0) {
        return 1.0;
    }
    float zenith = max(mu, 0.05);
    vec3 across = deck_sun - p * mu;
    float across_length = length(across);
    // **Straight up**: the shadow point is the point itself, and there is no offset to divide by.
    vec3 shadow_direction = p;
    if (across_length > 1.0e-6) {
        float arc = (deck_height * (across_length / mu)) / max(planet_radius, 1.0);
        shadow_direction = normalize(p + (across / across_length) * arc);
    }
    float field = texture(deck_cover, deck_shadow_uv(shadow_direction)).r;
    // **And the structure the map is too coarse to hold**, from the same ladder the cloud draws with. The
    // footprint is this pixel's angle **at the deck** — `fwidth` is measured at the eye, and the ladder's
    // feature sizes are arcs on the sphere, so the distance to the shell in radii is the conversion.
    if (deck_detail_strength > 0.0 && deck_detail_feature > 0.0) {
        float at_deck = length(fwidth(p)) * (deck_height / max(planet_radius, 1.0));
        field = clamp(
            field + cloud_detail(
                shadow_direction, at_deck, deck_detail_seed, deck_detail_feature, deck_detail_strength
            ),
            0.0, 1.0
        );
    }
    float thickness = clamp(
        (field - deck_threshold) / max(1.0 - deck_threshold, 1.0e-4), 0.0, 1.0
    );
    return exp(-deck_tau * thickness / zenith);
}
