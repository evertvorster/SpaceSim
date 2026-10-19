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
## **`condensation_temperature` is the 1-ATMOSPHERE VAPOUR-PRESSURE REFERENCE** — the temperature at
## which the pure substance' s vapour pressure equals 101,325 Pa. That is the normal **boiling point** for
## a liquid, and the **sublimation point** for a solid with no liquid phase at 1 atm.
##
## **It is NOT a melting or triple point, and this table held both meanings at once** until 2026-10-16.
## Water's was 273.15 (its triple point) while ammonia's was 239.8 (its boiling point), so a
## Clausius-Clapeyron correction from it gave ammonia the right answer and water a dew point **60 K too
## low** — which would have put Earth's cloud base at 8 km instead of 1.7.
@export var latent_heat: float = 0.0
## **Latent heat, J/mol** — what turns the 1-atm reference above into a condensation temperature at the
## pressure the species is actually at. Zero means "not known", and the table's 1-atm value is then used
## unchanged, which is right for nothing but a pure substance at 1 bar.
## **The species this one is MADE FROM, or empty if it is not a product.**
##
## Ammonium hydrosulphide is not a gas anybody puts in an atmosphere: NH\u2083 and H\u2082S meet at a level
## and combine there. So a product is never looked for in an atmosphere's mix — it is looked for in the
## species table, and it exists only where **all** of these reactants are present. That is the whole
## difference between it and a condensing gas, and the reason a giant with no ammonia in its mix has no
## NH\u2084SH deck however cold it is.
##
## Empty means an ordinary species: it condenses where its own `T_cond` is crossed.
@export var formed_from: PackedStringArray = []
## **Specific heat capacity at constant pressure**, J/(kg·K) — what sets the adiabatic lapse rate
## `g / c_p`, and therefore the shape of every temperature profile. Sourced physical values, like
## `density` and `molar_mass`; zero where a species is not a gas.
##
## Note that this one mixes by **mass** and not by mole fraction, because it is per kilogram.
@export var heat_capacity: float = 0.0

## **The melting point**, in kelvin — where a solid becomes a liquid.
##
## **`condensation_temperature` is NOT this**, and the two were one field in spirit until it was written
## down: that one is the 1-atm *vapour-pressure* reference, which for a substance with a liquid phase is its
## boiling point. A phase needs both ends — solid below the melting point, liquid between it and the boiling
## point, gas above — so the end that was missing is here rather than inferred from the other.
##
## **Zero means "not known"**, the table's standing rule: a substance without one yields `Phase.UNKNOWN`
## rather than a phase guessed from a plausible number.
@export var melting_temperature: float = 0.0

## **The pressure below which the substance has no liquid phase at all**, in pascals — its triple point.
##
## Zero means "not known" and is treated as "no such limit", which is right for nearly everything. The one
## case that matters is the exception that proves it: **CO2 sublimes at 1 atm**, its triple point sitting
## at 5.18 bar, which is why Mars has no liquid CO2 at 636 Pa however warm it gets. That is a derived
## result once this number exists, not a note in a doc.
@export var triple_point_pressure: float = 0.0
