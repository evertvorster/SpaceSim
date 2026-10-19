class_name SpacesimLuminance
extends RefCounted
## **What the eye adapts to**, as arithmetic: solid angles, whether a source is in the frame, whether
## something stands in front of it, and a body's disc-averaged luminance.
##
## This is the shape [SpacesimLod] established for the same reason — **nothing here knows a body, a node
## or a camera.** It takes numbers and returns numbers, so the reasoning below can be read and tested
## without building a solar system. What stays in `SpacesimSystemScene` is the *policy*: which bodies
## count, which bodies can occlude which, and the one distance at which the air is worth adding.
##
## The consumers are the exposure (through `SpacesimSystemScene.view_luminance_at`) and the point of
## light a body becomes below the mesh tier. **They are the same number on purpose** — see
## [method disc_luminance].

## The solid angle of a cone of half-angle `angular_radius`, in steradians: `2*pi*(1 - cos theta)`.
##
## A body's share of the view. Used for both the star and every lit body, because the only thing that
## distinguishes them is where the distance comes from.
static func cone_solid_angle(angular_radius: float) -> float:
	return 2.0 * PI * (1.0 - cos(clampf(angular_radius, 0.0, PI)))


## The solid angle of the **view itself** — a rectangular pyramid of tangent half-extents `(x, y)`:
## `4*atan(x*y / sqrt(1 + x^2 + y^2))`.
##
## Exact, rather than the `4*x*y` small-angle form, because it divides every other solid angle in this
## file and the field is not always narrow.
static func pyramid_solid_angle(tan_half: Vector2) -> float:
	if tan_half.x <= 0.0 or tan_half.y <= 0.0:
		return 0.0
	return 4.0 * atan(tan_half.x * tan_half.y
		/ sqrt(1.0 + tan_half.x * tan_half.x + tan_half.y * tan_half.y))


## The frame's half-diagonal, in radians: `atan(sqrt(x^2 + y^2))`.
##
## The cone a source's centre has to be inside to be in frame at all, before its own angular size is
## allowed for.
static func half_diagonal(tan_half: Vector2) -> float:
	return atan(sqrt(tan_half.x * tan_half.x + tan_half.y * tan_half.y))


## Whether a source's centre lies in the frame, **allowing for its own angular size** — a body that
## fills the view has its centre in view only by a technicality, and one just outside the corner is
## still partly in frame.
static func in_view(forward: Vector3, direction: Vector3, half_diagonal: float,
		angular_radius: float) -> bool:
	return acos(clampf(forward.dot(direction), -1.0, 1.0)) <= half_diagonal + angular_radius


## **Whether a sphere stands in front of a source.** [method in_view] asks only whether something is
## inside the frame's cone, which says nothing about whether it can be seen: from a planet's night side
## the Sun is in that cone whenever the camera points at the ground, because pointing at the ground
## points at the Sun *through the planet*.
##
## **A point-to-segment test rather than a ray cast** — the bodies are spheres and the span is short, so
## the closed form is exact and needs no physics query. The caller excludes the source itself, which
## cannot occlude itself.
##
## **The clamp at `t = 0.0` is what keeps the body under the observer from occluding anything.**
## Standing on a surface, the closest point of the segment is the observer's own feet, and those are
## `radius + altitude` from the centre — outside it. So a Sun above the local horizon has a negative
## projection and is never occluded, one just below it is grazing and still is not, and only one that is
## genuinely behind the body is. Nothing here models refraction, which makes the real Sun visible for
## another half a degree below the horizon.
static func occluded(observer: Vector3, target: Vector3, centre: Vector3, radius: float) -> bool:
	var span := target - observer
	var span_length_squared := span.length_squared()
	if span_length_squared <= 0.0:
		return false
	var offset := centre - observer
	var t := clampf(offset.dot(span) / span_length_squared, 0.0, 1.0)
	return offset.distance_squared_to(span * t) < radius * radius


## **A body's disc-averaged luminance**, in lux per steradian:
##
##     L = illuminance * bond_albedo * lambert_phase(phase_angle) / pi
##
## **One expression, used by two things** — the exposure's sum and the point of light a body becomes
## when it is too small to be a disc. That is what makes the handoff at the mesh threshold free: the
## splat and the disc agree in brightness there because they are the same number, not because two
## arithmetics happen to coincide.
##
## The phase term is the **disc-averaged illuminated fraction**, not a clamped cosine — see
## `SpacesimSurfaceModel.lambert_phase`. A clamped cosine is exactly zero past the half moon, so a
## crescent, which is most of what you see of a planet from anywhere interesting, would contribute
## nothing at all.
##
## Returns 0 for a body that reflects nothing or is entirely unlit, so a caller can skip it without a
## second test.
static func disc_luminance(illuminance: float, bond_albedo: float, phase_angle: float) -> float:
	if bond_albedo <= 0.0 or illuminance <= 0.0:
		return 0.0
	var phase := SpacesimSurfaceModel.lambert_phase(phase_angle)
	if phase <= 0.0:
		return 0.0
	return illuminance * bond_albedo * phase / PI


## The **phase angle** of a body as seen from an observer: the angle at the body between the observer
## and the star. `0` is a full disc, `pi` is new.
##
## Here rather than at the call site because its two consumers must not drift: a body drawn as a disc
## and the same body as a point of light have to agree, and the angle is where they would part.
##
## **Degenerate input returns `pi`, not `0`.** An observer standing at the body's centre, or a body
## exactly at the star, has no phase — and `0` means *fully lit*, so the two failures that matter here
## would both show a bright disc for a body whose position could not be resolved. Returning `pi` makes
## a body that cannot be located read as dark, and `disc_luminance` drops it either way.
static func phase_angle(body_position: Vector3, observer: Vector3, star_position: Vector3) -> float:
	var to_observer := observer - body_position
	var to_star := star_position - body_position
	if to_observer.length_squared() <= 0.0 or to_star.length_squared() <= 0.0:
		return PI
	return acos(clampf(to_observer.normalized().dot(to_star.normalized()), -1.0, 1.0))
