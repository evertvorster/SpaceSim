// **The gradient of a scalar over a sphere, from the screen** — one home, because two shaders now need the same thing
// and the first version of it was written twice.
//
// `up` is the unit direction a fragment is drawn at and `height` is any smooth scalar of it. The hardware gives
// `dFdx`/`dFdy` free (see the `shaders` skill, execution model §"what the GPU gives free"), and `dFdx(up)`/`dFdy(up)`
// are the screen-space steps *across the sphere* — so a 2x2 solve turns the height's screen derivatives into a
// gradient **on the surface**, with no tangent attribute and no second sampling of the field.
//
// **What this replaces, and why it is not a micro-optimisation**: a central difference
// `(h(p + t·s) - h(p - t·s)) / 2s` in two tangent directions costs FOUR full evaluations of the field to obtain one
// slope. On Earth's sea that was 8 `fnl_fbm3_banded` calls — 28 octaves a pixel — to measure a quantity two
// derivatives already carry. Evert, 2026-11-02: *"the water shader is a bit heavy, I see a significant frame rate
// drop when the ocean fills a large part of the screen."*
//
// **It is not free of trade**: a derivative of an interpolated varying is only as faithful as the triangulation, which
// is why `body_surface.gdshader` measures its footprint from `pixel_angle` rather than from `dFdx` (a re-selected
// patch mesh would otherwise move the texture at a fixed pixel). That matters where the quantity drives *geometry* or
// a *band-limit*; here it only ever feeds a normal, and the band-limit is passed to the noise by the caller. The land
// has used this solve since 2026-11-01 for its relief; the sea now shares it instead of differing the field.

// **Two directions spanning the tangent plane at `n`.** Arbitrary in rotation — the caller only needs an orthonormal
// pair — and chosen against the world up so the cross product is never degenerate.
void surface_tangents(vec3 n, out vec3 t1, out vec3 t2) {
	t1 = normalize(cross(n, abs(n.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	t2 = cross(n, t1);
}

// **The gradient of `height` along the surface at `up`, in the tangent frame.** Zero when the frame has collapsed
// (the determinant below), because a pixel at the exact centre of a degenerate quad has no gradient to report and a
// division by zero is a NaN that no shader can raise.
vec3 surface_gradient(vec3 up, vec3 t1, vec3 t2, float height) {
	vec3 dux = dFdx(up);
	vec3 duy = dFdy(up);
	float a = dot(dux, t1);
	float b = dot(dux, t2);
	float c = dot(duy, t1);
	float d = dot(duy, t2);
	float det = a * d - b * c;
	if (abs(det) <= 1.0e-12) {
		return vec3(0.0);
	}
	float dhx = dFdx(height);
	float dhy = dFdy(height);
	return ((d * dhx - b * dhy) / det) * t1 + ((a * dhy - c * dhx) / det) * t2;
}
