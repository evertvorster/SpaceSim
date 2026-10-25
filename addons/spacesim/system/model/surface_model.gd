class_name SpacesimSurfaceModel
extends RefCounted
## What a body's surface reflects — the albedo the temperature derivation needs and the colour the
## renderer draws.
##
## **The accounting is NET, and it replaced a gross one on 2026-10-16.** `bond_albedo` composites a
## `(1 - f) · clear + f · deck` stack from the bottom up, with the clear column a **derived quantity that
## includes the air's own reflection** — `clear_sky_albedo`, which is why this cannot be computed from
## `surface` alone. The gross area mix it replaced (`f · cloud + (1 - f) · surface`) gave the ground under a
## cloud no credit at all; both are valid arithmetic and they are not the same numbers, which is how the
## model came to have its cloud term 1.9× the published one and its clear term a fifth, cancelling to the
## right total. See `bond_albedo`'s own doc and [[SpaceSim/Solar Systems and the Physics Model]] §3.5.
##
## **Clouds dominate a planet's reflection**, which is why the decomposition is worth the trouble: Earth's
## published split is cloud 0.144 against a clear 0.149 (Stephens et al. 2015, CERES EAFB), and
## `reflectance_terms()` is the function that has to reproduce both halves rather than the sum.
##
## The stack is a linear mix, which is an approximation of a radiative-transfer problem — real clouds absorb
## and multiple-scatter — but it lands on the measured values when the numbers are real, and the test checks
## exactly that against the Moon, Earth and Venus.

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
## point. The earlier form was `cos(a)` clamped at zero, which is not a worse approximation but a
## different statement: **it deletes every body past the half moon.** At 122 degrees — near the
## terminator, a crescent — the dot product is -0.53, so the body was dropped from the sum entirely, and
## a crescent filling the frame contributed nothing. The true disc average there is 0.098, and it is
## never zero until the body is exactly new.
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


# ===== WHAT IS ON THE SURFACE, AND IN WHAT PHASE ===================================
#
# Everything above answers *how much light* a body reflects. This answers *what is there* — the question
# a renderer needs before it can draw anything: is this an ocean world, an ice world, or rock; where does
# the sea surface sit; which materials stack in which order up the slope; and above what height does the
# ground freeze. See vault `SpaceSim/Surface`.
#
# **All of it is derivation and none of it is authored.** The inputs are the composition content already
# carries, the material table's physical constants, and the temperature the atmosphere work already
# derives — nothing here invents a number, and the one place content is overruled is the *label*: a body
# authored `ocean` at 100 K is ice, because that is what water is at 100 K.

## A material's phase, at a temperature and a pressure.
##
## **`UNKNOWN` is a value, not a failure**: a substance the table has no melting point for cannot be placed
## in a phase without guessing, and a guess is worse than an absence — the same rule that keeps an
## unmeasured Rayleigh cross-section at zero.
enum Phase { UNKNOWN, SOLID, LIQUID, GAS }

## What a body's surface *is*, as one word — the verdict a renderer reads.
##
## **There is no `MOLTEN`.** It would need a solidus, and the table carries no melting point for silicate
## or iron, so the verdict would be unreachable code pretending to be a feature. Io is `ROCKY` and stays
## `ROCKY` until the table knows what rock melts at.
enum SurfaceKind { ROCKY, OCEAN, ICE, GAS_GIANT }


## **A material's phase at a temperature and a pressure.** The primitive the rest of this section is
## built on, and the only place the phase rules live.
##
## The three boundaries are the three the table now carries: below `melting_temperature` it is solid;
## above `condensation_temperature` — corrected to the pressure it is actually at — it is a gas; and
## **between them there is only a liquid if a liquid can exist here at all**, which is what the triple
## point decides. Below it a substance sublimes, which is why Mars has no liquid CO2 at 636 Pa however
## warm it gets.
##
## **The pressure passed in is the AMBIENT total pressure and the substance is taken as pure** — a sea, a
## glacier or a frost deposit is bulk material, not a trace gas, so its own vapour is at the whole of it.
## That is the opposite of `condensation_temperature_at`'s atmospheric use, where the partial pressure is
## what matters, and passing a mole fraction here would place every ocean far below its own boiling point.
static func phase_of(material: SpacesimSpecies, temperature: float, pressure: float) -> Phase:
	if material == null or material.melting_temperature <= 0.0 or temperature <= 0.0:
		return Phase.UNKNOWN
	if temperature < material.melting_temperature:
		return Phase.SOLID
	if pressure <= 0.0 \
			or (material.triple_point_pressure > 0.0 and pressure < material.triple_point_pressure):
		return Phase.GAS
	var boiling := SpacesimAtmosphereModel.condensation_temperature_at(material, 1.0, pressure)
	# **A table entry with no liquid range is not given one.** When the 1-atm reference sits at or below
	# the melting point, the honest reading is that this substance has no liquid phase there — the state
	# the model is in for a solid whose reference was its melting point — rather than a range inverted
	# from nothing.
	#
	# **The limit that costs us, named:** a substance whose 1-atm reference is a SUBLIMATION point never
	# gets a liquid, which is right at 1 atm and wrong above its own triple point. CO2 is the case: at
	# 300 K its saturation pressure is 6.7 MPa, so 10 MPa of it is a liquid, and this returns a gas. No
	# body in Sol is in that corner (Venus' 9.2 MPa is past the boiling point regardless), and the fix is
	# a Clausius-Clapeyron anchored at the triple point rather than at one atmosphere.
	if boiling <= material.melting_temperature:
		return Phase.GAS
	return Phase.LIQUID if temperature < boiling else Phase.GAS


## What a body's surface is. **The one word a renderer branches on**, so that a gas giant cannot be handed
## a sea level and an airless rock cannot be given an ocean's specular.
##
## The rules are the composition's own: a body with no `surface` register but a deck is a **gas giant**
## (its visible surface *is* the deck); a body with any liquid coverage is an **ocean** world; a body whose
## volatiles are all frozen is an **ice** world; everything else is **rock**.
static func surface_kind(
	body: SpacesimSystemBody, materials: SpacesimMaterialTable, luminosity: float, distance: float
) -> SurfaceKind:
	if body == null:
		return SurfaceKind.ROCKY
	if body.surface == null or body.surface.coverage.is_empty():
		return SurfaceKind.GAS_GIANT if body.clouds != null else SurfaceKind.ROCKY
	var thermal := _thermal(body, materials, luminosity, distance)
	var liquid := 0.0
	var frozen := 0.0
	for key in body.surface.coverage:
		var weight := float(body.surface.coverage[key])
		match phase_of(_material(materials, key), thermal.x, thermal.y):
			Phase.LIQUID:
				liquid += weight
			Phase.SOLID:
				frozen += weight
	if liquid > 0.0:
		return SurfaceKind.OCEAN
	if frozen > 0.0:
		return SurfaceKind.ICE
	return SurfaceKind.ROCKY


## **The volatile that has somewhere to sit**, and what phase it is in: the heaviest volatile material in
## the coverage, with the temperature and pressure that decided it.
##
## Empty for a body with no volatile coverage at all — Earth carries water as `ocean`, Ganymede as
## `water_ice`, Titan as `methane_ice`, and Io carries none. This is what the snow line reads its freezing
## point from, and later what places a sea's colour and its specular.
static func ocean_bearing(
	body: SpacesimSystemBody, materials: SpacesimMaterialTable, luminosity: float, distance: float
) -> Dictionary:
	if body == null or body.surface == null:
		return {}
	var thermal := _thermal(body, materials, luminosity, distance)
	var best: SpacesimSpecies = null
	var weight := 0.0
	for key in body.surface.coverage:
		var material := _material(materials, key)
		if material == null or material.melting_temperature <= 0.0:
			continue
		if float(body.surface.coverage[key]) <= weight:
			continue
		best = material
		weight = float(body.surface.coverage[key])
	if best == null:
		return {}
	return {
		"material": best.species_name,
		"fraction": weight,
		"phase": phase_of(best, thermal.x, thermal.y),
		"temperature": thermal.x,
		"pressure": thermal.y,
	}


## **Where the sea surface sits, as a percentile of the surface's height distribution** — so a renderer
## thresholds *its own* field at this number and the drawn ocean is the authored fraction of the area.
##
## The same relationship `SpacesimCloudMaps.threshold_for()` has with cloud coverage, and for the same
## reason: **"a fraction of the surface" has to mean the fraction**, so the number is measured against the
## field rather than chosen. Percentiles run from the bottom, so Earth's 0.708 of ocean puts sea level at
## the 70.8th — the area below it is the area that is under water.
static func sea_level_percentile(
	body: SpacesimSystemBody, materials: SpacesimMaterialTable, luminosity: float, distance: float
) -> float:
	if body == null or body.surface == null:
		return 0.0
	var thermal := _thermal(body, materials, luminosity, distance)
	var liquid := 0.0
	for key in body.surface.coverage:
		if phase_of(_material(materials, key), thermal.x, thermal.y) == Phase.LIQUID:
			liquid += float(body.surface.coverage[key])
	return clampf(liquid, 0.0, 1.0)


## **The surface as bands up the slope**, lowest first — each material's colour, reflectance and shading,
## with the span of the height distribution it occupies.
##
## Two things make this the whole of "how it will look":
##
##  - **The liquids come first, because a liquid fills the basins.** No threshold decides that; the phase
##    test does. Above them the solids take the rest of the distribution in the order content authored
##    them, which is why that order is a decision an author makes by writing the entries in an order —
##    Godot dictionaries keep it, and `.tres` text keeps it too.
##  - **The colour's luminance is set to the material's albedo**, keeping its hue. The authored palette is
##    2.3–3.4x brighter than the reflectance it claims (ocean `Color(0.05,0.15,0.35)` has a luminance of
##    0.143 against an albedo of 0.06), and a ramp built straight from it would draw a planet several
##    times too bright while every derivation still agreed with the published numbers.
##
## Each band is `{material, phase, from, to, color, albedo, roughness, specular}` — `from`/`to` in percentile
## space, so the renderer needs the field's own height values to place them, and gets them by measuring.
static func bands(
	body: SpacesimSystemBody, materials: SpacesimMaterialTable, luminosity: float, distance: float
) -> Array:
	var result: Array = []
	if body == null or body.surface == null or body.surface.coverage.is_empty():
		return result
	var thermal := _thermal(body, materials, luminosity, distance)
	var edge := 0.0
	# The basins first, in authored order among themselves.
	for key in body.surface.coverage:
		var material := _material(materials, key)
		if material == null or phase_of(material, thermal.x, thermal.y) != Phase.LIQUID:
			continue
		var weight := float(body.surface.coverage[key])
		result.append(_band(material, edge, edge + weight, phase_of(material, thermal.x, thermal.y)))
		edge += weight
	# Then the solids, sharing what is above the sea surface in proportion to their own weights — so a
	# body whose coverage sums to 1.0 does not have its land squeezed by the sea that covers part of it.
	var solid_total := 0.0
	for key in body.surface.coverage:
		if phase_of(_material(materials, key), thermal.x, thermal.y) != Phase.LIQUID:
			solid_total += float(body.surface.coverage[key])
	if solid_total > 0.0:
		var above := 1.0 - edge
		for key in body.surface.coverage:
			var material := _material(materials, key)
			if material == null or phase_of(material, thermal.x, thermal.y) == Phase.LIQUID:
				continue
			var share := float(body.surface.coverage[key]) / solid_total * above
			result.append(_band(material, edge, edge + share, phase_of(material, thermal.x, thermal.y)))
			edge += share
	return result


## **The height above which the ground is frozen**, in metres above the datum — the snow line, derived.
##
## The air already knows how fast it cools: `lapse_rate()` is `g/c_p`, and `temperature_at()` is that
## profile. So the height where the surface reaches the freezing point of its own volatile is arithmetic:
##
##     h = (T_surface - T_freeze) / lapse
##
## **It comes out LOW, and that is a value rather than a number to tune.** The lapse is the *dry* adiabat
## (Earth 9.78 K/km against an environmental ~6.5), which `SpacesimAtmosphereModel` already names as its
## limitation; Earth's line lands near 1.5 km against a real global mean of two to three. The fix belongs
## to the temperature model, not to a fudge here.
##
## Zero means no line: no air, no volatile on the surface, or a body already frozen everywhere — which is
## an `ICE` world and is what `surface_kind()` is for.
static func snow_line(
	body: SpacesimSystemBody, materials: SpacesimMaterialTable, luminosity: float, distance: float
) -> float:
	if body == null or body.atmosphere == null or body.surface == null:
		return 0.0
	var bearing := ocean_bearing(body, materials, luminosity, distance)
	if bearing.is_empty():
		return 0.0
	var material := _material(materials, bearing["material"])
	if material == null or material.melting_temperature <= 0.0:
		return 0.0
	var lapse := SpacesimAtmosphereModel.lapse_rate(
		body.atmosphere, materials, SpacesimAtmosphereModel.surface_gravity(body)
	)
	if lapse <= 0.0:
		return 0.0
	var excess := float(bearing["temperature"]) - material.melting_temperature
	return excess / lapse if excess > 0.0 else 0.0


## **The latitude beyond which the surface is frozen, in radians from the pole** — zero, for now, and
## deliberately.
##
## A polar cap is a *latitude*, and there is no horizontal temperature anywhere in the engine: the profile
## is `T(h)`, and the cloud model's bands are a circulation scale with no temperature attached. What would
## fill this is the latitudinal energy balance — a Budyko/Sellers one-dimensional model, whose insolation
## and albedo the engine already derives and whose transport coefficient is the one calibrated number.
## See vault `SpaceSim/Surface` §4.
##
## **The seam exists now so that the shader never has to be re-plumbed for it**: a renderer asks this
## question, gets "no cap", and draws none. An `ICE` world does not need it — it is frozen everywhere,
## which `surface_kind()` already says.
static func polar_ice_line(_body: SpacesimSystemBody) -> float:
	return 0.0


## The temperature and pressure a body's surface is at — **one helper, so the phase tests cannot be handed
## two different temperatures**. The temperature is the atmosphere model's own: a content pin, else the
## greenhouse, else plain equilibrium.
static func _thermal(
	body: SpacesimSystemBody, materials: SpacesimMaterialTable, luminosity: float, distance: float
) -> Vector2:
	var pressure := 0.0
	if body != null and body.atmosphere != null:
		pressure = body.atmosphere.surface_pressure
	return Vector2(
		SpacesimAtmosphereModel.reference_temperature(body, materials, luminosity, distance), pressure
	)


## One band, with its colour normalised and its shading chosen by what kind of material it is.
static func _band(material: SpacesimSpecies, from: float, to: float, phase: int) -> Dictionary:
	return {
		"material": material.species_name,
		# **The phase travels with the band**, because a renderer draws water and rock differently: the ocean
		# layer exists for a liquid band and for nothing else. It is the derivation's own answer rather than a
		# second guess at what the material is.
		"phase": phase,
		"from": from,
		"to": to,
		"color": band_color(material),
		"albedo": material.albedo,
		"roughness": band_shading(material).x,
		"specular": band_shading(material).y,
	}


## A material's colour with **its luminance set to its own albedo**, keeping the hue.
##
## A drawn brightness and a physical reflectance are different quantities, and this project has already
## paid for conflating them once. The authored palette is not a reflectance table — it is a picture
## someone chose — so the hue is kept and the level is corrected to the number the light budget uses.
static func band_color(material: SpacesimSpecies) -> Color:
	if material == null:
		return UNPINNED_COLOR
	var luminance := material.color.get_luminance()
	if luminance <= 0.0:
		return Color(material.albedo, material.albedo, material.albedo, 1.0)
	var scale := material.albedo / luminance
	return Color(
		material.color.r * scale, material.color.g * scale, material.color.b * scale, 1.0
	)


## How a band's material takes light: `(roughness, specular)`.
##
## **Two constants per kind of material, in one place** — the same arrangement `SpacesimBodyRenderer`
## already had, moved to where the material's own phase decides it. A liquid is glossy and reflects a
## sharp sun (which is what makes an ocean read as water rather than as a dark patch); a frozen volatile
## is bright and slightly glossy; rock and vegetation are neither.
static func band_shading(material: SpacesimSpecies) -> Vector2:
	if material == null:
		return Vector2(0.9, 0.15)
	if material.domain == SpacesimSpecies.Domain.LIQUID:
		return Vector2(0.08, 0.5)
	if material.melting_temperature > 0.0:
		return Vector2(0.45, 0.35)
	return Vector2(0.9, 0.15)
