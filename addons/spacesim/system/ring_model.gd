class_name SpacesimRingModel
extends RefCounted
## **What a band of small bodies is worth**, and **what it is not**.
##
## Two things live here and they are deliberately different:
##
## 1. **A rock's own surface brightness** — the same `disc_luminance` a body uses, so a ring's particles are
##    drawn as what they are. This is what the renderer uses today.
## 2. **A sheet's reflectance** — the slab's answer for an optical depth, which is the *dust's* law. It is
##    here, tested, and **not used by the rocks**, because the rocks are not the sheet.
##
## **The drawn particles are not the band's opacity, and this is the correction of 2026-11-16.** The 300,000
## particles that are drawn are the *largest embedded objects*, 100 m to 30 km; Evert's instruction when the
## band came out orders of magnitude too bright: *"We don't want these rocks to make up the entire
## reflectance, we'll add the dust layer later."*
##
## [method drawn_optical_depth] is the number that says it: those objects span `N·pi·<r²>/A`, which for the B
## ring is **2 x 10⁻⁷** — the whole drawn sample is a sixth of a millionth of the band's `tau = 1.2`. Treating
## it as the sheet made every particle carry the band's brightness, which is why the first two builds were
## far too bright. **The band's light is the dust's**, and until the dust layer exists there is no band, only
## a scatter of rocks.
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


## **The slab's reflectance** — **the dust layer's law, not the rocks'.** A drawn rock's radiance is its own
## surface brightness; this is what a *sheet* of optical depth `tau` returns, and it is here because the
## numbers Saturn is known by belong somewhere, and because the dust slice will call exactly this.
##
## As a fraction of the star's own flux — single scattering out of a sheet:
##
##     R = (1/4) · mu0/(mu0 + mu) · (1 - exp(-tau · (1/mu0 + 1/mu)))
##
## lit at cosine `mu0` and seen at cosine `mu`. It is the classic single-scattering answer and it has the
## behaviour the picture needs without a tuned constant: **near-linear in `tau` while the band is thin**,
## **saturating** once a ray has scattered, and **brighter at grazing incidence** (the eye looks along the
## sheet and sees more of it) while dimmer when the star grazes too.
##
## **It is deliberately dimmer than a Lambert surface.** Evert, 2026-11-16, flying the first build of this:
## *"The particles are way, way too bright."* That build used the two-stream diffuse reflectance,
## `tau/(1+tau)`, which is roughly what a thick scattering slab returns in total — and at `tau = 1.2` it is
## twice what one scattering delivers, so the band came out brighter than Saturn's own disc. Single scattering
## puts it where the physics of *one* bounce does: below a bright surface, and below the planet.
##
## **What it is missing is the reason real rings look bright.** The opposition surge — the sharp brightening
## within a few degrees of back-scatter — is worth a factor of two or more on Saturn's rings, and it needs a
## measured phase function and a game with a phase-angle dial to judge it. Naming it is why the number here is
## allowed to be low rather than tuned up to a picture.
static func reflectance(tau: float, sun_cosine: float, eye_cosine: float) -> float:
	var mu0 := maxf(sun_cosine, MIN_COSINE)
	var mu := maxf(eye_cosine, MIN_COSINE)
	if tau <= 0.0:
		return 0.0
	var slab := 0.25 * mu0 / (mu0 + mu) * (1.0 - exp(-tau * (1.0 / mu0 + 1.0 / mu)))
	return clampf(slab, 0.0, 1.0)


## **The sheet's radiance**, in the engine's units — the dust's, not the rocks'. `bond_albedo` comes from what
## the particles are made of: the same derivation a moon's colour uses, so a ring of ice is brighter than one
## of rock without a second palette.
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


## **How much of the band's opacity the DRAWN particles actually are** — `N·pi·<r²>/A`, with `r` the mean
## drawn radius and `A` the band's area.
##
## **It is the number that keeps this honest.** The drawn sample is the largest embedded objects, so its own
## optical depth is a fractional millionth of the band's: for Saturn's B ring, `2.0 x 10⁻⁷` against a `tau` of
## 1.2. The remaining 99.99998 % is the dust, which is not modelled yet, which is why the sky is not filled
## with a bright sheet and why the rocks must not be drawn as one.
static func drawn_optical_depth(population: SpacesimPopulation, mean_radius: float) -> float:
	var area := area(population)
	if area <= 0.0 or mean_radius <= 0.0:
		return 0.0
	return float(population.particle_count) * PI * mean_radius * mean_radius / area


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
