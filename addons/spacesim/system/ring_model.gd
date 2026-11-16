class_name SpacesimRingModel
extends RefCounted
## **What a ring is worth** — its radiance, its shadow, and the camera's two angles. No geometry, no nodes,
## no drawing: every number here is a function of the band's optical depth and the two directions that
## matter, which is why it can be checked against Saturn on paper.
##
## ## The sheet's surface brightness
##
## A ring is a slab of optical depth `tau`, lit by the star at cosine `mu0` above the plane and seen at
## cosine `mu`. Single scattering out of that slab gives the classic relation
##
##     I/F = (w/4) · mu0/(mu0 + mu) · (1 - exp(-tau · (1/mu0 + 1/mu)))
##
## and the engine wants radiance in the same currency as a body's, `illuminance · albedo · factor / pi`.
## So [method reflectance] returns the **shape** of that law, normalised so a bright Lambert surface at
## `mu0 = mu = 1` is `1`, and [method radiance] multiplies it by the star and by the material.
##
## **It has the behaviour the picture needs for free**, which is why it is a law rather than a scale
## factor: near-linear in `tau` when the band is thin, saturating when it is thick, brighter as the eye
## goes to grazing incidence, and dimmer when the star grazes as well. The three band values Saturn is
## known by fall out of it — C at 9 %, A at 41 %, B at 55 % of a bright surface — and a test asserts those
## against the content, so the numbers cannot drift into looking nice.
##
## ## What it deliberately does not model
##
## The **opposition surge**, the **forward-scattering peak** at high phase, and the fact that a thick ring's
## brightness is not a single-scattering quantity at all. Those need a phase function with measured
## parameters (Henyey-Greenstein `g`, a `w` per band) and the game has no phase-angle sampling to judge them
## by yet. Named here so that nobody reads the current law as more than it is.

## **The lowest cosine either direction is allowed to take.** `1/mu` diverges at grazing incidence and a
## ring seen exactly edge-on is a pixel wide — so the floor is a statement about what the model claims,
## not a numerical guard: below about one degree the answer would be a guess anyway.
const MIN_COSINE := 0.02

## **How bright a shadowed particle still is**, as a fraction of the band's own radiance.
##
## The project has no ambient model — the ambient is a constant, and nothing here invents one. This is
## the **floor** that keeps `R33` true: a rock in the planet's shadow is *dark*, not *absent*. Without it
## a shadowed particle has zero radiance, and a `blend_mix` splat of zero radiance over a lit planet is a
## black speck at best and nothing at worst. Evert, 2026-11-16: *"I don't want the rocks in the shadow of
## the planet disappearing, they should just not be lit from the sun."*
const UNLIT := 0.04


## The cosine of a direction above the ring plane, floored — see [constant MIN_COSINE].
##
## **The absolute value, because a ring is a sheet and not a surface**: light comes from whichever side it
## comes from, and a slab lit from below is lit exactly as well as one lit from above.
static func cosine(plane_normal: Vector3, direction: Vector3) -> float:
	var normal := plane_normal.normalized()
	var length := direction.length()
	if length <= 0.0:
		return MIN_COSINE
	return maxf(absf(normal.dot(direction / length)), MIN_COSINE)


## **The slab's reflectance**, as a fraction of a bright Lambert surface — the band's brightness, and the
## one number the picture is judged by.
##
##     R = (tau / (1 + tau)) · 2 · mu0 / (mu0 + mu)
##
## The first factor is the **two-stream (diffuse) reflectance** of a slab, which is what a band of
## scatterers at optical depth `tau` returns, and it is where the three Saturn values come from: C `0.1`
## gives 9 %, A `0.7` gives 41 %, B `1.2` gives 55 %.
##
## The second factor is **the geometry of a slab**, normalised to 1 when the star is overhead and the eye is
## overhead, which is where the band is at its stated brightness. It does two things a constant cannot:
## a ring **brightens towards grazing incidence** (the eye looking along the sheet sees more of it), and it
## dims when the star grazes. Both are real, and both are what make a ring's brightness change as the
## season does.
##
## **Clamped at 1** because nothing reflects more than a bright surface: with a thick band seen edge-on the
## product exceeds it, and an unclamped reflectance is exactly how a ring ends up brighter than the planet
## it orbits. Evert, 2026-11-15: *"the little splats are way too bright, far brighter than Saturn itself."*
##
## **What this is not.** Single scattering out of the slab — `(w/4)·mu0/(mu0+mu)·(1-exp(-tau(1/mu0+1/mu)))`
## — is the sharper law, and it is a factor of a few dimmer at low phase because it has no opposition surge.
## The diffuse form is used because it is the one the engine's own lighting language speaks, it agrees with
## the band values the project already quotes, and the surge needs measured phase parameters this game has
## no way to judge yet. `SpacesimRingModel`'s class comment carries the same note.
static func reflectance(tau: float, sun_cosine: float, eye_cosine: float) -> float:
	var mu0 := maxf(sun_cosine, MIN_COSINE)
	var mu := maxf(eye_cosine, MIN_COSINE)
	if tau <= 0.0:
		return 0.0
	var diffuse := tau / (1.0 + tau)
	var geometry := 2.0 * mu0 / (mu0 + mu)
	return clampf(diffuse * geometry, 0.0, 1.0)


## **The band's own radiance**, in the engine's units: the light falling on it, the fraction of it the
## material reflects, and the slab's brightness. `bond_albedo` comes from what the particles are made of —
## the same derivation a moon's colour uses, so a ring of ice is brighter than a ring of rock without a
## second palette.
static func radiance(
	illuminance: float, bond_albedo: float, tau: float, sun_cosine: float, eye_cosine: float
) -> float:
	if illuminance <= 0.0 or bond_albedo <= 0.0:
		return 0.0
	return illuminance * bond_albedo * reflectance(tau, sun_cosine, eye_cosine) / PI


## **The radiance of a particle the star cannot reach**: the same material with only the unlit floor under
## it. Never zero — see [constant UNLIT].
static func unlit_radiance(radiance_lit: float) -> float:
	return radiance_lit * UNLIT


## **How much light gets through the sheet**, `exp(-tau/mu)` — the fraction of what is behind it that
## survives. The complement, `1 - T`, is how much of the frame the sheet takes over, which is the alpha the
## splat blend needs.
static func transmittance(tau: float, eye_cosine: float) -> float:
	if tau <= 0.0:
		return 1.0
	return exp(-tau / maxf(eye_cosine, MIN_COSINE))


## **The size distribution, inverted.** `N(>D)` proportional to `D^-index` is a collisional cascade's own
## law — Dohnanyi's 2.5 in the strength regime — so drawing a uniform `u` and returning `floor·u^(-1/index)`
## gives a diameter with the distribution the band is said to have. Clamped at both ends, because the power
## law is only valid below about 100 km and because a band needs an end somewhere.
static func diameter(draw: float, floor_size: float, ceiling: float, index: float) -> float:
	if index <= 0.0 or floor_size <= 0.0:
		return floor_size
	var diameter := floor_size * pow(maxf(draw, 1.0e-9), -1.0 / index)
	return minf(diameter, ceiling)


## **How many objects exist at or above `size_floor`**, from an authored count at a reference size —
## `count · (floor/reference)^-index`. This is the number that makes a band's density real rather than a
## rendering decision.
static func addressable(population: SpacesimPopulation) -> float:
	if population == null or population.reference_size <= 0.0 or population.size_floor <= 0.0:
		return 0.0
	return float(population.count) * pow(
		population.size_floor / population.reference_size, -population.size_index
	)


## The band's area in the plane, `pi (r_out² - r_in²)`.
static func area(population: SpacesimPopulation) -> float:
	if population == null:
		return 0.0
	var inner := population.semi_major_axis.x
	var outer := population.semi_major_axis.y
	if inner <= 0.0 or outer <= inner:
		return 0.0
	return PI * (outer * outer - inner * inner)
