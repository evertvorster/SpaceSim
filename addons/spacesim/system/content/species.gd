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
## Wavelength-dependent **absorption** cross-section, one per channel, in **square metres per molecule**
## at the same three wavelengths `rayleigh` uses (680, 550, 440 nm).
##
## **Not the same quantity as `greenhouse`.** That one is a grey *infrared* mass-absorption coefficient
## with nothing to say about sunlight; this one is what sunlight is lost to. Together with `rayleigh` it
## gives the mix its `ω = σ_scatter / σ_extinct` — the single-scattering albedo, which is what decides
## whether a thick air reflects like a mirror or dims like a filter, and the only thing that makes
## `k = sqrt(3(1-w)(1-wg))` non-zero for the two-stream limit.
##
## **Zero where a species has no measured value yet**, by the same rule `rayleigh` follows: the gap is
## named rather than filled in with a plausible number. The visible absorbers that matter are **ozone**
## (the Chappuis band, and Earth's whole visible absorption), **methane** (Titan) and NO2 — while CO2, N2
## and O2 are transparent through the visible, which is why this cannot be what makes Venus's air dark.
@export var absorption: Vector3 = Vector3.ZERO
## Infrared band absorptivities for the greenhouse model, m²/kg **per band** — the array being where
## more bands would go. Populated in `materials.tres`, and read by
## [code]SpacesimAtmosphereModel.greenhouse_optical_depth()[/code], which is where Earth's 288 K and
## Venus's 737 K come from. Each value is fixed against one measured surface temperature; N₂, O₂,
## Ar, He and H₂ are explicitly **zero**, so "known transparent" and "not known" do not look alike.
@export var greenhouse: PackedFloat32Array = []
@export var condensation_temperature: float = 0.0 ## kelvin, 0 where it does not apply
## **Specific heat capacity at constant pressure**, J/(kg·K) — what sets the adiabatic lapse rate
## `g / c_p`, and therefore the shape of every temperature profile. Sourced physical values, like
## `density` and `molar_mass`; zero where a species is not a gas.
##
## Note that this one mixes by **mass** and not by mole fraction, because it is per kilogram.
@export var heat_capacity: float = 0.0
