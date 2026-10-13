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
## Wavelength-dependent Rayleigh scattering scale, one per channel, in **square metres per
## molecule** at the three channel wavelengths (red, green, blue). The sky derivation sums each
## species' value times its number density to get the mix's coefficient — see
## [code]SpacesimAtmosphereModel[/code] and [code]materials.tres[/code], which records where the
## numbers came from. Zero where a species has no measured cross-section yet; that gap is **named**
## rather than filled in with a plausible number.
@export var rayleigh: Vector3 = Vector3.ZERO
## Infrared band absorptivities for the greenhouse model. **Not yet populated** — the greenhouse is
## not built, and a guessed absorptivity would be worse than an absent one.
@export var greenhouse: PackedFloat32Array = []
@export var condensation_temperature: float = 0.0 ## kelvin, 0 where it does not apply
## **Specific heat capacity at constant pressure**, J/(kg·K) — what sets the adiabatic lapse rate
## `g / c_p`, and therefore the shape of every temperature profile. Sourced physical values, like
## `density` and `molar_mass`; zero where a species is not a gas.
##
## Note that this one mixes by **mass** and not by mole fraction, because it is per kilogram.
@export var heat_capacity: float = 0.0
