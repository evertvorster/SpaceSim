class_name SpacesimPopulation
extends Resource
## A population of small bodies in a solar system — the asteroid belt, a ring — as **content**.
##
## A population is a **distribution**, not a list: nothing here describes a fragment. The fragments
## are made up around the observer from these numbers, kept while they are in range, and dropped when
## they leave. Evert, 2026-11-14: *"you calculate the chances of an asteroid being in a position, make
## up a few that are in range, and forget about them when they go out of range again."*
##
## That is why there is no address, no lattice and no stored position anywhere: a fragment is a
## short-lived thing the field invents, and coming back to the same place gives different rocks.
## Evert's own rule from the design's first sitting, 2026-11-04: *"If you fly away from it, it gets
## lost in the noise again."*
##
## **A population is not a body and is not in [member SpacesimSolarSystem.bodies].** It has no radius,
## no mass, no layers, and nothing orbits it. See the vault: "Asteroids and Rings", and the plan
## "Asteroids and Rings Plan".

@export var id: String = "" ## stable id, `population:main_belt`
@export var display_name: String = ""
## What it orbits. Empty means the primary star, exactly as for a body. A ring is the same type with
## its parent set to the planet.
@export var parent_id: String = ""
## Fragments are drawn with this. Two fields in one session do not look alike.
@export var seed_value: int = 0

## Mass fractions per species, summing to 1 — the same shape a layer's composition has, so a fragment
## is made of something the material table knows, and what it is worth follows from what it is.
@export var composition: Dictionary[String, float] = {}

## The radial extent, metres, as semi-major axes. Sol's main belt is 2.1 to 3.3 AU.
@export var semi_major_axis: Vector2 = Vector2.ZERO
## Degrees, to the reference plane. **This is the belt's thickness**, not a per-fragment tilt that
## has to be inverted: a fragment is placed inside |z| <= r sin(i), and its own orbit is then given
## its tilt from the band.
@export var inclination: Vector2 = Vector2.ZERO

## The anchor every count is derived from: how many fragments are at or above
## [member reference_size]. Sol's published figure is 1.1 million above 1 km.
@export var reference_size: float = 1000.0
@export var count: int = 0
## Cumulative size distribution, N(>D) proportional to D^-size_index. Dohnanyi's collisional cascade
## gives 2.5, which is what the belt follows below 100 km.
@export var size_index: float = 2.5
## The smallest fragment that exists at all. Below it the material is dust: it is part of the
## distribution's mass and none of its objects.
@export var size_floor: float = 10.0
## The largest, where the power law is clamped — it is only valid below ~100 km, and Ceres is 940.
@export var size_ceiling: float = 5.0e5
