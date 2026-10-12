class_name SpacesimTravelScale
extends RefCounted
## The local unit of travel.
##
## Speed is never stored on the ship. Motion is expressed in units of the local
## neighbourhood: `throttle × local_length / TRAVERSE_SECONDS`. Far from everything the
## neighbourhood is huge and you move fast; closing on a planet or a base it shrinks and
## you slow down. There is no mode to engage, no multiplier, and no cap — travelling fast
## in the void and slowly near things falls out of the unit rather than being imposed on
## top of it.
##
## The [b]engine owns the unit[/b]; the flight model is an episode's business. A flight
## model works in neighbourhoods per second and this converts to metres, which is what
## lets different eras fly differently without the engine hard-coding one travel
## mechanism.
##
## `local_length` is clamped to the frame's own scale, so a frame declares the band it
## spans. Keeping frame thresholds and this band in agreement is what stops a visible
## lurch at a frame boundary.

## Seconds to cross the current local neighbourhood at full throttle.
const TRAVERSE_SECONDS := 10.0


## The local neighbourhood, in metres: how far the nearest significant thing is, held
## within the band this frame spans.
##
## Deep space has nothing near enough to matter, which must read as "the largest scale",
## never as zero.
static func local_length(
	distance: float, length_min: float, length_max: float
) -> float:
	if is_inf(distance) or is_nan(distance):
		return length_max
	return clampf(distance, length_min, length_max)


## Speed in metres per second for a throttle position in [0, 1].
##
## Derived, never integrated: there is no speed to desync, and no way to arrive too fast,
## because the limit falls with the remaining distance by construction.
static func speed_for(
	throttle: float,
	distance: float,
	length_min: float,
	length_max: float,
	traverse_seconds: float = TRAVERSE_SECONDS
) -> float:
	var length := local_length(distance, length_min, length_max)
	return clampf(throttle, 0.0, 1.0) * length / maxf(traverse_seconds, 0.001)
