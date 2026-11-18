shader_type spatial;
// **A ring's dust, as a SLAB of volume** — the same shape of thing the air is, and marched the same way.
//
// The band is a slab: `|z| <= thickness/2`, `inner <= r <= outer`, in the parent's frame with its pole along +Z.
// The fragment computes the chord a view ray cuts through that slab in closed form, clips the far end at the depth
// buffer so the planet's own body occludes it, and marches an emission/absorption integral along it.
//
// **Why this and not particles.** The drawn rocks are 4.5e-7 of the band's optical depth, so a dust built out of
// drawn samples had to stand in for millions of grains and its brightness depended on how many of them a pixel
// happened to catch — which made it thousands of times too bright when the sample count was wrong. A slab has no
// count: its brightness is `tau`, its thickness and the two angles, at every distance. Evert, 2026-11-18: *"Is there
// any way that we can have it as a volumetric shader, almost like air?"* — yes, and it is simpler than the samples.
//
// **What a slab does that particles cannot:** seen edge-on the chord is long and the band brightens; seen face-on it
// is the thickness and the band dims. That is a real ring's behaviour, and it is why `thickness` is authored.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled;

// The eye in the ring's own frame, and the rotation from view space into it — the same pair the air shell takes,
// and for the same reason: a vertex stage sees model space and a fragment stage sees view space.
uniform vec3 u_eye_local = vec3(0.0);
uniform mat3 u_to_local = mat3(1.0);
// The star's direction in the ring's frame, and the radiance a bright surface would have there — `illuminance *
// bond_albedo / PI`, the same currency a body's disc is drawn in.
uniform vec3 u_sun_local = vec3(0.0, 1.0, 0.0);
uniform vec3 u_sun_glow = vec3(1.0);
// The slab: its vertical optical depth, its thickness in metres, and the band's radii.
uniform float u_tau = 0.0;
uniform float u_thickness = 1.0;
uniform float u_inner = 0.0;
uniform float u_outer = 0.0;
// The body it encircles, for the planet's shadow across it: the model's origin IS that body's centre.
uniform float u_planet_radius = 0.0;
// **The frame's own surface**, where the march stops: the planet's body writes depth, so a chord that runs into it
// must end there rather than pass through. Sampled rather than tested — the depth attachment is not a storage image.
uniform sampler2D depth_texture : hint_depth_texture;

// **How many steps along the chord.** Sixteen is what a slab of one to five hundred kilometres needs at the angles a
// band is seen from; the density inside it is uniform, so the integral converges fast.
const int STEPS = 16;
// **The scattering coefficient**, per unit optical depth: one quarter, isotropic, which is where `τ/4` in
// `SpacesimRingModel.reflectance`'s thin limit comes from.
const float SCATTER = 0.25;


// **How much of the star reaches a point**, 1 in full light and 0 in the umbra — one ray against the planet's own
// sphere, which sits at this frame's origin. A hard edge is the honest first order: the star subtends 0.06 degrees
// at Saturn, so the penumbra is a few hundred metres of a band that is a thousand kilometres wide.
float star_light(vec3 p) {
	float b = dot(p, u_sun_local);
	float c = dot(p, p) - u_planet_radius * u_planet_radius;
	float discriminant = b * b - c;
	if (discriminant <= 0.0) {
		return 1.0;
	}
	float near_root = -b - sqrt(discriminant);
	return near_root > 0.0 ? 0.0 : 1.0;
}


void fragment() {
	vec3 dir = normalize(u_to_local * normalize(VERTEX));
	vec3 eye = u_eye_local;

	// ===== THE CHORD =====================================================================================
	// The slab is the intersection of `|z| <= h` and `r <= outer`, minus `r < inner` — and the hole is handled in the
	// march rather than in the bounds, because an annulus is not convex and a ray can cross the hole and the ring
	// again beyond it.
	float h = max(u_thickness * 0.5, 1.0);
	float t0 = 0.0;
	float t1 = 1.0e18;
	if (abs(dir.z) > 1.0e-9) {
		float ta = (-h - eye.z) / dir.z;
		float tb = (h - eye.z) / dir.z;
		t0 = max(t0, min(ta, tb));
		t1 = min(t1, max(ta, tb));
	} else if (abs(eye.z) > h) {
		discard;
	}
	float a = dot(dir.xy, dir.xy);
	if (a > 1.0e-12) {
		float b = dot(eye.xy, dir.xy);
		float c = dot(eye.xy, eye.xy) - u_outer * u_outer;
		float disc = b * b - a * c;
		if (disc <= 0.0) {
			discard;
		}
		float s = sqrt(disc);
		t0 = max(t0, (-b - s) / a);
		t1 = min(t1, (-b + s) / a);
	}

	// **Stop at whatever is drawn in front.** A planet's body is opaque and writes depth, so the near half of a
	// band seen through it has to end there; without this the dust would be drawn over the planet.
	float buffer_depth = texture(depth_texture, SCREEN_UV).r;
	if (buffer_depth > 0.0) {
		vec4 scene_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, buffer_depth, 1.0);
		t1 = min(t1, length(scene_view.xyz / max(abs(scene_view.w), 1.0e-9)));
	}
	if (t1 <= t0) {
		discard;
	}

	// ===== THE MARCH =====================================================================================
	// Emission and absorption front to back: each step scatters `SCATTER * dtau` of the star's light toward the eye,
	// through whatever the band has already absorbed, and takes its own share of what is behind.
	float density = u_tau / max(u_thickness, 1.0e-3);
	float step_length = (t1 - t0) / float(STEPS);
	float transmittance = 1.0;
	vec3 radiance = vec3(0.0);
	for (int i = 0; i < STEPS; i++) {
		vec3 p = eye + dir * (t0 + step_length * (float(i) + 0.5));
		// The hole: nothing to scatter, and nothing to absorb.
		if (length(p.xy) < u_inner) {
			continue;
		}
		float dtau = density * step_length;
		radiance += transmittance * u_sun_glow * (SCATTER * star_light(p) * dtau);
		transmittance *= exp(-dtau);
	}

	float alpha = 1.0 - transmittance;
	if (alpha <= 0.0) {
		discard;
	}
	// **Straight colour and an alpha**, because `blend_mix` multiplies by alpha itself: `ALBEDO * ALPHA + behind *
	// (1 - ALPHA)` must equal `radiance + behind * transmittance`, so the colour handed over is `radiance / alpha`.
	// **`u_tau` is what a strength scales** — less dust is less optical depth, not a dimmed sheet, so the geometry
	// stays honest when it is turned down.
	ALBEDO = radiance / alpha;
	ALPHA = alpha;
}
