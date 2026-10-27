// **The surface's mapping, and the displacement that turns it into geometry — one copy, for both layers.**
//
// ## Why this is shared and not repeated
//
// Land and sea are **two materials on one mesh**. The sea draws below the water line and the ground above it, both
// from the same height map and the same threshold. Displace one and not the other and a sea at the sphere's radius
// sits beneath a continent lifted kilometres into the air, so every coast becomes a fight between two surfaces that
// no longer meet. One function, one expression, both callers.
//
// ## The order that matters
//
// **`unit` must be the direction BEFORE displacement.** The field is a function of *direction*, and the mapping is
// `equirect()` of that direction; look the height up at the displaced direction and the terrain slides sideways as
// it rises — a fault that only appears once something is a few kilometres tall, and reads as the surface creeping.
// So the caller captures the unit direction first, then displaces.
//
// ## Why the vertex stage can only use the map
//
// **A vertex stage has no derivatives**, so there is no `fwidth` to band-limit anything with: the caller samples with
// an explicit `textureLod(..., 0.0)`, and the whole-body map *is* the band limit. That is enough, and it is the
// finding the displacement investigation rests on: 1 px of height error is arithmetically unreachable at close range,
// so geometry's job is the **silhouette and the parallax** — 5–10 km shapes — while everything finer stays the
// fragment stage's business. Nothing displaced here carries detail below the map's own texel, deliberately.

const float MAP_PI = 3.141592653589793;
const float MAP_TAU = 6.283185307179586;


// The equirect mapping, and it must stay the exact inverse of the bake's — `u` around the equator, `v`
// north-at-the-top. A mismatch does not look like an error, it looks like bad geography.
vec2 equirect(vec3 direction) {
	return vec2(
		0.5 + atan(direction.z, direction.x) / MAP_TAU,
		0.5 - asin(clamp(direction.y, -1.0, 1.0)) / MAP_PI
	);
}


// **The displaced model-space position.** A body's node carries its radius as scale, so a node's model space is a
// unit sphere and the displacement in it is the height as a *fraction of the radius* — `field_amplitude` is the
// field's ±1 in metres and `planet_radius` the body's, so the ratio is the whole conversion.
//
// `height` is the field's own value (about ±1), already multiplied by the caller's `displace` switch, which is what
// keeps the old picture one uniform write away.
vec3 displaced(vec3 unit, float height, float amplitude, float radius) {
	return unit * (1.0 + height * amplitude / max(radius, 1.0));
}
