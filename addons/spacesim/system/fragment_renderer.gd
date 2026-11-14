class_name SpacesimFragmentRenderer
extends Node3D
## **The rock you arrive at** — one fragment's shape, extracted when the eye is close enough to resolve it.
##
## A fragment of a population is a position, a diameter and an orbit; there is no geometry until somebody
## can see one. Only the **nearest** fragment is ever close enough to matter, so this draws one and
## rebuilds when the ship moves on to another one. That is the LOD principle applied to a single object:
## the work starts a little before the eye needs it, and nothing is built for the rocks behind you.
##
## **The extraction is on the worker pool and the publish is on the main thread**, the same split
## [SpacesimIrregularBody] uses: `SpacesimBlobShape.arrays` is arithmetic, `mesh_from` reaches the
## `RenderingServer`.

## Cells across the fragment's bounding cube. **Fixed, and deliberately coarse**: a rock is one to two
## orders of magnitude across against a planet's eight, so the subdivision that a planet needs to stay
## round is not needed here — the vault's small-bodies note says a single level may well be enough, and
## nothing has yet flown close enough to say otherwise.
const RESOLUTION := 24

## A fragment of diameter d is one pixel across at about 900 d (1080 lines, 70 degrees of field) — the
## same rule `SpacesimLod` uses. **Four pixels is where a shape earns an extraction**; below that the
## marker is the whole of it.
const PIXELS_AT_ONE_DIAMETER := 900.0
const RESOLVE_PIXELS := 4.0


var _mesh: MeshInstance3D
## The designation whose geometry is drawn or being built. **A string rather than an index**, because a
## fragment has no identity the rest of the engine knows: it exists for as long as it is near.
var _shown := ""
var _task := -1
var _arrays: Array = []
var _material: StandardMaterial3D


## The distance at which a fragment of this diameter is worth extracting.
static func resolve_distance(diameter: float) -> float:
	return diameter * PIXELS_AT_ONE_DIAMETER / RESOLVE_PIXELS


## Where this diameter is drawn from: the bulk solid of a composition, and nothing else.
##
## **A rock scatters** — full roughness, no metallic specular — because an untextured body given a
## planet's material reads as glass. The colour is the species' own, so what the rock is made of is what
## it looks like.
static func material_for(population: SpacesimPopulation) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = _bulk_colour(population)
	material.roughness = 1.0
	material.metallic_specular = 0.0
	return material


static func _bulk_colour(population: SpacesimPopulation) -> Color:
	var materials := SpacesimMaterialTable.engine_table()
	var best := Color(0.18, 0.16, 0.15)
	var share := 0.0
	for name in population.composition:
		var species := materials.by_name(String(name))
		if species == null or species.domain != SpacesimSpecies.Domain.SOLID:
			continue
		if float(population.composition[name]) > share:
			share = float(population.composition[name])
			best = species.color
	return best


## Show the fragment with this designation at this place, or keep what is already there.
##
## **One at a time**: a request that arrives while another extraction is in flight is dropped, and the
## next frame asks again. Two workers, two meshes and a race to publish would be three problems.
func draw_at(
	where: Vector3, designation: String, seed_value: int, diameter: float,
	material: StandardMaterial3D
) -> void:
	_ensure_mesh()
	_mesh.visible = true
	position = where
	if designation == _shown or _task != -1:
		return
	_shown = designation
	_material = material
	_mesh.mesh = null
	_arrays = []
	_task = WorkerThreadPool.add_task(
		_extract.bind(seed_value, maxf(diameter * 0.5, 0.5), RESOLUTION)
	)


## Take the shape away, and forget which fragment it belonged to — the next one is a different rock.
func hide_fragment() -> void:
	_shown = ""
	if _mesh != null:
		_mesh.visible = false


## Whether the fragment being drawn is the one this renderer was told to draw.
func is_showing(designation: String) -> bool:
	return designation == _shown


## Publish a finished extraction. Call once a frame, on the main thread.
func poll() -> void:
	if _task == -1:
		return
	if not WorkerThreadPool.is_task_completed(_task):
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	var surface: Array = _arrays
	_arrays = []
	var shape := SpacesimBlobShape.mesh_from(surface)
	if shape == null:
		return
	_mesh.mesh = shape
	_mesh.material_override = _material


func _extract(seed_value: int, radius: float, resolution: int) -> void:
	_arrays = SpacesimBlobShape.arrays(seed_value, radius, resolution)


func _ensure_mesh() -> void:
	if _mesh != null:
		return
	_mesh = MeshInstance3D.new()
	_mesh.name = "Fragment"
	# A rock's shadow is a few pixels of nothing at the range a fragment is drawn from, and casting one
	# in a scene at astronomical scale costs a shadow render for it.
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)
