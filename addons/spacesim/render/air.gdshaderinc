// The air, as arithmetic that more than one shader needs.
//
// **One home for the column.** `body_atmosphere.gdshader` integrates the scattering along a ray, and
// `body_surface.gdshader` has to know how much of the star's light survives the trip down to the
// ground. A second copy of this arithmetic is how the sky and the surface would come to disagree about
// how thick the air is — and the whole point of the pair is that they agree.
//
// Density falls off exponentially with height, so the entire vertical gradient is `exp(-h / H)`: no
// texture, no extra pass, and the same two-line form `glsl-atmosphere` uses.

// The march's resolution. Small on purpose: the density is concentrated in the first scale height, the
// shell is only a handful of scale heights deep, and this runs per pixel on a body that can fill the
// frame. **The number to justify it with is a frame cost, not a picture** — see the profile in the
// commit that introduced it.
const int AIR_STEPS = 8;


// Ray against a sphere centred on the ORIGIN, given a **normalised** direction.
//
// **The miss sentinel is a number, and a plausible one.** `x > y` is the test, and `1e5` on the near
// root is deliberately huge and positive so that a caller which clamps to it without testing is
// caught by that rather than silently accepted — the atmosphere shader's own history.
vec2 air_ray_sphere(vec3 origin, vec3 direction, float radius) {
	float b = 2.0 * dot(direction, origin);
	float c = dot(origin, origin) - (radius * radius);
	float d = (b * b) - (4.0 * c);
	if (d < 0.0) {
		return vec2(1e5, -1e5);
	}
	return vec2((-b - sqrt(d)) * 0.5, (-b + sqrt(d)) * 0.5);
}


// The air along a ray from `origin` (relative to the body's centre) out of the shell: the path integral
// of the relative density `exp(-h / H)`, in metres.
//
// **It starts at the observer and it stops at the planet, and both were bugs once.** The eye can be
// inside the shell, where the near root of the sphere test is behind it and negative — using it raw
// made the step size thousands of times too large and sampled nothing but vacuum. And a ray pointing at
// the body meets it *ahead*, in which case the ground is where the column ends.
//
// Airless bodies need no branch: pass a top radius equal to the planet's and the column is empty.
//
// **The parameters are deliberately NOT named after the uniforms the callers declare.** `planet_radius`
// is a uniform in every shader that includes this, and a parameter of that name makes Godot report
// *"Redefinition of 'planet_radius'"* — at this line, from whichever include came third. It compiled
// with two includes only because of where the `#include` sat relative to their uniforms, which is luck
// rather than a rule; the cloud deck is the shader that proved it. Renamed once for that reason, lost
// when the deck was reverted, and renamed again when it came back — **so if a third include is ever
// removed again, this stays**.
float air_column(vec3 origin, vec3 direction, float solid_radius, float shell_radius, float scale_height) {
	vec2 span = air_ray_sphere(origin, direction, shell_radius);
	if (span.x > span.y) {
		return 0.0;
	}
	float start = max(span.x, 0.0);
	float end = span.y;
	vec2 ground = air_ray_sphere(origin, direction, solid_radius);
	if (ground.x <= ground.y && ground.x > 0.0 && ground.x < end) {
		end = ground.x;
	}
	if (end <= start) {
		return 0.0;
	}
	float step_size = (end - start) / float(AIR_STEPS);
	float depth = 0.0;
	for (int i = 0; i < AIR_STEPS; i++) {
		float height = length(origin + direction * (start + (float(i) + 0.5) * step_size)) - solid_radius;
		depth += exp(-height / scale_height) * step_size;
	}
	return depth;
}
