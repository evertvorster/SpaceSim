shader_type spatial;
// **A ring's particles, each drawn as the rock it is.** Unshaded, depth-tested, never writing depth: 300,000
// of them must not fight over the depth buffer, and a billboard has no winding.
//
// **`blend_mix`, because a dark thing must be able to occlude.** Evert, 2026-11-16: *"I don't want the rocks in
// the shadow of the planet disappearing, they should just not be lit from the sun."* An additive draw cannot
// show that — a particle with no star light would add nothing and stop existing. Mixing makes a rock an opaque
// disc that replaces what is behind it by its own coverage and hands over its own radiance, so an unlit one is
// **a dark rock in front of a bright planet**.
//
// **And it is a rock, not a sheet.** The 300,000 drawn particles are the largest embedded objects; their own
// optical depth is `2 x 10⁻⁷` against the band's `tau = 1.2`, so they carry a sixth of a millionth of the
// band's light. Drawing them as the sheet is what made the first two builds orders of magnitude too bright —
// the band itself is the *dust*, which is not modelled yet. So each particle contributes
//
//     alpha     = its own coverage of the pixel,  min(1, pi * r_px^2)
//     radiance  = the light IT receives and reflects, per particle
//
// and a pixel's light is the sum of the coverage the rocks give it. At a million kilometres that is a faint
// scatter of dots, which is what 300,000 rocks *are*; the solid band waits for the dust.
//
// **The per-particle radiance is Lambert's own law, the same one the engine uses for a body's disc**
// (`SpacesimLuminance.disc_luminance`): the light arriving at the particle, the fraction its material
// reflects, and `(sin a + (pi - a) cos a)/pi` for the angle `a` between the star and the eye as seen FROM the
// particle. That angle is why it cannot be one number for the band: from inside the rings the near particles
// are lit from behind and the far ones from in front, and a flat uniform would draw a band that is equally
// bright everywhere — which is the one thing a ring never is.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled;

// The pixel's angular size, from the camera's fov and the render target's height: a vertex stage has no
// derivatives, so it cannot measure its own footprint.
uniform float pixel_angle = 0.00122;
// **The light arriving at the band divided by pi, times the particles' bond albedo** — everything in
// `disc_luminance` that is the same for every particle. The phase term is per particle, below.
uniform vec3 glow_linear = vec3(1.0);
// The floor a shadowed particle keeps: dark, and never absent.
uniform vec3 unlit_linear = vec3(0.04);
// Where the star is, in world space — the other half of the phase angle.
uniform vec3 star_position = vec3(0.0);

varying float v_coverage;
varying vec3 v_radiance;
// Constant across a quad, but a hard shadow edge must not be interpolated across two instances that
// disagree, so it is `flat`.
varying flat float v_shadow;

void vertex() {
	// The instance's origin in view space: a MultiMesh's MODELVIEW_MATRIX already carries the instance
	// transform, so this is the particle relative to the eye.
	vec4 centre = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	float distance = max(length(centre.xyz), 1.0);
	// Its radius in metres, carried by the instance's own basis scale. **MODELVIEW, not MODEL_MATRIX**: for a
	// MultiMesh the instance transform is folded into MODELVIEW_MATRIX and MODEL_MATRIX reads back as the
	// identity, which is how every splat in an earlier build came out 400x too bright.
	float radius = length(MODELVIEW_MATRIX[0].xyz);
	// **One pixel of radius when its own disc is smaller** — a quad narrower than a pixel rasterises
	// unreliably — while the coverage below keeps the particle's TRUE area, so the floor costs nothing in
	// light. This is the difference between a bright dot and the light a 100 m rock actually delivers.
	float half_size = max(radius, distance * pixel_angle);
	// **The number that proves it:** the drawn particles' own optical depth is `SpacesimRingModel.
	// drawn_optical_depth` — 4.5e-7 for the B ring, against the band's `tau` of 1.2. A rock that covers a whole
	// pixel at full radiance carries a million times the light it has, and that is what "orders of magnitude too
	// bright" was, twice.
	//
	// **The radius in pixels is the TRUE one, and the floor above is only the quad's size.** This line has now been
	// got wrong TWICE, and each time it made every rock in the band orders of magnitude too bright: a
	// floor-and-divide here gives a sub-pixel rock `radius_px = 1`, so `pi * radius_px^2` saturates its coverage
	// and a rock a thousandth of a pixel wide lights a whole one. The floor exists because a quad narrower than a
	// pixel rasterises unreliably; **the light must not follow it.** Evert, 2026-11-18: *"Faaaaar to bright, orders
	// of magnitude too bright... Maybe you made the rocks bright again by accident?"* — he was right.
	float radius_px = radius / max(distance * pixel_angle, 1.0e-9);
	// **The particle's share of the pixel it lands on**, and `1` once it covers the pixel outright. This is the
	// whole of the flux law: a rock smaller than a pixel dims what is behind it by its own area and adds its own
	// radiance times that area, which is exactly what a small opaque disc does.
	//
	// `.g` is "draw this one": zero once a body stands for the spot, so the shape replaces the splat rather than
	// growing through it.
	// **A rock covers with its own disc.** `.g` switches it off, which is what hides a spot that has a body.
	v_coverage = min(1.0, PI * radius_px * radius_px) * INSTANCE_CUSTOM.g;
	v_shadow = INSTANCE_CUSTOM.r;

	// **How much light this particle receives and reflects.** The phase angle is at the particle: the
	// direction to the star against the direction to the eye. `INV_VIEW_MATRIX[3]` is the camera's own world
	// position, so nothing has to be handed in twice.
	vec3 to_world = (INV_VIEW_MATRIX * vec4(centre.xyz, 1.0)).xyz;
	vec3 to_star = normalize(star_position - to_world);
	vec3 to_eye = normalize(INV_VIEW_MATRIX[3].xyz - to_world);
	float phase = acos(clamp(dot(to_star, to_eye), -1.0, 1.0));
	float lambert = (sin(phase) + (PI - phase) * cos(phase)) / PI;
	v_radiance = mix(unlit_linear, glow_linear * lambert, v_shadow);

	vec3 offset = vec3(VERTEX.xy * 2.0 * half_size, 0.0);
	// **A hidden particle is collapsed to a point of no area**, which is a frame-rate fix rather than a look:
	// switching a spot off by alpha alone still rasterises a quad the size of the shape it was replaced by.
	//
	// **There is no cut any more.** The band was drawn twice, cut on the plane through the planet's centre, so
	// that the half behind the planet could go under its air and the half in front over it. The planet's own body
	// hides the far half by depth, so the cut bought only the haze over the far limb — and it cost every ordering
	// fault this feature had, ending with a classification that hid the whole front half at some camera
	// positions. One draw, after everything the planet wears.
	if (v_coverage <= 0.0) {
		offset = vec3(0.0);
	}
	// A view-space offset in x and y is already screen-aligned, which is the whole of billboarding.
	POSITION = PROJECTION_MATRIX * vec4(centre.xyz + offset, 1.0);
}

void fragment() {
	// **A disc, not a quad**: the quad is a place to draw the disc on, and the edge is one texel wide so a rock
	// resolved to a few pixels looks round rather than square. **No `discard`** — a shader that discards cannot
	// use early depth culling on hardware that has it, and this draws 300,000 quads twice a frame; an alpha of
	// zero at the corners looks the same and blends nothing.
	float radial = length(UV * 2.0 - 1.0);
	float edge = 1.0 - smoothstep(1.0 - max(fwidth(radial), 0.01), 1.0, radial);
	ALBEDO = v_radiance;
	ALPHA = v_coverage * edge;
}
