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

uniform sampler2D deck_cover : filter_linear_mipmap, repeat_enable, hint_default_black;
// The percentile the deck's own coverage implies — the same number the deck draws with, so the shadow is
// where the cloud is and not where the field merely has a value.
uniform float deck_threshold : hint_range(0.0, 1.0) = 1.0;
// **Zero means there is no deck above this surface**, which is the honest state for most bodies and makes the
// whole path a uniform branch. Where a layer states no optical depth it is derived from its opacity,
// `τ = −ln(1 − opacity)`, because that is what "how opaque it is where it covers" already means.
uniform float deck_tau = 0.0;
// Metres from this surface to the deck's TOP — the length of the shadow's lever arm.
uniform float deck_height = 0.0;
// **The star's direction in the body's own frame** is declared in `star_transmission.gdshaderinc`, which a
// shader using this one must include FIRST — the shadow is offset along it, and so are the occlusion and the
// air's extinction. One uniform, one home.

// **The eye, in the body's own frame and in body radii** — the direction *to* the camera, per fragment, which
// is what the upward ray needs. A *direction* will not do where the star's does: the eye is a few radii away,
// not a few hundred million, so the viewing angle genuinely varies across a disc. It is the same quantity the
// deck's own material is handed as `eye_local`.
uniform vec3 body_eye_local = vec3(0.0, 0.0, 2.0);

// **How dark a shadow is allowed to get**, as the floor on the light it leaves: `1.0` is no shadow, `0.0` is
// the physical transmittance with nothing added back.
//
// The engine gives one `AO` value, and it drives **both** the ambient and the direct light, so "a shadow does
// not remove the ambient" cannot be said by writing two numbers — it has to be said as a floor. Evert,
// 2026-10-20: *"when you are in the shadow of a cloud, there is usually still plenty of ambient light lighting
// the scene."* He is right, and the physical reason is that a shadow is filled back in by multiple scattering —
// the cloud's own base is a bright diffuse source over your head — which nothing here models, because the
// ambient is a constant rather than a sky probe.
//
// **The upgrade path is written down rather than implied**: when the lighting plan gives the ambient an actual
// sky to come from, this floor should go and the ambient should simply be lit by what is above it.
uniform float deck_shadow_floor : hint_range(0.0, 1.0) = 1.0;

// **The deck's detail ladder, so the shadow is the image of the SAME field the cloud draws.** These are the
// deck's own numbers, published beside the map: a shadow that sampled only the map would be blotchy where the
// cloud is whispy, because the whispy detail below the map's texel is this ladder — six octaves of the same
// generator, evaluated per pixel. Evert, 2026-10-20: *"the detail ladder makes the texture — why can't we use
// the texture, which is the output of the detail ladder?"*

#include "res://addons/spacesim/render/detail_ladder.gdshaderinc"


bool deck_shadow_present() {
	return deck_tau > 0.0 && deck_height > 0.0;
}


// The deck's map is equirect, `u` around the equator and `v` from the north pole — the bake's exact inverse,
// as everywhere else this map is read.
vec2 deck_shadow_uv(vec3 direction) {
	return vec2(0.5 + atan(direction.z, direction.x) / TAU, 0.5 - asin(clamp(direction.y, -1.0, 1.0)) / PI);
}

// **The path through the slab along one ray, in column-thicknesses** — `thickness / mu`, with the map read
// where that ray actually crosses the deck rather than where the point is.
//
// **One function for both rays**, because they are the same medium: the star's (which makes a shadow) and the
// eye's (which is what the surface's light has to cross to be seen). A second copy of this arithmetic is how
// the two would come to disagree about how thick the cloud is, which is the failure this include exists to
// prevent in the first place.
//
// Returns **-1** when the ray leaves below the local horizontal — nothing crosses the slab — and each caller
// decides what that means: no light to shadow, or nothing to attenuate on the way out.
//
// `with_detail` is false for the eye's ray. The ladder is the *sub-texel* structure and it costs six noise
// evaluations; a beam's attenuation is decided by the coarse field, and the surface shaders already run a
// ladder of their own. The shadow keeps it, because there the ladder is what makes the shadow's edge belong to
// the cloud that casts it.
float deck_column_path(vec3 p, vec3 direction, float planet_radius, bool with_detail) {
    float mu = dot(p, direction);
    if (mu <= 0.0) {
        return -1.0;
    }
    float zenith = max(mu, 0.05);
    vec3 across = direction - p * mu;
    float across_length = length(across);
    // **Straight up**: the crossing point is the point itself, and there is no offset to divide by.
    vec3 crossing = p;
    if (across_length > 1.0e-6) {
        float arc = (deck_height * (across_length / mu)) / max(planet_radius, 1.0);
        crossing = normalize(p + (across / across_length) * arc);
    }
    float field = texture(deck_cover, deck_shadow_uv(crossing)).r;
    // **No noise ladder here either**, and for a stronger reason than on the deck: a shadow is the *image* of the cloud
    // that casts it, so the two must sample the same thing. With the deck drawing its map alone, a shadow that added
    // ladder noise would be a different cloud from the one overhead — which is the fault this include was written to
    // prevent in the first place.
    float thickness = clamp(
        (field - deck_threshold) / max(1.0 - deck_threshold, 1.0e-4), 0.0, 1.0
    );
    return thickness / zenith;
}


// How much of the star's light reaches a point whose unit direction is `p`: `exp(-tau · path)`.
float deck_transmittance(vec3 p, float planet_radius) {
    float path = deck_column_path(p, body_sun, planet_radius, true);
    // The star is at or below this point's horizon: there is no direct light to shadow.
    if (path < 0.0) {
        return 1.0;
    }
    return exp(-deck_tau * path);
}


// **What is left of a BEAM after it crosses the slab, relative to the DIFFUSE transmittance the composite
// already applies** — the factor a specular highlight owes the cloud above it.
//
// **A specular lobe is a beam and a cloud's base is a diffuse source, so they are not attenuated alike.** The
// deck is drawn `blend_mix`, so the surface behind it passes at `1 - alpha`, and `alpha` is built from
// `two_flux`'s *diffuse* transmittance `1/(1+x)` — right for the ground's colour, and thousands of times too
// much for the sun's reflection on water. Evert, flying at sunset, 2026-10-25: *"solid clouds look like hazy
// wisps when the sunlight is directly behind it, and reflecting off of water."* At `x = 11.5` the diffuse
// answer is 8 % and a beam's is 0.001 %.
//
// `x` is the **same** `deck_tau · path` the shadow casts with — one medium, one map, one view cosine — so this
// is a correction to *which* transmittance applies, not a second law about the cloud.
//
// The result is `exp(-x)·(1 + x)`, which is ≤ 1 for every `x ≥ 0`: the glint can only be dimmed.
float deck_specular_share(vec3 p, vec3 to_eye, float planet_radius) {
    float path = deck_column_path(p, to_eye, planet_radius, false);
    if (path < 0.0) {
        return 1.0;
    }
    float x = max(deck_tau * path, 0.0);
    return exp(-x) * (1.0 + x);
}

// How much of the star's light reaches a point whose unit direction is `p`, **after the floor** — the number
// the caller writes into `AO`. The transmittance itself is the return of `deck_transmittance()` below, kept
// separate so the concession and the physics are not the same expression.
float deck_shadow_factor(vec3 p, float planet_radius) {
	return mix(deck_shadow_floor, 1.0, deck_transmittance(p, planet_radius));
}
