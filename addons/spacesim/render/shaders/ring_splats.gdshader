shader_type spatial;
// **A ring's particles, drawn as a sheet of discs.** Unshaded, depth-tested and depth-writing-never: the
// particles are light and a medium, not geometry, and 300,000 of them must not fight over the depth buffer.
// No culling, because a billboard has no winding.
//
// **`blend_mix`, and that is the whole of requirement `R33`.** An additive draw cannot show a dark thing:
// a particle in the planet's shadow has no star light, so it would add nothing and stop existing — which
// is exactly what the first attempt did, and what Evert rejected (*"I don't want the rocks in the shadow of
// the planet disappearing, they should just not be lit from the sun"*). Mixing means a particle **extinguishes
// what is behind it by its own transmittance and replaces it with its own radiance**, so an unlit one is a
// dark particle over a bright planet, and an invisible one is impossible.
//
// **The optical depth is the only brightness number.** One drawn particle stands in for many real ones, so
// it carries a share of the sheet's `tau`:
//
//     alpha = 1 - exp(-(tau/mu) * share / overlaps)      share = r_px^2 / mean_r_px^2
//
// and the radiance it hands over is `L / (1 - exp(-tau/mu))`. With `overlaps` particles landing on a pixel
// those two compose to exactly `L` over a background dimmed by `exp(-tau/mu)` — the sheet's own reflectance
// and its own transmittance, however many particles the pixel happens to catch. That is what makes the
// brightness **independent of distance**, which is the property no per-splat scale factor can have.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled;

// The pixel's angular size, from the camera's fov and the render target's height: a vertex stage has no
// derivatives, so it cannot measure its own footprint.
uniform float pixel_angle = 0.00122;
// The band's optical depth, and the cosine of the eye's direction above the ring plane. Together they are
// the path length through the slab, `tau / mu`.
uniform float tau = 0.0;
uniform float eye_cosine = 1.0;
// **How many particles are expected to land on one pixel** — the count that makes the above compose to the
// sheet rather than to a cloud of discs. Computed on the host each frame, because it needs the band's
// projected area and the mean particle size, and a vertex stage knows neither.
uniform float overlaps = 1.0;
// The mean particle's screen radius, floored at one pixel — the denominator of each particle's share.
uniform float mean_radius_px = 1.0;
// The band's radiance in the engine's linear currency, and the floor a shadowed particle keeps.
uniform vec3 glow_linear = vec3(1.0);
uniform vec3 unlit_linear = vec3(0.04);
// **Which half of the ring this draw is.** A planet's air is transparent with the depth test off, so one
// draw cannot be both in front of it and behind it. Evert, 2026-11-15: *"Cut the rings exactly on the
// planet's centre so you split it into a front half that faces the camera and goes in front of the planet,
// and a back half that goes behind the planet."*
uniform vec3 split_direction = vec3(0.0, 0.0, 1.0);
uniform float split_side = 0.0;
uniform vec3 planet_origin = vec3(0.0);

varying float v_alpha;
// Constant across a quad, but a hard shadow edge must not be interpolated across two instances that
// disagree, so it is `flat` — an interpolated 0/1 pair would draw a smear of half-lit particles along the
// shadow's edge.
varying flat float v_shadow;

void vertex() {
	// The instance's origin in view space: a MultiMesh's MODELVIEW_MATRIX already carries the instance
	// transform, so this is the particle relative to the eye.
	vec4 centre = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	float distance = max(length(centre.xyz), 1.0);
	// Its radius in metres, carried by the instance's own basis scale. **MODELVIEW, not MODEL_MATRIX**: for a
	// MultiMesh the instance transform is folded into MODELVIEW_MATRIX and MODEL_MATRIX reads back as the
	// identity, which is how every splat in the first attempt came out 400x too bright.
	float radius = length(MODELVIEW_MATRIX[0].xyz);
	// **One pixel of radius when its own disc is smaller** — a quad narrower than a pixel rasterises
	// unreliably, and the flux it cannot deliver at that size is carried by `alpha` instead.
	float half_size = max(radius, distance * pixel_angle);
	float radius_px = half_size / max(distance * pixel_angle, 1.0e-9);

	float share = (radius_px * radius_px) / (mean_radius_px * mean_radius_px);
	float depth = (tau / max(eye_cosine, 0.02)) * share / max(overlaps, 1.0e-6);
	// `.g` is "draw this one": zero once a body stands for the spot, so the shape replaces the splat rather
	// than growing through it, and **zero alpha also stops it occluding**, which is what hiding means here.
	v_alpha = (1.0 - exp(-max(depth, 0.0))) * INSTANCE_CUSTOM.g;
	v_shadow = INSTANCE_CUSTOM.r;

	vec3 offset = vec3(VERTEX.xy * 2.0 * half_size, 0.0);
	// **The cut.** A particle on the other side of the planet belongs to the other draw, so this one collapses
	// it to a point of no area — `return` is not allowed in a vertex stage, and a degenerate quad rasterises
	// nothing.
	if (split_side != 0.0) {
		vec3 world = (INV_VIEW_MATRIX * vec4(centre.xyz, 1.0)).xyz;
		if (dot(world - planet_origin, split_direction) * split_side < 0.0) {
			offset = vec3(0.0);
			v_alpha = 0.0;
		}
	}
	// A view-space offset in x and y is already screen-aligned, which is the whole of billboarding.
	POSITION = PROJECTION_MATRIX * vec4(centre.xyz + offset, 1.0);
}

void fragment() {
	// **A disc, not a quad**: the quad is a place to draw the disc on. The edge is one texel wide, because a
	// particle resolved to a few pixels must look round rather than square.
	float radial = length(UV * 2.0 - 1.0);
	if (radial > 1.0) {
		discard;
	}
	float edge = 1.0 - smoothstep(1.0 - max(fwidth(radial), 0.01), 1.0, radial);
	// **The accumulated radiance must come out at `glow`, however many particles land on the pixel.** With
	// `n` layers each `alpha` and radiance `S`, the sum is `S * (1 - (1-alpha)^n)`, and `(1-alpha)^n` is the
	// slab's transmittance `exp(-tau/mu)` by construction — so `S` is the band's radiance over the fraction
	// of the frame the sheet takes over. A shadowed particle keeps the unlit floor: dark, and still drawn.
	vec3 radiance = mix(unlit_linear, glow_linear, v_shadow);
	float absorbed = max(1.0 - exp(-tau / max(eye_cosine, 0.02)), 1.0e-4);
	ALBEDO = radiance / absorbed;
	ALPHA = v_alpha * edge;
}
