class_name SpacesimAtmosphere
extends Resource
## A body's atmosphere as content: how much of it, and what it is made of.
##
## The profiles (T(h), P(h), rho(h)), the retention test per species and the scattering
## coefficients are all **derived** from this — never authored.

@export var surface_pressure: float = 0.0 ## pascals
## Mole fractions, summing to ~1. Keys are species in the material table.
@export var species: Dictionary[String, float] = {}
## Condensables: their `species` entry is a reference value, not a fixed one, which lets a water
## world's greenhouse depend on its temperature without a feedback loop in the data.
@export var variable_species: PackedStringArray = []
