class_name SpacesimAtmosphereModel
extends RefCounted
## A body's air: the numbers the sky shader needs, derived from what the atmosphere is made of.
##
## This is §3.4 of [[SpaceSim/Solar Systems and the Physics Model]] — **the scattering row only**.
## The profiles, retention and the greenhouse are not built; what is here is what a clear sky needs.
## Everything is a pure function of content, so the renderer cannot disagree with the model.
##
## The sky itself is `body_atmosphere.gdshader`, which is `glsl-atmosphere` applied to a shell. Its
## inputs are exactly these numbers — see [[SpaceSim/Atmospheres]].

## Boltzmann, joules per kelvin.
const BOLTZMANN := 1.380649e-23
## Avogadro, per mole.
const AVOGADRO := 6.02214076e23
## Stefan-Boltzmann, watts per square metre per kelvin to the fourth.
const STEFAN_BOLTZMANN := 5.670374419e-8
## Newton's constant.
const GRAVITATION := 6.674e-11

## **Mie scattering is aerosols, not the species mix**, so it cannot be derived from content and is
## named here rather than hidden in the shader. Earth-like values from `glsl-atmosphere`'s example:
## aerosols are coarse enough to scatter forward strongly, which is what `MIE_ANISOTROPY` says.
const MIE_COEFFICIENT := 21.0e-6
const MIE_SCALE_HEIGHT := 1.2e3
const MIE_ANISOTROPY := 0.758

## How bright the sky is, as a multiple of the reference illuminance below. **A look constant, not
## physics**: 22.0 is `glsl-atmosphere`'s own value for Earth at noon, and the shader's output has the
## same shape as the one that value was chosen for.
##
## It is applied *relative to the star's light*, so a sky stays in proportion to the surface the star
## lights instead of getting brighter as you fly outward — the exposure multiplier already divides the
## illuminance back out.
const SKY_INTENSITY := 22.0
## What a multiplier of 1.0 means to the camera. The same number `SpacesimExposure` uses, so the sky
## and the exposure cannot drift apart.
const REFERENCE_LUX := 100_000.0


## Molecules per cubic metre, from the ideal gas law. Everything else follows from this: the
## coefficients are cross-sections **per molecule**, so the density is what turns them into 1/m.
static func number_density(atmosphere: SpacesimAtmosphere, temperature: float) -> float:
	if atmosphere == null or temperature <= 0.0:
		return 0.0
	return atmosphere.surface_pressure / (BOLTZMANN * temperature)


## The per-channel Rayleigh coefficient of the mix, 1/m — `kRlh`, and exactly the argument
## `glsl-atmosphere` takes. Summed as each species' cross-section times its number density.
##
## **Blue scattering most is the whole reason the sky is blue**, so this is a Vector3 and not a float.
## A species with no cross-section in the material table contributes nothing rather than a guess —
## see `coverage()`.
static func rayleigh_coefficient(
	atmosphere: SpacesimAtmosphere, materials: SpacesimMaterialTable, temperature: float
) -> Vector3:
	if atmosphere == null or materials == null:
		return Vector3.ZERO
	var density := number_density(atmosphere, temperature)
	var total := Vector3.ZERO
	for key in atmosphere.species:
		var material := materials.by_name(String(key))
		if material == null:
			continue
		total += material.rayleigh * (float(atmosphere.species[key]) * density)
	return total


## The mix's mean molar mass, grams per mole, weighted by mole fraction.
static func mean_molar_mass(
	atmosphere: SpacesimAtmosphere, materials: SpacesimMaterialTable
) -> float:
	if atmosphere == null or materials == null:
		return 0.0
	var total := 0.0
	for key in atmosphere.species:
		var material := materials.by_name(String(key))
		if material == null:
			continue
		total += material.molar_mass * float(atmosphere.species[key])
	return total


## The altitude over which the air's density falls by 1/e: `kT / (m-bar g)`.
##
## Earth comes out at 8.4 km against the 8.5 km the model doc quotes, and `glsl-atmosphere`'s own
## Earth-like value is 8.0 km — the three agree, which is why this plugs into its shader rather than
## being fitted to it.
static func scale_height(
	atmosphere: SpacesimAtmosphere,
	materials: SpacesimMaterialTable,
	temperature: float,
	gravity: float
) -> float:
	var molar := mean_molar_mass(atmosphere, materials)
	if molar <= 0.0 or gravity <= 0.0 or temperature <= 0.0:
		return 0.0
	var molecule := molar / 1000.0 / AVOGADRO ## kilograms
	return BOLTZMANN * temperature / (molecule * gravity)


## Surface gravity, `GM/r^2`. Content authors mass for every body — see `SpacesimSystemBody` — so
## this needs nothing the derivation stages do not already have.
static func surface_gravity(body: SpacesimSystemBody) -> float:
	if body == null or body.radius <= 0.0:
		return 0.0
	return GRAVITATION * body.mass / (body.radius * body.radius)


## **The temperature the coefficients are evaluated at, and the only one there is.** This is §3.6's
## first row — equilibrium temperature — and it is a placeholder for the real thing: with no
## greenhouse, Earth comes out at 255 K against a measured 288 K, which makes the air about 13%
## denser than it should be. That is a number to fix, not to hide: when §3.6 lands, this is what it
## replaces.
static func equilibrium_temperature(
	body: SpacesimSystemBody,
	materials: SpacesimMaterialTable,
	luminosity: float,
	distance: float
) -> float:
	if body == null or luminosity <= 0.0 or distance <= 0.0:
		return 0.0
	var albedo := SpacesimSurfaceModel.bond_albedo(body, materials)
	# The `4` is the geometry, and it is the difference between 255 K and 1,000 K: a body intercepts
	# `pi r^2` of the light but radiates from `4 pi r^2` of surface.
	var absorbed := (1.0 - albedo) * luminosity / (4.0 * PI * distance * distance * 4.0)
	return pow(absorbed / STEFAN_BOLTZMANN, 0.25)


## How much of the mix actually scatters: the mole fractions with a Rayleigh cross-section, over all
## of them.
##
## **A named gap, not a silent one.** A species whose cross-section is not in the material table
## contributes nothing to the sky, so this is what says whether the air is complete. Everything the
## authored atmospheres use is covered except water vapour (1% of Earth) and hydrogen (a trace of
## Titan); both are small enough to leave out until a body needs them.
static func coverage(atmosphere: SpacesimAtmosphere, materials: SpacesimMaterialTable) -> float:
	if atmosphere == null or materials == null:
		return 0.0
	var covered := 0.0
	var total := 0.0
	for key in atmosphere.species:
		var fraction := float(atmosphere.species[key])
		total += fraction
		var material := materials.by_name(String(key))
		if material != null and material.rayleigh.length_squared() > 0.0:
			covered += fraction
	if total <= 0.0:
		return 0.0
	return covered / total
