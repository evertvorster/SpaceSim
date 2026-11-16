class_name SpacesimKepler
extends RefCounted
## Where a body is, from its orbital elements. A **pure function of time**: no integration, no
## state, nothing to step forward — so a system is reproducible at any `t` and nothing has to be
## stored to remember it.
##
## The elements are the JPL set: semi-major axis, eccentricity, inclination, longitude of the
## ascending node, argument of periapsis, and mean anomaly at the epoch. Angles are degrees in
## content and radians here.

const G := 6.6743e-11 ## m3 kg-1 s-2
const NEWTON_STEPS := 6 ## converges long before this for the eccentricities that exist


## The gravitational parameter of the **two bodies together**: `G(M + m)`, the primary's mass plus the
## orbiting body's.
##
## Jupiter alone shifts its own period by half a day, so the second term is not a rounding detail.
## Where the orbiting body's mass is not known — the rocky bodies, until mass is derived from their
## layers — only the primary's is used and the period comes out a hair long. That error is about one
## part in a million, which is why it only shows up for the giants.
static func mu_of(total_mass: float) -> float:
	return G * total_mass


## Seconds in the orbital period, from the elements and the two-body parameter [method mu_of].
## Zero when the orbit or the parent's mass is unknown — a body whose mass is not yet derived does
## not move, rather than moving wrongly.
static func period(orbit: SpacesimOrbit, mu: float) -> float:
	if orbit == null or orbit.semi_major_axis <= 0.0 or mu <= 0.0:
		return 0.0
	return TAU * sqrt(pow(orbit.semi_major_axis, 3.0) / mu)


## Where the body is at `t` — world-clock seconds — expressed in its parent's frame.
##
## `mean_anomaly_at_epoch` is measured at `epoch_time`, on the same clock. With a mass of zero the
## orbit does not advance: the body sits at its mean anomaly for the epoch.
static func position_at(orbit: SpacesimOrbit, mu: float, t: float, epoch_time: float) -> Vector3:
	if orbit == null:
		return Vector3.ZERO
	var a: float = orbit.semi_major_axis
	if a <= 0.0:
		return Vector3.ZERO
	var e: float = clampf(orbit.eccentricity, 0.0, 0.999)

	var n: float = 0.0
	if mu > 0.0:
		n = TAU * sqrt(mu / pow(a, 3.0))
	var mean_anomaly := wrapf(deg_to_rad(orbit.mean_anomaly_at_epoch) + n * (t - epoch_time), -PI, PI)

	var eccentric_anomaly := mean_anomaly
	for _step in NEWTON_STEPS:
		var delta := (eccentric_anomaly - e * sin(eccentric_anomaly) - mean_anomaly) \
			/ (1.0 - e * cos(eccentric_anomaly))
		eccentric_anomaly -= delta
		if absf(delta) < 1.0e-12:
			break

	# In the orbital plane, x' pointing from the focus to periapsis.
	var xp := a * (cos(eccentric_anomaly) - e)
	var yp := a * sqrt(1.0 - e * e) * sin(eccentric_anomaly)

	# Rotate into the reference plane: Rz(-node) Rx(-inclination) Rz(-periapsis).
	var w := deg_to_rad(orbit.argument_of_periapsis)
	var i := deg_to_rad(orbit.inclination)
	var o := deg_to_rad(orbit.ascending_node)
	var cw := cos(w)
	var sw := sin(w)
	var ci := cos(i)
	var si := sin(i)
	var co := cos(o)
	var so := sin(o)

	var x := (cw * co - sw * so * ci) * xp + (-sw * co - cw * so * ci) * yp
	var y := (cw * so + sw * co * ci) * xp + (-sw * so + cw * co * ci) * yp
	var z := (sw * si) * xp + (cw * si) * yp

	# The ecliptic frame has its own z through the north pole; the engine's is Y-up and
	# right-handed, so x stays, ecliptic y becomes -z, and ecliptic z becomes y.
	return Vector3(x, z, -y)


## **A body's rotation axis**, in the engine's frame: the normal of its orbital plane, tilted by its `axial_tilt`
## about the orbit's own ascending node.
##
## **This is what `axial_tilt` has always meant**, and until now nothing read it: the content format states it as
## *"degrees, obliquity in `[0, 180]`, from the body's orbital plane"*, and every planet was drawn with the
## engine's +Y as its pole. Evert, 2026-11-16: *"There is no up in space. Most planets rotate with their axis
## perpendicular to the orbit. So, these should have been authored and tested long ago when we first drew
## planets"* — right on both counts.
##
## The engine's +Y is the ecliptic's north (the mapping below sends ecliptic `z` to engine `y`), so a body with
## no tilt already has its pole along +Y and the correction is the tilt alone — which is why this changes so
## little in the picture and so much in what the picture means: a tilted pole is what gives a ringed planet its
## season, and its rings their plane.
##
## **The direction of the tilt** is the ascending node's, which is deterministic, perpendicular to the orbit
## normal, and fixed in the orbit's frame — so as the body travels round its orbit the star's angle to its pole
## changes exactly as a real axial tilt makes a season. `axial_tilt > 90` is retrograde content, and rotating by
## more than a right angle is exactly how a retrograde planet's pole ends up on the other side.
static func pole(orbit: SpacesimOrbit, axial_tilt_degrees: float) -> Vector3:
	if orbit == null:
		return Vector3.UP
	var i := deg_to_rad(orbit.inclination)
	var o := deg_to_rad(orbit.ascending_node)
	# The orbit normal in the reference plane, then in the engine's frame — the same mapping `position_at`
	# applies, `(x, z, -y)`, so the two cannot disagree about which way is up.
	var normal := Vector3(sin(i) * sin(o), cos(i), -sin(i) * cos(o)).normalized()
	# The ascending node's direction: ecliptic `(cos o, sin o, 0)` mapped the same way.
	var node := Vector3(cos(o), 0.0, -sin(o)).normalized()
	return normal.rotated(node, deg_to_rad(clampf(axial_tilt_degrees, 0.0, 180.0))).normalized()
