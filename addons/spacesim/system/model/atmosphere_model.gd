class_name SpacesimAtmosphereModel
extends RefCounted
## A body's air: the numbers the sky shader needs, derived from what the atmosphere is made of.
##
## This is §3.4 of [[SpaceSim/Solar Systems and the Physics Model]] **and §3.6's first two rows**:
## the scattering coefficients the sky shader takes, the profiles, and the greenhouse. Retention
## (Jeans escape) is the one part that is not built. Everything is a pure function of content, so the
## renderer cannot disagree with the model.
##
## The sky itself is `body_atmosphere.gdshader`, which is `glsl-atmosphere` applied to a shell. Its
## inputs are exactly these numbers — see [[SpaceSim/Atmospheres]].

## A temperature for the callers that take one and for the internals that must not care. **The air's
## reflection does not depend on it** — see `clear_sky_albedo`, where the cancellation is spelled out —
## so this is a formality rather than a physical input.
const REFERENCE_TEMPERATURE := 288.0
## Boltzmann, joules per kelvin.
const BOLTZMANN := 1.380649e-23
## The gas constant, J/(mol K) — for Clausius-Clapeyron.
const GAS_CONSTANT := 8.314
## One atmosphere, in pascals: the reference pressure
## `SpacesimSpecies.condensation_temperature` is stated at.
const ATMOSPHERIC_PRESSURE := 101325.0
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

## **The sky's scale is the star's own light, converted — there is no free constant in it.**
##
## The shader's integration returns a quantity in **inverse steradians**: the phase function times the
## optical depth, with the phase functions normalised the way they have to be (`3/(16π)(1+cos²θ)` for
## Rayleigh, so `∫p dΩ = 1`). Multiplying that by an illuminance in lux gives a radiance in **lux per
## steradian** — and the engine's radiance unit is `REFERENCE_LUX / π`, because a white Lambertian under
## `REFERENCE_LUX` has radiance `REFERENCE_LUX / π` and renders as `1.0`. So the conversion is the whole
## of it:
##
##     scale = illuminance * PI / REFERENCE_LUX
##
## **It replaces `SKY_INTENSITY = 22.0`**, which was `glsl-atmosphere`'s own value for Earth at noon: a
## number with no derivation, chosen against units its author never stated. Earth at noon is what checks
## the derived one — `3/(16π)·2·τ` in blue is about `0.031`, and the conversion turns that into ~4,000
## lux/sr, which is what a clear zenith sky measures. The old constant drew the same sky about seven
## times brighter than that.
static func sky_scale(illuminance: float) -> float:
	return illuminance * PI / REFERENCE_LUX

## What a multiplier of 1.0 means to the camera. The same number `SpacesimExposure` uses, so the sky
## and the exposure cannot drift apart.
const REFERENCE_LUX := 100_000.0

## --- the sky's own light on the ground -----------------------------------------------------------------
##
## **The other half of the air.** The shell draws the scattered light for the *eye*; these constants are
## how much of it arrives at the *ground*, which is a different integral and a different problem.
##
## First order, and named as such: the light the air removes from the beam is the light it has to give
## back, `DOWN_FRACTION` of an isotropically scattered beam goes down, and `DIFFUSE_MAX` is the ceiling
## where single scattering stops being the answer. **The ceiling is a limit, not a fit** — without it the
## form runs away at grazing sun angles, where the beam is fully removed but most of what was removed
## came off a path nowhere near the ground.
const SKY_DOWN_FRACTION := 0.5
const SKY_DIFFUSE_MAX := 0.12
## The sun's cosine below which the path is taken as grazing rather than infinite.
const SKY_MIN_COS_ZENITH := 0.05
## How softly the air's own horizon shades out, in cosine. **This is the twilight term.** The ground goes
## dark when the sun crosses ITS horizon; the air above it stays lit until the sun drops below the
## *shell's* horizon, which is `sqrt(1 - (R / (R + h))^2)` lower — about 10 degrees for Earth. That gap is
## the whole reason a term like this has to be evaluated at the top of the air and not at the ground.
const SKY_SHADOW_SOFTNESS := 0.1

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
	# **No clamp at zero height.** A convective troposphere continues *below* the reference level — a gas
	# giant has no surface, and the 1-bar level is a reporting convention rather than the bottom of the
	# air. Clamping here is what made every deck below 1 bar inexpressible: Jupiter's water cloud is at
	# 15-20 bar and could never be found because the profile refused to go under its own datum.
	return maxf(surface_temperature - lapse * height, tropopause_temperature)


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


## The mix's **absorption** coefficient, 1/m. The exact mirror of `rayleigh_coefficient`, and zero
## everywhere until the material table carries visible absorption cross-sections — which is a **named
## gap**, not a value of zero (see `SpacesimSpecies.absorption`).
##
## **Absorption uses the scattering species' scale height**, i.e. it is treated as well mixed with the
## air. That is right for methane in Titan's atmosphere and **wrong for ozone**, which sits in a layer
## around 25 km rather than following the air's exponential. The error is a thinner ozone column at
## low sun than a well-mixed ozone would give — named here rather than modelled.
static func absorption_coefficient(
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
		total += material.absorption * (float(atmosphere.species[key]) * density)
	return total


## **The single-scattering albedo**, per channel: how much of the light the air removes it gives back as
## scattering rather than losing to absorption.
##
## It is the one number that decides whether a thick air behaves like a mirror or a filter, and it is
## what the two-stream limit is built on (`k = sqrt(3(1-w)(1-wg))`, which is zero when `w` is one).
## **Exactly 1 when the table carries no absorption**, which is where this starts — conservative
## scattering is the assumption until a measurement says otherwise.
static func single_scatter_albedo(
	atmosphere: SpacesimAtmosphere, materials: SpacesimMaterialTable, temperature: float
) -> Vector3:
	var scattering := rayleigh_coefficient(atmosphere, materials, temperature)
	var absorption := absorption_coefficient(atmosphere, materials, temperature)
	var mie := Vector3.ONE * MIE_COEFFICIENT
	var extinction := scattering + mie + absorption
	return Vector3(
		(scattering.x + mie.x) / maxf(extinction.x, 1.0e-30),
		(scattering.y + mie.y) / maxf(extinction.y, 1.0e-30),
		(scattering.z + mie.z) / maxf(extinction.z, 1.0e-30)
	)


## The pressure at a height, hydrostatic on a single exponential: `P(h) = P0 * exp(-h / H)`.
##
## **One scale height, taken at the surface, and it degrades past a scale height or two.** That is the
## whole of the approximation, and it is the reason the deck check is a *height* against the literature's
## altitude ranges: the sources publish a pressure level, so a height has to be converted to compare, and
## this conversion is only good while the level is within a couple of scale heights of the ground.
## Measured against the two cases that have both numbers: **Earth's cloud base comes to 0.84 bar against
## a real cumulus base near 0.9**, where the level is 0.18 of a scale height up — but **Venus's comes to
## 3.5 bar where the real deck sits near 0.7–1**, because that level is 3.3 scale heights up and one
## exponential cannot span that (the real pressure falls by a factor of 92 over 50 km, an effective
## scale height of ~11 km against the surface's 15.9).
static func pressure_at(height: float, surface_pressure: float, air_scale_height: float) -> float:
	if air_scale_height <= 0.0 or surface_pressure <= 0.0:
		return 0.0
	return surface_pressure * exp(-height / air_scale_height)


## One species' condensation level — **where a cloud deck sits, derived rather than authored.**
##
## The parameter is the height at which the species reaches its own `condensation_temperature` in the
## `T(h)` profile. Every species already carries that number: it is the same one the greenhouse
## calibration is fixed against, so nothing new is authored here.
##
## **Three regimes, and two of them are not "no deck".**
##
## | | |
## |---|---|
## | `LEVEL` | the profile crosses the condensation temperature above the ground: there is a height, and a deck could sit on it |
## | `DEEP` | it **does** condense, but below the depth this model represents — a real deck rather than a haze, and Jupiter's water cloud is one |
## | `NONE` | the troposphere never gets cold enough: the condensate is confined to the tropopause or above, and there is no tropospheric deck at all |
class Condensation:
	extends RefCounted

	enum Regime {
		LEVEL, ## a height where the species reaches its condensation temperature
		DEEP, ## it condenses, but **below the depth this model represents** — see `MODELLED_PRESSURE_MULTIPLE`
		NONE, ## never cold enough in the modelled column
	}

	var species := ""
	var regime := Regime.NONE
	## **How it came to exist**, which is not decoration: the engine can only find the first kind by
	## crossing a temperature, and a caller that treats them alike will place a photochemical deck at
	## whichever altitude happens to be cold enough.
	enum Formation {
		CONDENSATION, ## a gas in the mix, where `T(h)` crosses its own `T_cond` — the ordinary case
		REACTION, ## not in the mix: a product of two gases that meet at that level (NH\u2084SH)
	}
	var formation := Formation.CONDENSATION
	## Metres above the surface. Only meaningful for `LEVEL`.
	var height := 0.0
	## Pascals, from `pressure_at` — **an approximation that degrades with height**, see there.
	var pressure := 0.0
	## **How deep the deck is, in metres — the top is `height + thickness`.** Only meaningful for
	## `LEVEL`, and zero where the regime is not one, which is this module's convention for *not stated*.
	##
	## The **condensate scale height**: the height over which the saturation mixing ratio falls by e, from
	## Clausius-Clapeyron along the body's own lapse —
	##
	##     d(ln e_s)/dh = −L Γ / (R T²)   ⇒   H_w = (R / L) · T_base² / Γ
	##
	## capped by the tropopause, because a cloud cannot rise past it. `R` and `L` are both **molar**
	## (`latent_heat` is J/mol), which is what makes `R/L` a reciprocal temperature and `H_w` metres.
	##
	## Measured against the real decks: **Earth comes out 1,604 m** against cumulus bases 1–2 km and tops
	## 2–3 km, on the conservative side because `Γ` is the *dry* adiabat (9.78 K/km against a real 6.5);
	## **Jupiter 3,969 m** against an ammonia deck several times that, because a convective deck is organised
	## and `H_w` is a condensation scale; and **Venus 160 m against a real 20 km deck** — photochemical
	## H₂SO₄ and not the CO₂ this model condenses, the same cause as its base being right for the wrong
	## molecule, made worse here because that base sits against the tropopause so the **cap** binds rather
	## than the scale. All three measured 2026-10-20 by `tests/test_clouds.gd`.
	var thickness := 0.0


## Every condensation level in a body's air, **highest first** — so the first `LEVEL` is the deck seen
## from outside.
##
## Inputs are the two a caller already has or can already derive: the surface gravity and the equilibrium
## temperature. Everything else — the surface temperature, the lapse rate, the tropopause, the scale
## height — is this module's own and is computed here, so a caller cannot get one of them inconsistent
## with the other three.
##
## **`equilibrium` must be `equilibrium_temperature()`, never `reference_temperature()`.** The latter
## returns what content *pinned* as a mean surface temperature, and the tropopause is the skin temperature
## of the **equilibrium** one — so passing the pinned surface here takes `tropopause_temperature` to
## 0.8409 of a 737 K Venus, a 620 K ceiling, and **`NONE` for every species on the planet**: Venus's deck
## disappears entirely (measured 2026-10-20, while adding `thickness`). The two functions are one letter
## apart in name and 518 K apart in meaning.
static func condensation_levels(
	atmosphere: SpacesimAtmosphere,
	materials: SpacesimMaterialTable,
	gravity: float,
	equilibrium: float,
	body: SpacesimSystemBody = null
) -> Array:
	var levels: Array = []
	if atmosphere == null or materials == null:
		return levels
	var lapse := lapse_rate(atmosphere, materials, gravity)
	if lapse <= 0.0:
		return levels
	var surface := surface_temperature(atmosphere, materials, gravity, equilibrium)
	# **A PINNED surface temperature is the surface**, and ignoring it was the bug that hid the giants'
	# decks: `systems/sol.tres` has carried `mean_surface_temperature` for all four since they were
	# authored, and `reference_temperature` honoured it while this function — the one that actually places
	# a deck — called `surface_temperature` directly. Jupiter derived 119 K against its pinned 165 K, and
	# ammonia can never condense under that.
	if body != null and body.overrides != null and body.overrides.set.has("mean_surface_temperature"):
		surface = body.overrides.mean_surface_temperature
	var ceiling := tropopause_temperature(equilibrium)
	var air_height := scale_height(atmosphere, materials, surface, gravity)
	for key in atmosphere.species:
		var material := materials.by_name(String(key))
		if material == null or material.condensation_temperature <= 0.0:
			continue
		levels.append(_level_for(
			material, Condensation.Formation.CONDENSATION, surface, ceiling, lapse, atmosphere, air_height,
			materials
		))
	# **A species that forms IN SITU is looked for in the TABLE, not in the mix** — see
	# `SpacesimSpecies.formed_from`. It exists only where every one of its reactants is present, and a
	# species that is both an input and a product is skipped here because the loop above already made its
	# level.
	for material in materials.species:
		if material == null or material.condensation_temperature <= 0.0:
			continue
		if material.formed_from.is_empty() or atmosphere.species.has(material.species_name):
			continue
		var all_present := true
		for reactant in material.formed_from:
			if not atmosphere.species.has(reactant):
				all_present = false
				break
		if not all_present:
			continue
		levels.append(_level_for(
			material, Condensation.Formation.REACTION, surface, ceiling, lapse, atmosphere, air_height,
			materials
		))
	levels.sort_custom(func(a: Condensation, b: Condensation) -> bool: return a.height > b.height)
	return levels


## **The condensation temperature at the PARTIAL pressure the species is actually at.**
##
## `condensation_temperature` is the 1-atm reference (see `SpacesimSpecies`), and a trace gas is not at
## 1 atm: ammonia is 0.26 % of Jupiter's air, so its **263 Pa** partial pressure condenses it at
## **159 K, not the table's 240 K**. That 80 K is the difference between Jupiter having an ammonia deck
## and having none — at the 1-atm value the gas is "below its condensation point everywhere", which for
## the substance that *makes* Jupiter's visible cloud is plainly wrong.
##
## Clausius-Clapeyron, `1/T = 1/T_ref - (R/L)*ln(p/p_ref)`. **A species with no `latent_heat` keeps the
## old behaviour** rather than being guessed at.
static func condensation_temperature_at(
	material: SpacesimSpecies, fraction: float, total_pressure: float
) -> float:
	var reference := material.condensation_temperature
	if reference <= 0.0 or material.latent_heat <= 0.0 or fraction <= 0.0 or total_pressure <= 0.0:
		return reference
	var partial := fraction * total_pressure
	if partial >= ATMOSPHERIC_PRESSURE:
		return reference
	return 1.0 / (
		1.0 / reference
			- (GAS_CONSTANT / material.latent_heat) * log(partial / ATMOSPHERIC_PRESSURE)
	)


## **How far below the reference level the model represents the troposphere**, as a multiple of the
## reference pressure. **One stated calibration, and nothing per body** — which is deliberate: systems
## will be generated procedurally, so a depth that had to be authored per giant would be a depth that
## could be authored *impossible*. Twenty bar is where a gas giant's water cloud sits, and it is where
## the model stops claiming to know.
const MODELLED_PRESSURE_MULTIPLE := 20.0


## One `Condensation` record for a species against the profile it has to sit in.
##
## **Factored out because there are two ways to arrive here** — a gas in the mix, and a product of two of
## them — and the regime arithmetic is identical either way. Duplicating it would mean the two formation
## paths could disagree about where a level is.
static func _level_for(
	material: SpacesimSpecies,
	formation: int,
	surface: float,
	ceiling: float,
	lapse: float,
	atmosphere: SpacesimAtmosphere,
	air_height: float,
	materials: SpacesimMaterialTable
) -> Condensation:
	var level := Condensation.new()
	level.species = material.species_name
	level.formation = formation
	var fraction: float = atmosphere.species.get(material.species_name, 0.0)
	var freezing := condensation_temperature_at(material, fraction, atmosphere.surface_pressure)
	if freezing <= ceiling:
		level.regime = Condensation.Regime.NONE
	else:
		# **The same arithmetic whether the level is above or below the reference**, and that unification is
		# the point: `(surface - freezing)/lapse` is positive for a deck overhead and negative for one
		# underneath, and both are real. A negative height is not a fog — it is a deck deeper than the
		# datum, which is every giant's water cloud.
		level.height = (surface - freezing) / lapse
		level.pressure = pressure_at(level.height, atmosphere.surface_pressure, air_height)
		var deepest := -air_height * log(MODELLED_PRESSURE_MULTIPLE)
		level.regime = Condensation.Regime.LEVEL if level.height >= deepest else Condensation.Regime.DEEP
		if level.regime == Condensation.Regime.LEVEL:
			# **The condensate scale height, capped by the tropopause.** The second term is the same
			# arithmetic as `height` with the ceiling in place of the base temperature, so the two cannot
			# use different profiles — and it is asked for only where the base is above the ground, since a
			# `DEEP` deck's top is not a thing this model has a height for.
			#
			# **A species with no `latent_heat` gets no thickness**, which is the same reading the table gives
			# a zero everywhere else: *not stated*. Without the guard the division would be infinite and the
			# tropopause cap would quietly become the answer.
			#
			# `ponytail:` the table states ONE latent heat per species and does not always say which phase it
			# is, so a base below `melting_temperature` is still computed with the vapour's number. The ice
			# entries cannot be reached by name — `water_vapour`'s sibling is `water_ice`, not
			# `water_vapour_ice`, so a suffix rule would be a guess — and the error is small: Earth's deck is
			# **1.6 km with the vapour's coefficient against 1.3 with the ice's**, both inside the observed
			# range. Upgrade path: a `latent_fusion` per species, which is a measurement to collect.
			if material.latent_heat > 0.0 and lapse > 0.0:
				level.thickness = maxf(minf(
					(GAS_CONSTANT / material.latent_heat) * freezing * freezing / lapse,
					(surface - ceiling) / lapse - level.height
				), 0.0)
	return level



## **The air's own reflection** — the term the albedo derivation was missing, and it is DERIVED rather
## than collected: every number it needs is already in this module.
##
## A clear sky is not transparent. Earth's clear-sky planetary albedo is **0.149** against an all-sky
## **0.293** (Stephens et al. 2015, *Reviews of Geophysics*, from CERES EAFB global annual means), and
## the difference between those two is the cloud contribution — **0.144**. So the 0.149 is the surface
## *plus the air above it*, and a model that counts only the surface is short by most of it.
##
## **The derivation, and what it assumes.** Rayleigh and Mie scattering remove light from the beam; the
## part that goes back out of the top is the fraction single-scattered **upward**. For a Rayleigh phase
## function the up/down split is symmetric, so **half** of what is scattered once leaves upward — and a
## scattering optical depth of `tau` therefore reflects `0.5 * omega * (1 - exp(-tau))`, where `omega` is
## the single-scattering albedo that separates what is *scattered* from what is *absorbed*.
##
## **There is NO temperature argument, and that is a result rather than a simplification.** The optical
## depth is `k(1/m) * H(m)` = `[sigma * p / (k T)] * [k T / (m-bar g)]` = `sigma * p / (m-bar g)` — the
## temperature cancels exactly, as does the number density, because a hot atmosphere is both thinner and
## taller. `omega` cancels it the same way, both its terms being proportional to the number density. So
## the air's reflection depends only on **what it is made of, how much of it there is, and how hard the
## body pulls** — which is also what stops this from being circular, since `bond_albedo()` is what the
## equilibrium temperature is computed *from*. A parameter that cannot depend on the temperature cannot
## depend on itself through it. `tests/test_surface.gd` asserts the independence rather than trusting it.
##
## **The Mie share is deliberately NOT counted, and that is a finding rather than a simplification.**
## `MIE_COEFFICIENT` is 21e-6 per metre — a *volume* coefficient authored for Earth's air, used by the sky
## shader as one number for every body because aerosols are a named gap in the material table. Adding it
## here gave tiny Triton, whose air is 1.4 Pa of nitrogen, an aerosol optical depth of **0.30** — an
## Earth-like haze over a near-vacuum — and that pushed its clear-sky albedo past 1.0, at which point
## `equilibrium_temperature` takes the fourth root of a negative number and every temperature on the body
## becomes NaN. The suite caught it, which is the only reason it is not in the file.
##
## So a body's air reflects what its **own** gases scatter, scaled by its own pressure and gravity, and
## counts no aerosol at all. A per-body aerosol column is a collection item; an Earth haze on Neptune is
## not an approximation of one.
##
## Returned **per channel**, like the coefficient it is built from: a Rayleigh atmosphere reflects blue
## several times more than red, which is the same fact that makes the sky blue.
static func clear_sky_albedo(
	atmosphere: SpacesimAtmosphere,
	materials: SpacesimMaterialTable,
	gravity: float
) -> Vector3:
	if atmosphere == null or materials == null or gravity <= 0.0:
		return Vector3.ZERO
	# One number is a stand-in for "any temperature", because the result does not have it. Named rather
	# than passed, so that a caller cannot think it matters.
	var air_height := scale_height(atmosphere, materials, REFERENCE_TEMPERATURE, gravity)
	if air_height <= 0.0:
		return Vector3.ZERO
	# Scattering only, and only the gases the mix actually has.
	var depth := rayleigh_coefficient(atmosphere, materials, REFERENCE_TEMPERATURE) * air_height
	var omega := single_scatter_albedo(atmosphere, materials, REFERENCE_TEMPERATURE)
	return 0.5 * omega * Vector3(
		1.0 - exp(-depth.x), 1.0 - exp(-depth.y), 1.0 - exp(-depth.z)
	)


## The same number as one scalar over the three channels.
##
## **Weighted equally unless a caller says otherwise, and that is a stated simplification rather than a
## claim.** This is an *energy* question, so weighting by luminance would be wrong — that is the eye's
## response and not the star's output — and the right weights are Planck's function at the star's
## effective temperature across these three wavelengths. Equal weights are within about a sixth of that
## for a solar-type star, and the sensitivity is printed by the suite rather than left implicit.
static func clear_sky_scalar(
	atmosphere: SpacesimAtmosphere,
	materials: SpacesimMaterialTable,
	gravity: float,
	weights: Vector3 = Vector3(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0)
) -> float:
	var per_channel := clear_sky_albedo(atmosphere, materials, gravity)
	return per_channel.x * weights.x + per_channel.y * weights.y + per_channel.z * weights.z


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
	# **A body's own heat is a second source, and for a giant it is not a correction.** It adds to the
	# same flux, so it goes in before the fourth root — and because that root compresses, 5.44 W/m2 of
	# internal heat against 6.25 of sunlight only moves Jupiter from 102 K to 120 K. **The remaining 45 K
	# to its measured 165 K at 1 bar is NOT this term**: it is H2/He collision-induced absorption, which is
	# a greenhouse coefficient this table does not carry. Two gaps, named separately so neither can be
	# mistaken for the other's fix.
	absorbed += maxf(body.internal_heat_flux, 0.0)
	return pow(absorbed / STEFAN_BOLTZMANN, 0.25)


## How much of the mix actually scatters: the mole fractions with a Rayleigh cross-section, over all
## of them.
##
## **A named gap, not a silent one.** A species whose cross-section is not in the material table
## contributes nothing to the sky, so this is what says whether the air is complete. **Water vapour
## is the only remaining gap** — 1% of Earth's air — after hydrogen's cross-section was added for the
## gas giants (computed from a literature (n−1) and checked against helium first). `test_render.gd`
## asserts that Earth is the only body short of one.
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
