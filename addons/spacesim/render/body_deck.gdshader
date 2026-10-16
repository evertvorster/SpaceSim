shader_type spatial;
// `cull_disabled` because one shell has to serve both sides of itself: from space you see the deck's
// TOP, and from underneath the same sphere is the ceiling. The far regime is for the outside view, but
// a deck that vanished as you flew under it would read as a bug rather than as a limitation.
render_mode blend_mix, cull_disabled, specular_disabled;

// The cloud deck: a baked coverage map on a shell, thresholded into cloud.
//
// ---------------------------------------------------------------- WHAT IT IS
//
// **A picture of a field that was already computed.** Nothing here derives anything: the map came from
// `SpacesimCloudField` and `SpacesimCloudMaps`, the threshold is the percentile that gives the layer its
// coverage, and the colour is the body's. The shader's whole job is to place the map on the sphere and
// let the air dim it — which is why it can be this short.
//
// **Not additive.** The air is `blend_add` because a sky is something you look *through*; a deck is
// something you look *at*, and it has to occlude what is behind it. That is why this is a second
// material rather than another term in the atmosphere's.
//
// **The altitude is derived** — the condensation level, from the air's own `T(h)` profile — so the deck
// sits at a real height above a real surface and moves with the air rather than with the planet's size.
// `radius * 1.012` is what the first attempt used, and 76 km above Earth made it every world's outermost
// silhouette.
//
// ---------------------------------------------------------------- THE MAPPING
//
// **This must be the exact inverse of `SpacesimCloudField.bake`, or the bands land mirrored or off by a
// hemisphere** — a bug that looks like bad geography rather than like an error. The bake walks
// `lon = u * TAU - PI`, `lat = PI/2 - v * PI`, and builds
// `direction = (cos lat cos lon, sin lat, cos lat sin lon)`; so:
//
//     u = 0.5 + atan2(z, x) / TAU
//     v = 0.5 - asin(y) / PI
//
// with `v = 0` the north pole, which is the map's top row. **The two are one fact in two languages,
// and a change to either has to be made in both.**
//
// `repeat_enable` on `u` is deliberate rather than incidental: at `u = 1.0` exactly, which the seam
// produces, a clamped sampler would pick the wrong edge. Nothing depends on filtering beyond that —
// the map is sampled where it is already pixel-perfect, which is the measurement the phases rest on.

uniform sampler2D cover : filter_linear, repeat_enable;
// Where the layer's coverage puts the threshold, as a percentile of the map — from
// `SpacesimCloudMaps.threshold_for()`, so the drawn coverage is the one that was asked for.
uniform float threshold : hint_range(0.0, 1.0) = 0.0;
// The width of a cloud's edge, in field units. One number drives the coverage and nothing else: the
// deck has no separate alpha channel, because a cloud's boundary being soft and being thin are the
// same fact.
uniform float softness : hint_range(0.001, 0.5) = 0.05;
// **For a deck with no structure to threshold.** A `FEATURELESS` body has no map because there is no
// noise to bake, and an `UNKNOWN` one has no map because nobody has collected its wind scale — and a
// uniform field cannot express partial *area* coverage, since every texel would have to land on the same
// side of the threshold. So the coverage goes here instead, and the result is a veil: uniform, which is
// the honest picture of a hazy world rather than an absent one. Mars, Titan and the two ice giants get
// this, and so does Venus. **1.0 on a mapped deck**, where the map's percentile already carries the area.
uniform float veil : hint_range(0.0, 1.0) = 1.0;
// **Linear, and already scaled to the deck's own albedo by the host** — so what is drawn is the
// reflectance `bond_albedo` uses, not the palette colour, which is a different number entirely.
uniform vec3 cloud_color = vec3(1.0);

// ===== THE AIR THIS DECK SITS UNDER ================================================
//
// **A cloud is a surface under the air, so it is lit and seen through it exactly as the ground is.**
// Without this the deck is lit by the star's full beam and seen unattenuated, which reads as a flat
// white lid from space. It is the same block `body_surface.gdshader` carries, off the same uniforms,
// from the same call — one writer, so the two cannot be told different things about the sun.
uniform float planet_radius = 1.0;
uniform float atmosphere_radius = 0.0;
uniform vec3 rayleigh_coefficient = vec3(0.0);
uniform float rayleigh_scale_height = 1.0;
uniform vec3 absorption_coefficient = vec3(0.0);
uniform float mie_coefficient = 0.0;
uniform float mie_scale_height = 1.0;
uniform vec3 eye_offset = vec3(0.0);
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 sky_illuminance = vec3(0.0);
uniform float sky_diffuse_max = 0.0;
uniform float sky_down_fraction = 0.0;
uniform float sky_min_cos_zenith = 1.0;
uniform float sky_shadow_softness = 1.0;
uniform float reference_lux = 100000.0;

#include "res://addons/spacesim/render/air.gdshaderinc"

// Model space, the offset from the body's centre — which for a unit sphere IS its direction. Captured
// in `vertex()` because **`VERTEX` inside `fragment()` is in VIEW space**.
varying vec3 local_position;


void vertex() {
	local_position = VERTEX;
}


void fragment() {
	vec3 p = normalize(local_position);
	float u = 0.5 + atan(p.z, p.x) / TAU;
	float v = 0.5 - asin(p.y) / PI;
	float height = texture(cover, vec2(u, v)).r;

	// **The percentile as a step, softened.** At `threshold = 0` everything is cloud — which is what a
	// body the model calls FEATURELESS should be, and what a one-texel white map produces.
	float covered = smoothstep(threshold - softness, threshold + softness, height);

	ALBEDO = cloud_color;
	ALPHA = covered * veil;
	ROUGHNESS = 0.9;

	if (atmosphere_radius > planet_radius) {
		// `VERTEX` here is relative to the camera and the body's centre is `-r0`, so the point relative
		// to the body's centre is `VERTEX + r0`. The sun is a direction, so `w = 0` rotates it without
		// its translation — the same two lines the surface shader uses, and for the same reason.
		vec3 r0 = (VIEW_MATRIX * vec4(eye_offset, 0.0)).xyz;
		vec3 point = VERTEX + r0;
		vec3 to_sun = normalize((VIEW_MATRIX * vec4(sun_direction, 0.0)).xyz);
		// **The deck's own altitude is where the column starts**, so the air above it is what dims it —
		// not the air above the ground, which is 100 km deeper. This is the whole of why a deck seen from
		// space is dimmer than its albedo.
		float rayleigh_column = air_column(
			point, to_sun, planet_radius, atmosphere_radius, rayleigh_scale_height
		);
		float mie_column = air_column(
			point, to_sun, planet_radius, atmosphere_radius, mie_scale_height
		);
		vec3 to_eye = normalize(-point);
		float view_rayleigh = air_column(
			point, to_eye, planet_radius, atmosphere_radius, rayleigh_scale_height
		);
		float view_mie = air_column(
			point, to_eye, planet_radius, atmosphere_radius, mie_scale_height
		);
		vec3 sun_transmittance = exp(
			-(rayleigh_coefficient + absorption_coefficient) * rayleigh_column
				- vec3(mie_coefficient * mie_column)
		);
		vec3 view_transmittance = exp(
			-(rayleigh_coefficient + absorption_coefficient) * view_rayleigh
				- vec3(mie_coefficient * view_mie)
		);
		vec3 cloud_albedo = ALBEDO;
		ALBEDO = cloud_albedo * sun_transmittance * view_transmittance;

		// And the sky's own light on the cloud, which at a deck's altitude is the same law as on the
		// ground. **The ground stops the sun ray**, which is what makes the night side need no special
		// case: from a point the star cannot reach, the column comes back empty and the term is a no-op.
		vec3 normal_view = normalize((VIEW_MATRIX * vec4(p, 0.0)).xyz);
		float cos_zenith = dot(normal_view, to_sun);
		float ratio = planet_radius / atmosphere_radius;
		float air_horizon = -sqrt(max(1.0 - ratio * ratio, 0.0));
		float lit = clamp((cos_zenith - air_horizon) / max(sky_shadow_softness, 1.0e-4), 0.0, 1.0);
		vec3 tau_vertical = (rayleigh_coefficient + absorption_coefficient) * rayleigh_scale_height
			+ vec3(mie_coefficient * mie_scale_height);
		float mu = max(abs(cos_zenith), sky_min_cos_zenith);
		vec3 removed = min(1.0 - exp(-tau_vertical / mu), vec3(sky_diffuse_max));
		vec3 sky_lux = sky_illuminance * removed * sky_down_fraction * lit;
		EMISSION += cloud_albedo * view_transmittance * sky_lux / max(reference_lux, 1.0);
	}
}
