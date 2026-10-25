// **How much of the star's own disk reaches a point on a body's surface** — the occlusion half of
// `Lighting Plan` §3.1's transmission primitive, at the one place where it is exact.
//
// ---------------------------------------------------------------- what this answers
//
// A surface shader lights a sphere, and its `NORMAL` is a **shading fiction**: `body_surface.gdshader` tilts
// it by the ground's own slope, because a body whose real relief is 0.14 % of its radius would otherwise
// shade like a billiard ball. A tilted normal faces the star from *past* the geometric terminator, so a
// ridge that should be in darkness is drawn lit — thin bright outlines tracing every coastline in the
// planet's dark half. Two flights have reported it, and `relief_exaggeration` 12 -> 5 with a 19° clamp
// (2026-10-19) only narrowed it, because **a clamp cannot relate a lean to the star it is leaning toward**.
//
// So the light itself has to be zero where the geometry says the star is below the horizon, and then no
// normal above it can invent any. That is what this file computes, and it is why it is applied to the light
// — through `AO`, which the engine turns into a direct-light occlusion before the light loop — and not to
// the normal. Keeping the tilt is deliberate: the relief is what makes the ground look like ground.
//
// ---------------------------------------------------------------- why a fraction and not a step
//
// The star is a disk, not a point, so a surface point sees it *partly* as it crosses the limb. The penumbra
// is the star's own angular radius, and that is not a constant: `asin(R_star / d)` differs **77x across
// Sol** (0.687° at Mercury, 0.0089° at Neptune), so the host publishes it per body from
// `SpacesimLod.angular_radius` — the same call that feeds the light's own `light_angular_distance`, so the
// band a surface shades with and the softness the engine's shadow would use cannot disagree.
//
// **And the band is filtered by what a pixel can resolve, in the same expression.** The penumbra is
// `2 · star_angle · disc_radius_px` wide, so on a disc filling the frame it is several pixels and must be
// drawn, and past about a 107 px disc radius (Sol from Earth) it is narrower than one pixel — where the
// correct answer is the filtered step and not a sampled band. The transition is therefore the WIDER of the
// two, which is the same shape as the detail ladder's own footprint fade. No branch, no distance gate, no
// second threshold.
//
// **It also removes a defect the fix would otherwise create.** This factor multiplies the *tilted* normal's
// light, so a one-pixel cut would land exactly where per-pixel tilt decides which neighbour is lit — a new
// ragged line drawn along the terminator. The penumbra spans that place by construction; and because it is
// centred on the horizon and reaches full only at `+star_angle`, it dims nothing on the day side beyond the
// star's own width.

// The star's angular radius, in radians, as seen from this body. **Zero is the honest default**: a material
// whose publish was missed then draws a point star — a one-pixel filtered step — rather than a soft edge
// sized by a number nobody supplied.
uniform float star_angle = 0.0;

const float STAR_MIN_HALF_WIDTH = 1.0e-6;


// The fraction of the star's disk above the horizon at a point whose unit normal is `up`, given the star's
// direction in the same frame and the angle one pixel spans there. Both callers already carry that angle
// for their own detail ladders — `length(dFdx(up))` — so this adds no measurement of its own.
//
// **The circular segment, exactly**: with the star's centre at elevation `e` and its disk of radius `h`, the
// fraction is `(acos(t) − t·sqrt(1 − t²)) / π` at `t = −e / h`. It is 0.5 at the horizon and saturates half
// a width either side, so it can never overshoot 1 or go negative — which is what makes it safe to use as a
// light occlusion rather than a shading suggestion.
float star_transmission(vec3 up, vec3 star_direction, float pixel_angle) {
	// **An angle, because the half-width is one.** A raw `dot` is a sine, and comparing a sine against a
	// radian is a 1e-5 relative error at α = 0.005 and a wrong answer once the pixel is the wider term.
	float elevation = asin(clamp(dot(up, star_direction), -1.0, 1.0));
	float half_width = max(star_angle, pixel_angle * 0.5);
	float t = clamp(-elevation / max(half_width, STAR_MIN_HALF_WIDTH), -1.0, 1.0);
	return (acos(t) - t * sqrt(max(1.0 - t * t, 0.0))) / PI;
}
