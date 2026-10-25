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
