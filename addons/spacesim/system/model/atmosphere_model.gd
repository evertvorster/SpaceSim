class_name SpacesimAtmosphereModel
extends RefCounted
## A body's air: what colour it is, and how thick it looks.
##
## Small on purpose. The full derivation — retention per species, the `T(h)`/`P(h)`/`rho(h)` profiles,
## the multi-band greenhouse, the Rayleigh coefficients the sky shader wants — is
## [[SpaceSim/Solar Systems and the Physics Model]] §3.4 and is not built. What is here is enough to
## render the air, and it comes from the same data the rest of the model reads.

## Earth at one atmosphere is the reference. Fog density is not a physical unit in Godot, so this is
## a mapping constant rather than physics — named so it can be found.
const DENSITY_AT_ONE_BAR := 0.03
const REFERENCE_PRESSURE := 101325.0


## The colour of the air, weighted by the mole fractions of what it is made of.
##
## The same pattern as the surface: the materials carry the colours, the composition says how much of
## each. Earth comes out pale blue (nitrogen and oxygen), Venus a warm cream (carbon dioxide), and
## Titan a dim orange (methane haze) — none of which is authored.
static func color(body: SpacesimSystemBody, materials: SpacesimMaterialTable) -> Color:
	if body.atmosphere == null or materials == null:
		return Color(0.5, 0.6, 0.75)
	var total := Color(0.0, 0.0, 0.0)
	var weight := 0.0
	for key in body.atmosphere.species:
		var material := materials.by_name(String(key))
		if material == null:
			continue
		var fraction := float(body.atmosphere.species[key])
		total += material.color * fraction
		weight += fraction
	if weight <= 0.0:
		return Color(0.5, 0.6, 0.75)
	return total / weight


## How thick the air looks, 0 upwards.
##
## Square-rooted rather than proportional, because fog density is not a physical unit and a linear
## mapping makes Venus — 92 bar — opaque to the point of being a solid ball. The square root keeps
## Earth at the reference, gives Venus something like ten times the haze, and leaves Mars almost clear.
static func density(body: SpacesimSystemBody) -> float:
	if body.atmosphere == null or body.atmosphere.surface_pressure <= 0.0:
		return 0.0
	return DENSITY_AT_ONE_BAR * sqrt(body.atmosphere.surface_pressure / REFERENCE_PRESSURE)
