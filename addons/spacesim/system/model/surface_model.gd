class_name SpacesimSurfaceModel
extends RefCounted
## What a body's surface reflects — the albedo the temperature derivation needs and the colour the
## renderer draws.
##
## The surface contribution is an **area-weighted** blend of the materials over the authored coverage
## fractions. The cloud deck is blended over the top by its own fraction, which is why this cannot be
## computed from `surface` alone: **clouds dominate a planet's reflection.**
##
## A linear area mix is an approximation of a radiative-transfer problem — real clouds absorb and
## multiple-scatter — but it lands on the measured values when the numbers are real, and the test
## checks exactly that against the Moon, Earth and Venus.

## What a body with nothing to derive from is drawn in. Deliberately unlovely, so a placeholder is
## never mistaken for a result.
const UNPINNED_COLOR := Color(0.62, 0.62, 0.66)


## **The air's own reflection**, as a fraction of the star's light — the term this model was missing.
##
## Zero for an airless body, which is a value and not a missing one. The per-channel physics is
## `SpacesimAtmosphereModel.clear_sky_albedo`, which needs no temperature: the optical depth is
## `[sigma p / kT] * [kT / m-bar g]` and the temperature cancels.
static func air_albedo(body: SpacesimSystemBody, materials: SpacesimMaterialTable) -> float:
	if body == null or body.atmosphere == null or materials == null:
		return 0.0
	return SpacesimAtmosphereModel.clear_sky_scalar(
		body.atmosphere, materials, SpacesimAtmosphereModel.surface_gravity(body)
	)


## **The clear-sky albedo**: what this body would reflect with no clouds anywhere.
##
## The surface *everywhere* plus the air above it — a property of the planet rather than of the cloud-free
## part of it, which is what makes the net accounting below work: a whole planet's worth of it is what
## sits under a gap.
static func clear_sky_albedo(body: SpacesimSystemBody, materials: SpacesimMaterialTable) -> float:
	return surface_albedo(body, materials) + air_albedo(body, materials)


## Bond albedo: the fraction of the star's light the body reflects.
##
## **NET, as of 2026-10-16** — the accounting the published measurements are in:
##
##     A = (1 - f) * A_clear + f * A_cloud
##     A_clear = surface_albedo + air_albedo           (the whole planet, cloudless)
##
## **This replaced a GROSS area mix** — `f * cloud + (1 - f) * surface` — which gave the surface under a
## cloud no credit at all. The two are both valid and they are not the same numbers: gross makes the
## cloud albedo the deck's own reflectance (0.45 is right there), while net makes it the reflectance of
## the cloud *system* seen from outside, which the clear column it hides must be subtracted from
## (0.38). Calibrating the total never distinguished them, which is how the model came to have its cloud
## term 1.9x the published one and its clear term a fifth, cancelling to the right answer.
##
## **The net one is the honest one because the published split is in it.** Earth's all-sky albedo is
## 0.293 and its clear-sky albedo 0.149 (Stephens et al. 2015, from CERES EAFB), so the cloud's share is
## the difference, 0.144 — a *net* figure, since it is measured against what the clear column would have
## reflected. Against that:
##
##     published   cloud 0.144   clear 0.149   total 0.293
##     net model   (1-f) * clear + f * deck, with the air counted
##
## **What is still not counted, named:** the air *above* a cloud, because the deck's reflectance is taken
## as the whole system's. That is the next order of business and it is small on Earth.
static func bond_albedo(
	body: SpacesimSystemBody, materials: SpacesimMaterialTable
) -> float:
	# **The stack composites from the bottom up**, so each layer hides some of what is beneath it and the
	# topmost is applied last. With one layer this reduces exactly to
	# `cover * albedo + (1 - cover) * clear` — the formula the Earth calibration is fixed against — which
	# is why every body authored before the stack existed is unchanged by it.
	var result := clear_sky_albedo(body, materials)
	if body.clouds == null:
		return result
	for index in range(body.clouds.layer_count() - 1, -1, -1):
		var cover := clampf(body.clouds.coverage_at(index), 0.0, 1.0)
		result = cover * body.clouds.albedo_at(index) + (1.0 - cover) * result
	return result


## **The split of a body's reflection**, as its parts — because the total can be right while the parts
## are not, and that is exactly what the published numbers caught on 2026-10-16.
##
## The terms are the **net** ones, matching `bond_albedo()`: the clear column weighted by the cloud-free
## fraction, and the deck by the covered one. Earth's published split is cloud 0.144 against a clear
## 0.149 (Stephens et al. 2015, CERES EAFB), and before the air was counted at all this model's was
## cloud 0.270 against a clear 0.032 — the total right and both halves wrong, which is why calibrating
## against the total never caught it.
static func reflectance_terms(
	body: SpacesimSystemBody, materials: SpacesimMaterialTable
) -> Dictionary:
	var ground := surface_albedo(body, materials)
	var air := air_albedo(body, materials)
	var clear := ground + air
	var total := bond_albedo(body, materials)
	# **The cloud-free fraction is the PRODUCT of every layer's gaps**, not the top layer's — a disc is
	# only cloud-free where no deck covers it, and each deck independently leaves its own gaps open.
	var uncovered := 1.0
	var top := 0.0
	var top_albedo := 0.0
	if body.clouds != null:
		var count := body.clouds.layer_count()
		for index in count:
			uncovered *= 1.0 - clampf(body.clouds.coverage_at(index), 0.0, 1.0)
		if count > 0:
			top = clampf(body.clouds.coverage_at(0), 0.0, 1.0)
			top_albedo = body.clouds.albedo_at(0)
	return {
		"cloud": total - uncovered * clear,
		"surface": uncovered * ground,
		"air": uncovered * air,
		"total": total,
		"cloud_fraction": 1.0 - uncovered,
		"cloud_albedo": top_albedo,
		"surface_albedo": ground,
		"air_albedo": air,
		"top_fraction": top,
	}


## The **Lambert phase function**: the disc-averaged radiance of a lit sphere relative to a fully-lit
## one, as a function of the phase angle.
##
##     f(a) = (sin a + (pi - a) * cos a) / pi
##
## 1 at full, **1/pi at half**, 0 only at new, and smooth across the half moon. That smoothness is the
## point. `view_luminance_at` used `cos(a)` clamped at zero, which is not a worse approximation but a
## different statement: **it deletes every body past the half moon.** At 122 degrees — near the
## terminator, a crescent — the dot product is -0.53, so the body was dropped from the sum entirely,
## the exposure rested at the dark-adapted ceiling with that body filling the frame, and the lit part
## blew out. The true disc average there is 0.098, and it is never zero until the body is exactly new.
##
## It is better on the gibbous side too, where the disc average includes the bright limb: at 60
## degrees it is 0.609 against a cosine of 0.5.
##
## **Bond and geometric albedo are different quantities related through the phase integral** (which is
## 3/2 for this function). This codebase uses **Bond** throughout, so this normalises the disc average
## and no geometric albedo has to be reconciled with it. The function itself is a model — exact for a
## perfectly diffuse sphere. Airless rock backscatters harder, so Lambert makes its crescents slightly
## too bright, and a cloudy body scatters forward, so Venus is brighter as a crescent than this says.
static func lambert_phase(phase_angle: float) -> float:
	var a := clampf(phase_angle, 0.0, PI)
	return (sin(a) + (PI - a) * cos(a)) / PI


## The surface alone, with no cloud over it. An airless body's whole answer.
static func surface_albedo(body: SpacesimSystemBody, materials: SpacesimMaterialTable) -> float:
	if body.surface == null:
		return 0.0
	var total := 0.0
	var weight := 0.0
	for key in body.surface.coverage:
		var material := _material(materials, key)
		if material == null:
			continue
		var fraction := float(body.surface.coverage[key])
		total += fraction * material.albedo
		weight += fraction
	return total / weight if weight > 0.0 else 0.0


## The colour to draw the **bare surface** in — the material blend, with **no cloud over it**.
##
## The deck is a separate drawn layer, so blending it in here double-counts it, and that is exactly
## what washed Earth's blue into grey: 0.6 of white over a blue surface lands at a colour only 1.15:1
## from neutral, which the eye reads as grey. Physics and picture want different things from the same
## data — `bond_albedo` includes the deck because the temperature depends on it; the drawn surface
## does not, because the deck is drawn on top of it.
static func color(body: SpacesimSystemBody, materials: SpacesimMaterialTable) -> Color:
	if body.surface == null:
		# Nothing to see *but* the deck: a gas giant has no surface coverage, so its cloud colour is
		# the only honest thing to draw it in.
		if body.clouds != null:
			return body.clouds.color
		return UNPINNED_COLOR
	return _surface_color(body, materials)


static func cloud_fraction(body: SpacesimSystemBody) -> float:
	if body.clouds == null:
		return 0.0
	return clampf(body.clouds.fraction, 0.0, 1.0)


## The colour blend, in the space the materials are authored in — which is what Godot's
## `albedo_color` expects too, so the result is self-consistent. The Shaders project lost time to the
## opposite mistake (hand-picked sRGB values used as though they were linear), so this is deliberate
## rather than incidental.
static func _surface_color(body: SpacesimSystemBody, materials: SpacesimMaterialTable) -> Color:
	var total := Color(0.0, 0.0, 0.0)
	var weight := 0.0
	for key in body.surface.coverage:
		var material := _material(materials, key)
		if material == null:
			continue
		var fraction := float(body.surface.coverage[key])
		total += material.color * fraction
		weight += fraction
	if weight <= 0.0:
		return Color.BLACK
	return total / weight


## A material by name, or null when the table does not carry it — a missing species should leave a
## hole rather than a wrong answer.
static func _material(materials: SpacesimMaterialTable, species_name: Variant) -> SpacesimSpecies:
	if materials == null:
		return null
	return materials.by_name(String(species_name))
