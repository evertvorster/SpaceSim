class_name SpacesimSystemBody
extends Resource
## One **body** in a solar system: a star, planet, dwarf planet or moon.
##
## **Content only.** Everything derived from this — mass (except a star's), gravity, the
## atmosphere profiles, temperature, colour — is computed at load and never stored here, and the
## built scene (nodes, meshes, frames) lives in [code]SpacesimSceneBody[/code]. A resource is cached
## and shared, so it must not hold node references.
##
## "Body", not "world": a *world* is how much of the cosmos a player has explored, which is
## personal and differs between players. See the Cosmos and Discovery note.

enum Kind { STAR, PLANET, DWARF_PLANET, MOON }

@export var id: String = "" ## stable id, `kind:name` — `star:sol`, `planet:earth`, `moon:luna`
@export var display_name: String = ""
@export var kind: Kind = Kind.PLANET
## What it orbits. Empty means the primary star.
@export var parent_id: String = ""
## The star the system is named after. Exactly one body in a system is primary.
@export var primary: bool = false
@export var radius: float = 0.0 ## metres, mean
## Kilograms. **Authored for stars**: a self-gravitating body's mass is the fundamental and its
## radius is a consequence, so deriving mass from radius and composition would be backwards.
## 0.0 for every other body means "derive it from the layers".
@export var mass: float = 0.0
@export var rotation_period: float = 0.0 ## seconds, sidereal, ALWAYS positive
## Degrees, obliquity in [0, 180] from the orbital plane. **Retrograde is > 90**, never a negative
## rotation period — one place for the direction, so Venus and Uranus cannot be double-counted.
@export var axial_tilt: float = 0.0
@export var layers: Array[SpacesimLayer] = []
## Null means this body does not move: it stands at [member fixed_position]. A body either orbits
## or is fixed, so "both" is impossible rather than merely rejected.
@export var orbit: SpacesimOrbit
@export var fixed_position: Vector3 = Vector3.ZERO
@export var atmosphere: SpacesimAtmosphere
@export var surface: SpacesimSurface
## The cloud deck. On the body rather than inside the atmosphere, because a gas giant's visible surface
## *is* its cloud deck — what the body looks like, not a property of its air, which the giants do have.
@export var clouds: SpacesimClouds
@export var overrides: SpacesimBodyOverrides
## Whether it gets atmosphere and surface frames. Authored for now: a content judgement, not a
## physical fact, though deriving a default from [member kind] is the tidy end state.
@export var landable: bool = true
## Whether it is worth marking on screen. A body can be worth flying to without being worth a
## label — every rock in a belt is the latter.
@export var significant: bool = true


func kind_name() -> String:
	match kind:
		Kind.STAR: return "star"
		Kind.PLANET: return "planet"
		Kind.DWARF_PLANET: return "dwarf_planet"
		Kind.MOON: return "moon"
	return "body"


## Whether this body moves. A body with no orbit is fixed.
func orbits() -> bool:
	return orbit != null
