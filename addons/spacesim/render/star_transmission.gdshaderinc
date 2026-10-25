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

// **The star's direction in the body's own frame**, which is the frame every direction on these surfaces is
// measured in — `unit_position` for the land and the sea, `p` for a deck. It lives here rather than in
// `deck_shadow.gdshaderinc` because it has three consumers now: a shadow is offset along it, the occlusion
// below needs it, and so does the air's own extinction. **Include this file before `deck_shadow`** in a
// shader that wants both: the shadow's functions read it and a shader is compiled top to bottom.
//
// It used to be `deck_sun`, and the name is what allowed the surface's publish to sit inside the deck's own
// per-frame call — where an airless body, having no deck, never got it and kept the default `Vector3.UP`.
uniform vec3 body_sun = vec3(0.0, 1.0, 0.0);

// ===== THE AIR'S SHARE OF THE STAR'S LIGHT =========================================
//
// **The light a surface or a cloud is drawn in is the light that REACHES it**, and on the way in the air has
// taken its share: blue first, then green, then red — which is why a ridge near the terminator is not white,
// and why a cloud on the far limb of a lit planet is dim and orange instead of a bright spot. Evert,
// 2026-10-25: *"Clouds lit from the side firstly have less light hitting them from the absorption from the
// atmosphere, and their own absorption makes them darker, so you should never see bright spots for these
// clouds from the far side of the planet."*
//
// **The numbers are the pass's, from `body.air`** — the same dictionary `SpacesimAtmospherePass` is fed — so
// the ground and the sky over it cannot disagree about how thick the air is. **The law is
// `SpacesimAtmosphereModel`'s**, which is where it is tested; what is here is its transcription, and the one
// thing that must not drift is the shape.
//
// **Zero is the degenerate case, not a branch**: an airless body's coefficients are zero, every optical depth
// is zero, and the transmittance is exactly 1.
uniform vec3 air_rayleigh = vec3(0.0);
uniform float air_rayleigh_height = 0.0;
uniform vec3 air_absorption = vec3(0.0);
uniform float air_mie = 0.0;
uniform float air_mie_height = 0.0;
// Metres above this body's surface — 0 for the ground and the sea, the deck's own base height for a cloud.
uniform float air_altitude = 0.0;

const float STAR_MIN_HALF_WIDTH = 1.0e-6;


// **The air mass of a spherical exponential atmosphere**, approximated in closed form: `1` overhead,
// `sqrt(pi R / 2H)` at the horizon (34 for Earth, against the Chapman function's 38), monotone between, and
// within ~20 % of the exact integral everywhere. The plane-parallel `1/cos` it replaces is *unbounded* at
// the horizon and wrong by a factor of two a few degrees above it — and the horizon is the whole point.
// **A closed form and not a march**: eight samples across a chord that at the limb is ~2,000 km, against an
// 8.5 km scale height, was the previous attempt and it under-integrated the one case that matters.
float star_air_mass(float mu, float scale_height, float solid_radius) {
	return inversesqrt(mu * mu + 2.0 * scale_height / (PI * max(solid_radius, 1.0)));
}


// **What survives the trip down to this point**, per channel.
//
// `dip` is how far below the vertical horizon the star reaches a point at this altitude — the tangent clears
// the ground for a point above it, which is why a cloud stays lit a degree or so after the ground beneath it
// has gone dark. Applied as a shift of the elevation, which gets both ends right (0 at the local horizon, 1
// overhead) and the middle to well inside the model's own tolerance.
//
// Above the local horizon the path is the vertical column, `H*exp(-h/H)`, times the air mass through the
// elevation, and it grows without bound as the star sets — so the light dies continuously into the sunset
// rather than being cut.
vec3 star_air_transmittance(vec3 up, vec3 star_direction, float altitude, float solid_radius) {
	float height = max(altitude, 0.0);
	float ratio = solid_radius / max(solid_radius + height, 1.0e-3);
	float dip = sqrt(max(1.0 - ratio * ratio, 0.0));
	float mu = clamp(dot(up, star_direction) + dip, 0.0, 1.0);
	// A zero scale height is an airless body: the column is zero, not a division.
	float rayleigh_path = air_rayleigh_height * exp(-height / max(air_rayleigh_height, 1.0e-3))
		* star_air_mass(mu, air_rayleigh_height, solid_radius);
	float mie_path = air_mie_height * exp(-height / max(air_mie_height, 1.0e-3))
		* star_air_mass(mu, air_mie_height, solid_radius);
	return exp(-(air_rayleigh + air_absorption) * rayleigh_path - vec3(air_mie) * mie_path);
}


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
