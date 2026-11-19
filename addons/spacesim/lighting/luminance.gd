class_name SpacesimLuminance
extends RefCounted
## **A body's brightness as the eye sees it**, as arithmetic: a disc-averaged luminance and the phase
## angle it depends on.
##
## This is the shape [SpacesimLod] established for the same reason — **nothing here knows a body, a node
## or a camera.** It takes numbers and returns numbers, so the reasoning can be read and tested without
## building a solar system.
##
## The consumer is the point of light a body becomes below the mesh tier — [method disc_luminance].
##
## **The view half is gone.** `cone_solid_angle`, `pyramid_solid_angle`, `half_diagonal`, `in_view` and
## `occluded` served the exposure's sum over the frame, which measured what the eye was *looking at*;
## `SpacesimExposurePass` meters the rendered frame now, so that whole integral went with it. `Lighting
## Plan` §6a has the reasoning and §B4 the decision.

## **A body's disc-averaged luminance**, in lux per steradian:
##
##     L = illuminance * bond_albedo * lambert_phase(phase_angle) / pi
##
## **One expression, and one consumer** — the point of light a body becomes when it is too small to be a
## disc.
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


## **How much of the star a point can see**, 1 in full light and 0 in the caster's umbra — the fraction of
## the star's disc that the caster does not cover.
##
## **The engine's shadow law, and there are no shadow maps in it.** A planet's shadow is a geometric fact
## about where the star is, so it is computed from two circles on the sky: the star's apparent disc of
## angular radius `alpha`, the caster's of `beta`, and the angle `theta` between their centres. The area
## they share, over the star's own area, is how much light is missing. Partial overlap is the penumbra,
## which falls out rather than being modelled.
##
## Derived from the project's `Lighting Plan`, where it replaced a shadow map that never worked at a
## planet's scale. Evert, 2026-11-15, on Saturn's shadow across its rings: *"it looks like the planet just
## does not cast shadows. I complained about this a long time ago."* He is right, and a ring is where the
## absence is unmissable.
static func shadow_fraction(
	point: Vector3, star_position: Vector3, caster_position: Vector3, caster_radius: float,
	star_radius: float
) -> float:
	var to_star := star_position - point
	var to_caster := caster_position - point
	if to_star.length_squared() <= 0.0 or to_caster.length_squared() <= 0.0:
		return 1.0
	var alpha := asin(clampf(star_radius / to_star.length(), 0.0, 1.0))
	# **A point inside the caster is in its umbra by definition**, and the apparent radius of a sphere seen
	# from inside it is more than a hemisphere.
	var caster_distance := to_caster.length()
	var beta := (
		PI * 0.5 if caster_distance <= caster_radius
		else asin(clampf(caster_radius / caster_distance, 0.0, 1.0))
	)
	var theta := to_star.angle_to(to_caster)
	if alpha <= 0.0:
		# A point star cannot be partly covered: it is behind the caster or it is not.
		return 0.0 if theta < beta else 1.0
	var covered := _disc_overlap(alpha, beta, theta) / (PI * alpha * alpha)
	return clampf(1.0 - covered, 0.0, 1.0)


## The area two circles of angular radii `alpha` and `beta` share, their centres `theta` apart — the sum of
## two circular segments. Zero when they do not touch, the smaller disc's whole area when one is inside the
## other.
static func _disc_overlap(alpha: float, beta: float, theta: float) -> float:
	if theta >= alpha + beta:
		return 0.0
	if theta <= absf(alpha - beta):
		var smaller := minf(alpha, beta)
		return PI * smaller * smaller
	# Each segment: `r^2 acos(x/r) - x sqrt(r^2 - x^2)`, with `x` the half-distance from the lens's centre.
	var x := (
		alpha * alpha - beta * beta + theta * theta
	) / (2.0 * theta)
	var y := sqrt(maxf(alpha * alpha - x * x, 0.0))
	var segment_alpha := alpha * alpha * acos(clampf(x / alpha, -1.0, 1.0)) - x * y
	var other := theta - x
	var segment_beta := beta * beta * acos(clampf(other / beta, -1.0, 1.0)) - other * y
	return segment_alpha + segment_beta
