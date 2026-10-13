class_name SpacesimMaterialTable
extends Resource
## The substances a system's compositions refer to. Ships with the engine rather than with a
## story: changing the density of iron changes physics, not art.

## Where the engine's own table lives. A system may carry one of its own, merged over this.
const ENGINE_TABLE_PATH := "res://addons/spacesim/system/content/materials.tres"

@export var species: Array[SpacesimSpecies] = []


## The table that ships with the engine. Godot caches the load, so this is cheap to call.
static func engine_table() -> SpacesimMaterialTable:
	var loaded: Variant = load(ENGINE_TABLE_PATH)
	if loaded == null or not (loaded is SpacesimMaterialTable):
		push_error("SpacesimMaterialTable: no engine table at '%s'" % ENGINE_TABLE_PATH)
		return null
	return loaded


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
