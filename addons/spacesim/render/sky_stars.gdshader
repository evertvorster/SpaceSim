// SpaceSim's sky: the stars, drawn from the real catalogue.
//
// **SpaceSim's own file — edit it here.** Godot 4 sky host: a ShaderMaterial on a Sky resource with
// background_mode = BG_SKY. Returns LINEAR HDR; the Environment tone maps the whole frame, so tone
// mapping here would apply the curve twice.
//
// ---------------------------------------------------------------- WHAT IT IS
//
// The stars that are visible from Sol, at their measured magnitudes, drawn as **one pixel each**.
// The numbers that make it accurate are in `docs/API.md` and `addons/spacesim/sky/PROVENANCE.md`;
// the short version is that a magnitude-0 star delivers 2.54e-6 lux, the whole sky delivers 2e-4 lux
// and the counts run 15 / 48 / 171 / 513 / 1602 / 4800 to magnitudes 1..6.
//
// **This is an INPUT, not an answer.** Every star shader that came before this one was display
// referred — it already had an exposure decision baked into it — which is why none of them could
// respond to SpaceSim's scaling EV: a fixed picture multiplied by a variable exposure is a different
// picture, not the same picture seen differently. Here the radiance is physical and the exposure
// decides what you can see. Nothing in this file knows what the exposure is.
//
// ---------------------------------------------------------------- HOW A STAR IS DRAWN
//
// One pixel, carrying the star's whole flux, found by a BOX test in normalized device coordinates.
// NDC and not a lattice, because the pixels TILE the screen: a star belongs to the pixel whose
// centre is nearest it, so every star lands in exactly one pixel, none can fall between two, and
// none can be drawn twice. A kernel sampled at the pixel centre cannot promise either.
//
// The pixel's value is its illuminance over the pixel's own solid angle, so a brighter star is a
// brighter pixel, every star is the same size, and the sum of a star's pixels is its light. That
// also means a higher resolution or a narrower field concentrates the same flux into a smaller
// angle and the star gets brighter — which is the behaviour Evert chose (2026-10-14), and is what a
// larger aperture does to a point source.
//
// ---------------------------------------------------------------- LICENCE
// GPL-3.0-or-later. The star DATA beside it is CC BY-SA 4.0 — see PROVENANCE.md.
shader_type sky;

// ===== THE CATALOGUE ============================================================
// Built by tools/build_star_catalogue.py, bucketed by cube-face cell so a pixel tests one cell's
// handful of stars rather than 119,613 of them.
uniform sampler2D u_stars;        // RGBA32F: xyz unit direction, V magnitude
uniform sampler2D u_star_colour;  // R32F: B-V colour index
uniform sampler2D u_cells;        // RG32F: the cell's first star index, and how many it holds
uniform vec2 u_stars_size;        // texel dimensions, for the index arithmetic below
uniform vec2 u_colour_size;
uniform vec2 u_cells_size;
uniform int  u_grid;              // cells per cube-face edge

// ===== THE TUNABLES ============================================================
// How deep the sky is drawn, as a magnitude. The catalogue holds all of it and this only decides
// what is shown, so sweeping it costs a uniform and needs no rebuild. The catalogue is a COMPLETE
// sky to magnitude 8 and a diminishing fraction beyond, so this belongs in 6.5 to 8.0 with 9.0 as a
// soft ceiling. The naked-eye limit is 6.5.
uniform float u_limit_mag = 6.5;  // [3.0, 9.5]

// A hand tuner on the whole field's brightness, applied as a plain multiplier on the radiance above.
//
// It is a **calibration knob and not the physics**: the brightness is derived from measured
// illuminance and this only scales it. It is here because settling the absolute level by argument
// has proved slower than settling it by eye — Evert, 2026-10-14: *"Can we put a scaler on the
// brightness of the background so I can tune it manually?"* Driven by `sky.star_gain`, which is in
// DECADES for exactly that reason.
uniform float u_gain = 1.0;

// ===== HOST PLUMBING ============================================================
// Set by SpacesimStarSky once a frame. The camera basis is here rather than taken from a built-in
// because the star's screen position and the pixel's screen position MUST be computed the same way,
// and the only way to guarantee that is to compute both from the same numbers.
uniform vec3  u_right = vec3(1.0, 0.0, 0.0);
uniform vec3  u_up = vec3(0.0, 1.0, 0.0);
uniform vec3  u_fwd = vec3(0.0, 0.0, -1.0);
uniform vec2  u_tan_half = vec2(0.5, 0.5);   // tan(half fov) per axis
// There is deliberately no viewport-size uniform. The pixel's own size is MEASURED below, from the
// screen-space derivatives of the ray, so there is no number for the host to get wrong — see `sky()`.

// ===== PHYSICS ==================================================================
// Measured, not chosen: a V=0 star delivers this much at the observer (Schlyter).
const float LUX_PER_MAG0 = 2.54e-6;

// Godot's unit: a white Lambertian surface under `light_intensity_lux` = 100,000 renders as 1.0, and
// that surface's radiance is 100,000/pi lux per steradian. So a radiance in lux/sr is divided by
// this to reach the engine's units. **It is a unit conversion, not a fudge factor** — if the sky
// comes out too dim or too bright, what is wrong is the exposure or the physics, never this.
const float UNIT_LUX_PER_SR = 100000.0 / 3.14159265358979;

// The worst cell in the catalogue holds 17 stars; the loop bound is a constant because a dynamic
// bound costs more than the break. If a finer grid is ever needed this can come down.
const int MAX_PER_CELL = 24;


int cell_of(vec3 d, int grid) {
	// MUST match `cell_of()` in tools/build_star_catalogue.py, exactly. This is the one piece of
	// arithmetic that has to agree across the language boundary.
	vec3 a = abs(d);
	int face;
	vec2 uv;
	if (a.x >= a.y && a.x >= a.z) {
		face = d.x > 0.0 ? 0 : 1;
		uv = vec2(d.y, d.z) / a.x;
	} else if (a.y >= a.z) {
		face = d.y > 0.0 ? 2 : 3;
		uv = vec2(d.x, d.z) / a.y;
	} else {
		face = d.z > 0.0 ? 4 : 5;
		uv = vec2(d.x, d.y) / a.z;
	}
	ivec2 c = clamp(ivec2((uv * 0.5 + 0.5) * float(grid)), ivec2(0), ivec2(grid - 1));
	return face * grid * grid + c.y * grid + c.x;
}


ivec2 texel_of(int index, vec2 size) {
	int w = int(size.x);
	return ivec2(index % w, index / w);
}


// Colour from a black-body at the star's temperature. Planck at the sRGB primaries rather than a
// hand-picked ramp, normalised to UNIT LUMINANCE so brightness stays a magnitude and only the hue
// moves — otherwise a cool star would be brighter or dimmer than a hot one of the same magnitude.
float planck(float nm, float t) {
	float l = nm * 1e-9;
	return 1.0 / (pow(l, 5.0) * (exp(1.4388e-2 / (l * t)) - 1.0));
}


vec3 star_tint(float bv) {
	// Ballesteros' B-V to temperature, which is accurate across the classes we care about: B-V 0 is
	// 10,124 K (A0), 1.4 is 3,951 K (M0), -0.3 is 16,600 K (B0).
	float t = clamp(4600.0 * (1.0 / (0.92 * bv + 1.7) + 1.0 / (0.92 * bv + 0.62)),
	                1000.0, 40000.0);
	vec3 c = vec3(planck(610.0, t), planck(555.0, t), planck(465.0, t));
	return c / max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-30);
}


void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 acc = vec3(0.0);

	float dz = dot(d, u_fwd);

	// **The pixel's size, measured from the pipeline rather than told.** Godot draws a sky as a
	// fullscreen triangle whose vertex positions ARE the NDC corners, so NDC is an affine function of
	// the fragment coordinate and the forward difference across one fragment is exactly one pixel at
	// the resolution the 3D is actually drawn at. Derivatives therefore *measure* the size.
	//
	// Taking it from the host instead was a silent square law: the obvious answer,
	// `Viewport.get_visible_rect()`, is the **canvas** rect — right only while the render resolution's
	// height equals the canvas resolution's, and wrong by its square at every other. A wrong pixel
	// solid angle is a wrong star brightness, and a wrong half-pixel is a star drawn in the wrong
	// pixel. Neither announces itself.
	//
	// The division is clamped because Godot also renders this material into the radiance cubemap,
	// where a ray can point behind the camera; the clamp keeps the derivative finite rather than
	// letting it become a NaN that reaches the ambient light. The `measured` test below is the same
	// concern seen as a range check — one pixel is a small fraction of NDC, at any resolution.
	vec2 plane = vec2(dot(d, u_right), dot(d, u_up)) / max(dz, 1e-6);
	vec2 ndc_step = vec2(abs(dFdx(plane.x)), abs(dFdy(plane.y))) / u_tan_half;
	bool measured = ndc_step.x > 1e-9 && ndc_step.y > 1e-9
		&& ndc_step.x < 0.5 && ndc_step.y < 0.5;
	vec2 half_pixel = ndc_step * 0.5;

	// **No early `return` is allowed in a `sky()` function** — Godot rejects it outright ("Using
	// 'return' in the 'sky' processor function is incorrect"), so the whole body lives inside the
	// guard instead. Cost of the guard: nothing, since a ray pointing behind the camera draws nothing
	// anyway.
	if (dz > 1e-9 && measured) {
		// This pixel, in the same coordinates a star is measured in.
		vec2 ndc = plane / u_tan_half;

		// The pixel's own solid angle, exactly: the gnomonic element dx*dy / (1+|p|^2)^(3/2) times
		// the pixel's own NDC extent. Using the centre value instead would over-brighten every star
		// toward the corners of the frame.
		float r2 = 1.0 + dot(plane, plane);
		float d_omega = u_tan_half.x * u_tan_half.y * ndc_step.x * ndc_step.y / (r2 * sqrt(r2));

		vec2 cell_data = texelFetch(u_cells, texel_of(cell_of(d, u_grid), u_cells_size), 0).rg;
		int offset = int(cell_data.x + 0.5);
		int count = int(cell_data.y + 0.5);

		for (int i = 0; i < MAX_PER_CELL; i++) {
			if (i >= count) break;
			int index = offset + i;
			vec4 s = texelFetch(u_stars, texel_of(index, u_stars_size), 0);
			if (s.w > u_limit_mag) continue;

			vec3 sd = normalize(s.xyz);
			float sz = dot(sd, u_fwd);
			if (sz <= 1e-9) continue;

			vec2 sndc = vec2(dot(sd, u_right), dot(sd, u_up)) / (sz * u_tan_half);
			// The box: half a pixel, in NDC — measured above, not sent in.
			if (abs(sndc.x - ndc.x) > half_pixel.x) continue;
			if (abs(sndc.y - ndc.y) > half_pixel.y) continue;

			float lux = LUX_PER_MAG0 * pow(10.0, -0.4 * s.w);
			float bv = texelFetch(u_star_colour, texel_of(index, u_colour_size), 0).r;
			acc += star_tint(bv) * (lux / d_omega);
		}
	}

	COLOR = acc * u_gain / UNIT_LUX_PER_SR;
}
