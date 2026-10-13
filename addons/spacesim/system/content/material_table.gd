class_name SpacesimMaterialTable
extends Resource
## The substances a system's compositions refer to. Ships with the engine rather than with a
## story: changing the density of iron changes physics, not art.

@export var species: Array[SpacesimSpecies] = []


func by_name(species_name: String) -> SpacesimSpecies:
	for entry in species:
		if entry.species_name == species_name:
			return entry
	return null


func names() -> PackedStringArray:
	var out := PackedStringArray()
	for entry in species:
		out.append(entry.species_name)
	return out
