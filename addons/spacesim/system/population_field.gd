class_name SpacesimPopulationField
extends RefCounted
## The fragments a [SpacesimPopulation] actually has — **made up around the observer, and forgotten
## when they leave.**
##
## Nothing about a fragment is stored anywhere but here and only while it is in range. The population
## is a density; a fragment is drawn from that density inside a ball around the ship, given a circular
## orbit that passes through the point it was drawn at, and dropped once it is outside the ball again.
## Evert, 2026-11-14: *"you calculate the chances of an asteroid being in a position, make up a few that
## are in range, and forget about them when they go out of range again."*
##
## **Nothing moves yet — deliberately, and exactly as the planets and moons do not move.** A fragment's
## orbit is known and correct (its radius, its rate, the direction it will travel), and none of it is
## applied: the position is solved once when the fragment is made, and then it stands still. Evert,
## 2026-11-14: *"in theory we know which direction and speed they will be traveling in, but for
## simplicity's sake nothing is moving yet, that is for a different time when we will focus just on
## that."* `Fragment.velocity()` is therefore what the rock *will* do, not what it is doing, and nothing
## may feed it to a ship's travel unit until the motion lands.
##
## **This is why there is no address lattice and no query inverse.** An earlier design had the
## population indexed by orbital elements so that a fragment's position was a function of its address
## and the clock — and it could not be queried, because the period depends on the semi-major axis
## alone, so the only dimension that localises anything is the radius. Making up the fragments deletes
## that whole problem: nothing has to be inverted, and the density is a number rather than a structure.
##
## The cost, accepted and named: **coming back gives different rocks.** Evert, 2026-11-04: *"If you
## fly away from it, it gets lost in the noise again."*

## How many fragments the field keeps. **The marker pool decides how many are *shown*; this decides
## how many exist**, so that the nearest is always found and the distances are the ones a Poisson
## process at the population's density gives. Two dozen is the pool's own scale.
const FIELD_COUNT := 24

## How many draws a spawn may make before giving up. A ship outside the belt fails every draw, and
## that is the normal case — the field simply stays empty.
const SPAWN_ATTEMPTS := 24

const G := 6.6743e-11


## One fragment: a circle through the point it was drawn at, and the phase along it.
##
## `radius`, `u` and `v` are **relative to the parent body's centre**, so the orbit is a closed form
## with no solver: `position(phase) = parent + radius * (cos(phase) * u + sin(phase) * v)`.
class Fragment:
	var radius: float ## metres from the parent's centre — also the semi-major axis, the orbit being circular
	var u: Vector3 ## unit vector, where the fragment is at phase 0
	var v: Vector3 ## unit vector, perpendicular to `u`, the direction of travel at phase 0
	var phase: float ## radians
	var rate: float ## radians per second, the circular orbital rate at `radius`
	var diameter: float ## metres
	## What its shape is extracted from, so its mesh is the same one every time it is resolved. Its own
	## rather than the population's seed, or every fragment would be the same rock.
	var seed_value: int
	var designation: String ## `A-0007` — the address is gone, so this is its identity for a session


	## **How fast it will be going, and which way, when bodies move** — the derivative of the circle it
	## rides. **Nothing reads this while the world is still**: it is the motion that is known and not
	## applied, and a ship must not inherit it until the rock actually moves.
	func velocity() -> Vector3:
		return radius * rate * (-sin(phase) * u + cos(phase) * v)


var population: SpacesimPopulation

var _fragments: Array[Fragment] = []
var _rng := RandomNumberGenerator.new()
var _made := 0


func _init(p_population: SpacesimPopulation) -> void:
	population = p_population
	_rng.seed = p_population.seed_value if p_population != null else 0


## The fragments the field holds, in no particular order.
func fragments() -> Array[Fragment]:
	return _fragments


## Where a fragment is, in the system frame.
## **The fragments as pieces** — an id, where it is in the system frame, and how big it is. The shape
## [SpacesimFragmentBodies] takes, so a belt and a ring hand rocks to one manager.
func pieces(parent_position: Vector3) -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	for fragment in _fragments:
		list.append({
			"id": fragment.designation,
			"position": position_of(fragment, parent_position),
			"diameter": fragment.diameter,
		})
	return list


func position_of(fragment: Fragment, parent_position: Vector3) -> Vector3:
	return parent_position + fragment.radius * (
		cos(fragment.phase) * fragment.u + sin(fragment.phase) * fragment.v
	)


## Drop the fragments that have left, and make up enough to fill the field again.
##
## **Nothing is advanced**: a fragment stands where it was made. `_delta` is kept in the signature
## because the tick it belongs to is what will move the rock once bodies move — see the class comment.
##
## `mu` is the **parent's** gravitational parameter: a fragment's orbit is the parent's, and a
## fragment has no gravity worth adding to it. It is used when a fragment is made, to give it the rate
## it *will* orbit at.
func update(
	parent_position: Vector3, mu: float, ship_position: Vector3, _delta: float
) -> void:
	if population == null:
		return
	var reach := spawn_radius_of(population)
	if reach <= 0.0 or not is_finite(reach):
		_fragments.clear()
		return

	var kept: Array[Fragment] = []
	for fragment in _fragments:
		if position_of(fragment, parent_position).distance_to(ship_position) <= reach:
			kept.append(fragment)
	_fragments = kept

	for _slot in FIELD_COUNT - _fragments.size():
		var fragment := _spawn(parent_position, mu, ship_position, reach)
		if fragment == null:
			# Every draw landed outside the belt: there is nothing here to fill the field with, and
			# trying the other slots would only repeat the same rejection.
			break
		_fragments.append(fragment)


## The radius of the ball the field is drawn in — **the distance at which `FIELD_COUNT` fragments are
## expected**, at the population's own density. It is what makes the nearest fragment as far away as
## the real belt would put it, instead of as far as a rendering decision would.
static func spawn_radius_of(pop: SpacesimPopulation) -> float:
	var density := density_of(pop)
	if density <= 0.0:
		return 0.0
	return pow(FIELD_COUNT / (4.0 / 3.0 * PI * density), 1.0 / 3.0)


## Fragments per cubic metre that have an address at all — the size floor's cut, not the density of
## the material.
static func density_of(pop: SpacesimPopulation) -> float:
	if pop == null:
		return 0.0
	var volume := volume_of(pop)
	if volume <= 0.0:
		return 0.0
	return addressable_count(pop) / volume


## How many fragments are at or above [member SpacesimPopulation.size_floor], which is the population's
## count of objects rather than of dust.
static func addressable_count(pop: SpacesimPopulation) -> float:
	if pop == null or pop.reference_size <= 0.0 or pop.size_floor <= 0.0:
		return 0.0
	return float(pop.count) * pow(pop.size_floor / pop.reference_size, -pop.size_index)


## The volume the population occupies: a shell between the two semi-major axes, as thick as the
## inclination band makes it. `z` of a fragment at radius r on an orbit inclined by i never exceeds
## r sin i, so the shell's half-thickness is `r sin(i_max)`.
static func volume_of(pop: SpacesimPopulation) -> float:
	if pop == null:
		return 0.0
	var inner := pop.semi_major_axis.x
	var outer := pop.semi_major_axis.y
	if inner <= 0.0 or outer <= inner:
		return 0.0
	var half := sin(deg_to_rad(clampf(pop.inclination.y, 0.0, 90.0)))
	return 4.0 / 3.0 * PI * half * (pow(outer, 3.0) - pow(inner, 3.0))


## Whether a point, relative to the parent's centre, is inside the population's band.
static func in_band(pop: SpacesimPopulation, local: Vector3) -> bool:
	var radius := local.length()
	if radius < pop.semi_major_axis.x or radius > pop.semi_major_axis.y:
		return false
	var half := sin(deg_to_rad(clampf(pop.inclination.y, 0.0, 90.0)))
	return absf(local.z) <= radius * half


## One fragment, drawn inside the ball around the ship that the population's density puts
## `FIELD_COUNT` fragments in, and rejected unless it lands in the band.
func _spawn(
	parent_position: Vector3, mu: float, ship_position: Vector3, reach: float
) -> Fragment:
	for _attempt in SPAWN_ATTEMPTS:
		var local := ship_position + _random_in_ball(reach) - parent_position
		if not in_band(population, local):
			continue
		return _fragment_at(local, mu)
	return null


## Uniform in the ball, so the field's distances are a Poisson process's rather than a shell's.
func _random_in_ball(reach: float) -> Vector3:
	var z := _rng.randf_range(-1.0, 1.0)
	var azimuth := _rng.randf_range(0.0, TAU)
	var ring := sqrt(maxf(0.0, 1.0 - z * z))
	var radius := reach * pow(_rng.randf(), 1.0 / 3.0)
	return Vector3(ring * cos(azimuth), ring * sin(azimuth), z) * radius


## A circular orbit through `local`, tilted into the population's inclination band.
func _fragment_at(local: Vector3, mu: float) -> Fragment:
	var fragment := Fragment.new()
	fragment.radius = local.length()

	var outward := local / fragment.radius
	# A direction perpendicular to `outward` that is flat in the belt's plane, and one that is
	# perpendicular to both — a basis for the orbit's own plane.
	var flat := Vector3.UP.cross(outward)
	if flat.length_squared() < 1e-12:
		# Over a pole: any perpendicular will do, and UP is the one direction that is not one.
		flat = Vector3.RIGHT.cross(outward)
	flat = flat.normalized()
	var rise := outward.cross(flat)

	var tilt := deg_to_rad(_rng.randf_range(
		clampf(population.inclination.x, 0.0, 90.0),
		clampf(population.inclination.y, 0.0, 90.0)
	))
	fragment.u = outward
	fragment.v = (flat * cos(tilt) + rise * sin(tilt)).normalized()
	fragment.phase = 0.0
	fragment.rate = sqrt(maxf(mu, 0.0) / pow(fragment.radius, 3.0)) if mu > 0.0 else 0.0
	fragment.diameter = _random_diameter()
	fragment.seed_value = _rng.randi()
	_made += 1
	fragment.designation = "A-%04d" % _made
	return fragment


## N(>D) proportional to D^-index, inverted: a uniform draw is a diameter with the right distribution.
func _random_diameter() -> float:
	var u := maxf(_rng.randf(), 1.0e-9)
	var diameter := population.size_floor * pow(u, -1.0 / population.size_index)
	return minf(diameter, population.size_ceiling)
