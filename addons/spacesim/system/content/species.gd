class_name SpacesimSpecies
extends Resource
## One substance a body can be made of, or an atmosphere made from. Physical constants live with
## the engine; a system may extend or override the table.

enum Domain { SOLID, LIQUID, GAS }

@export var species_name: String = ""
@export var domain: Domain = Domain.SOLID
@export var density: float = 0.0 ## kg/m3 at the relevant phase
@export var molar_mass: float = 0.0 ## g/mol
@export var albedo: float = 0.0 ## Bond albedo of the material
@export var color: Color = Color.GRAY
## Wavelength-dependent Rayleigh scattering scale, one per channel. **Not yet populated** — the
## sky derivation is a later step, and a guessed cross-section would be worse than an empty one.
@export var rayleigh: Vector3 = Vector3.ZERO
## Infrared band absorptivities for the greenhouse model. **Not yet populated**, same reason.
@export var greenhouse: PackedFloat32Array = []
@export var condensation_temperature: float = 0.0 ## kelvin, 0 where it does not apply
