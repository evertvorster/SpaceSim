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


## Bond albedo: the fraction of the star's light the body reflects.
##
##   A = cloud_fraction * cloud_albedo + (1 - cloud_fraction) * surface_albedo
static func bond_albedo(body: SpacesimSystemBody, materials: SpacesimMaterialTable) -> float:
	var cover := cloud_fraction(body)
	var deck := 0.0
	if body.clouds != null:
		deck = body.clouds.albedo
	return cover * deck + (1.0 - cover) * surface_albedo(body, materials)


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
