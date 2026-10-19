class_name SpacesimMaterialTable
extends Resource
## The substances a system's compositions refer to. Ships with the engine rather than with a
## story: changing the density of iron changes physics, not art.

## Where the engine's own table lives. A system may carry one of its own, merged over this.
const ENGINE_TABLE_PATH := "res://addons/spacesim/system/content/materials.tres"

@export var species: Array[SpacesimSpecies] = []


## The table that ships with the engine.
##
## **Held in a static, because `load()` is only a cache hit while something still references the
## result.** The table is always used *inside* an expression — `bond_albedo(body.content,
## engine_table())` — so the temporary reference died at the end of the statement, the cache entry
## went with it, and the whole species `.tres` was re-read from disk once per point-tier body per
## frame. Measured 2026-10-15 with the GDScript profiler (`-d --profiling`): **self time 10.2-10.7 ms
## per frame, 14 calls, ~0.73 ms each**, and `SpacesimSpecies` constructed 378 times a frame
## (14 x 27). The line here used to read "Godot caches the load, so this is cheap to call" — which is
## exactly what made it look safe.
##
## **Read-only.** A `Resource` is shared, so nothing may write to what this returns.
static var _engine_table: SpacesimMaterialTable


static func engine_table() -> SpacesimMaterialTable:
	if _engine_table == null:
		var loaded: Variant = load(ENGINE_TABLE_PATH)
		if loaded == null or not (loaded is SpacesimMaterialTable):
			push_error("SpacesimMaterialTable: no engine table at '%s'" % ENGINE_TABLE_PATH)
			return null
		_engine_table = loaded
	return _engine_table


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
