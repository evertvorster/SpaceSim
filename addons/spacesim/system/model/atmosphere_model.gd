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

## **How many scale heights of air to draw.** The shell's top is derived, not authored: the air thins
## exponentially, so "where it ends" is a multiple of `kT/(m-bar g)` and nothing else.
##
## Ten puts the density at `e^-10` — one part in 22,000 of the surface — which is invisible. **It
## matters that this is per body and not one number for the system**: at a fixed 100 km the shell is
## twelve scale heights over Earth but only four over Jupiter, where the air is still 2% of surface
## density at the top and the shell would end in visible haze.
const SHELL_SCALE_HEIGHTS := 10.0


## Below this the atmosphere is convective and follows the adiabat; above it, radiative. Named because
## it is the grey-atmosphere skin temperature, `2^-1/4` of the effective temperature -- the temperature
## a blackbody-only atmosphere settles at with no greenhouse at all.
const SKIN_TEMPERATURE_FACTOR := 0.8408964152537145 ## 2 ** -0.25


## The mix's specific heat capacity at constant pressure, J/(kg·K).
##
## **Mass-weighted, not mole-weighted** — this one is per kilogram, so the fractions that enter are mass
## fractions. Every other mix in this file is mole-weighted, and getting this one wrong by copying them
## would be a quiet factor of about four on the lapse rate.
static func heat_capacity(
	atmosphere: SpacesimAtmosphere, materials: SpacesimMaterialTable
) -> float:
	if atmosphere == null or materials == null:
		return 0.0
	var total := 0.0
	var mass := 0.0
	for key in atmosphere.species:
		var material := materials.by_name(String(key))
		if material == null:
			continue
		var amount := float(atmosphere.species[key]) * material.molar_mass
		total += amount * material.heat_capacity
		mass += amount
	if mass <= 0.0:
		return 0.0
	return total / mass


## The **dry adiabatic lapse rate**, `g / c_p`, in kelvin per metre: how fast a convecting parcel cools
## as it rises.
##
## This is where the profile comes from, and it is a real check rather than a fitted number: Earth's
## composition and gravity give **9.78 K/km**, against the textbook 9.8, and Venus's give ~10.5.
static func lapse_rate(
	atmosphere: SpacesimAtmosphere,
	materials: SpacesimMaterialTable,
	gravity: float
) -> float:
	var capacity := heat_capacity(atmosphere, materials)
	if capacity <= 0.0 or gravity <= 0.0:
		return 0.0
	return gravity / capacity


## The temperature at a height above the surface, kelvin.
##
## **Convective below, radiative above.** A parcel of air that is warmer than its surroundings rises and
## cools at `lapse_rate`; that can continue only until it meets the temperature the radiation alone
## would hold, which is the **skin temperature** `0.8409 * T_eff` at the top. So the profile is the
## adiabat down from the tropopause to the surface, and the surface temperature is what that adiabat
## lands on.
##
## **Named limitation:** this is a *dry* adiabat. Real convection is moist, which flattens the upper
## troposphere — Earth's tropopause comes out at 7.4 km against a real 11-12. It does not affect cloud
## *bases*, which is what the profile is chiefly for, and moist convection is the refinement.
static func temperature_at(
	height: float,
	surface_temperature: float,
	lapse: float,
	tropopause_temperature: float
) -> float:
	return maxf(surface_temperature - lapse * maxf(height, 0.0), tropopause_temperature)


## The **grey infrared optical depth** of the whole column, top to surface: `sum(kappa_i * column_i)`.
##
## Each species' column mass is `x_i * (M_i / m-bar) * (p_surface / g)` — mole fraction turned into a
## mass fraction and multiplied by the total column `p/g` — so this needs nothing that is not already
## derived. `kappa` is the material table's `greenhouse[0]`, and it is **zero** for the gases that are
## transparent in the infrared rather than absent, so "known transparent" and "not known" do not look
## alike.
static func greenhouse_optical_depth(
	atmosphere: SpacesimAtmosphere,
	materials: SpacesimMaterialTable,
	gravity: float
) -> float:
	if atmosphere == null or materials == null or gravity <= 0.0:
		return 0.0
	var molar := mean_molar_mass(atmosphere, materials)
	if molar <= 0.0:
		return 0.0
	var column := atmosphere.surface_pressure / gravity ## kg/m2, the whole air
	var depth := 0.0
	for key in atmosphere.species:
		var material := materials.by_name(String(key))
		if material == null or material.greenhouse.is_empty():
			continue
		var mass_fraction := float(atmosphere.species[key]) * material.molar_mass / molar
		depth += material.greenhouse[0] * mass_fraction * column
	return depth


## **The surface temperature, with the greenhouse.** The grey-atmosphere result, which is textbook:
##
##     T_surface = T_eff * (1 + 3 * tau / 4) ^ (1/4)
##
## An atmosphere that is transparent in the infrared (`tau = 0`) leaves the surface at `T_eff`, which
## is the right answer for an airless body and for Titan's nearly-clear methane. As `tau` grows the
## surface warms, and **Venus is why this is worth having**: 92 bar of CO2 gives `tau` of 142 and a
## surface 508 K above its equilibrium temperature, out of the column mass alone. No cloud term is
## needed for that — the sulphuric-acid deck is already in the albedo, and the two agree.
static func surface_temperature(
	atmosphere: SpacesimAtmosphere,
	materials: SpacesimMaterialTable,
	gravity: float,
	equilibrium: float
) -> float:
	if equilibrium <= 0.0:
		return equilibrium
	var depth := greenhouse_optical_depth(atmosphere, materials, gravity)
	return equilibrium * pow(1.0 + 0.75 * depth, 0.25)


## The temperature a purely radiative atmosphere would hold at its top: `2^-1/4 * T_eff`, the
## grey-atmosphere skin temperature. Below this the profile is the adiabat instead.
static func tropopause_temperature(equilibrium: float) -> float:
	return equilibrium * SKIN_TEMPERATURE_FACTOR


## How far above the surface the air is worth drawing, in metres: `SHELL_SCALE_HEIGHTS` scale heights.
##
## **Derived, and it has to be.** The alternative — one authored altitude for the whole system — is
## right for exactly one body. A caller that needs the air to cover a region regardless (a frame's
## transition altitude, say) takes the maximum of this and its own floor.
static func shell_reach(
	atmosphere: SpacesimAtmosphere,
	materials: SpacesimMaterialTable,
	temperature: float,
	gravity: float
) -> float:
	return scale_height(atmosphere, materials, temperature, gravity) * SHELL_SCALE_HEIGHTS


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


## **The temperature the coefficients are evaluated at.** In order of authority:
##
## 1. **What content pinned.** Content wins everywhere else and it wins here; for the gas giants it is
##    the only right answer, because they radiate more than they receive and their warmth is
##    collision-induced absorption rather than molecular bands. A pinned value is a **measured** one,
##    which is what the model is checked against.
## 2. **The greenhouse**, `surface_temperature()` — equilibrium plus the warming from the column. This
##    is what turns Earth's 254 K of insolation into 288 K and Venus's 229 K into 737 K.
## 3. **Equilibrium**, for a body with no `atmosphere` block at all.
##
## **This is the number the whole sky hangs on.** `kRlh` is proportional to 1/T and the scale height to
## T, so the greenhouse's arrival is visible without touching the shader: Venus's air was 3.2x too
## dense and 3.2x too shallow until this landed.
static func reference_temperature(
	body: SpacesimSystemBody,
	materials: SpacesimMaterialTable,
	luminosity: float,
	distance: float
) -> float:
	if body != null and body.overrides != null \
		and body.overrides.set.has("mean_surface_temperature"):
		return body.overrides.mean_surface_temperature
	var equilibrium := equilibrium_temperature(body, materials, luminosity, distance)
	if body == null or body.atmosphere == null:
		return equilibrium
	return surface_temperature(
		body.atmosphere, materials, surface_gravity(body), equilibrium
	)


## **Equilibrium temperature — §3.6's first row, and the placeholder for the real thing.** With no
## greenhouse Earth comes out at 255 K against a measured 288 K, which makes the air about 13% denser
## than it should be. That is a number to fix, not to hide: when §3.6 lands, this is what it replaces.
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
