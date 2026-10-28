class_name SpacesimSceneBody
extends RefCounted
## One body's **built** half: the content it came from, and the nodes it was built into.
##
## The content lives in [SpacesimSystemBody]. A Godot `Resource` is cached and shared, so one
## holding node references would hand the same nodes to a second build — the nodes live here, and
## this is the object the scene hands out.

## The authored body this was built from. The fields below are copied out of it so the scene does
## not have to reach through it everywhere; `content` is kept for anything the derivation will need.
var content: SpacesimSystemBody
var id: String
var name: String
var kind: String ## "star", "planet", "moon", ...
var radius: float ## metres
var position: Vector3 ## in the system frame, metres — fixed, or solved from the orbit
var color: Color
var parent_id: String
var fixed_position: Vector3
var orbit: SpacesimOrbit
var landable: bool
var significant: bool

# Built by SpacesimSystemScene.
var node: Node3D
var mesh: MeshInstance3D
## The material `mesh` is drawn with when it is **not** a wireframe, kept so the debug view can restore it.
## Set when the body is built; `update_lod` swaps a wireframe material over it and puts this one back.
var mesh_material: Material
## **The cloud stack**: one deck per layer the model places a level for, highest first, each a node on the
## body's own patch mesh at its own derived radius. Empty for a body with no air, no authored deck, or no
## condensable that forms a level — which is most of them.
var decks: Array[Deck] = []


## One deck, built: the node, its material, and the derived altitudes they were placed at.
##
## **Kept together because they are one thing** — a node without its level has nowhere sensible to sit, and a
## material without the measurement its map produced carries another layer's threshold. `index` is the
## content layer it came from, which is what the map cache and the field's seed are keyed by.
class Deck:
	extends RefCounted

	var node: MeshInstance3D
	var material: ShaderMaterial
	var level: SpacesimAtmosphereModel.Condensation
	var index := 0
	## Metres above the surface, and the slab's thickness — the node is scaled to `radius + height + thickness`
	## and `base_ratio` is what places the base inside it.
	var height := 0.0
	var thickness := 0.0
	## What content says this layer covers and reflects, and the hue it is drawn in — resolved once at build,
	## because the map's threshold and ramp gain are fitted to them on every publish.
	var coverage := 0.0
	var albedo := 0.0
	var palette := Color.WHITE
	## The layer's optical depth at full thickness, or 0 for the reflectance-ramp path. It decides which of
	## the map's two measured means the ramp gain is fitted to.
	var optical_depth := 0.0
	## **The depth the SHADOW uses**, which is not always the one the deck draws with: a layer on the ramp path
	## states no `optical_depth`, and its honest equivalent is `−ln(1 − opacity)` — what "how opaque it is where
	## it covers" already means, since `α = 1 − e^{−τ}`. Zero for a layer that is neither.
	var shadow_tau := 0.0
	## The body's cloud organisation, which is what the field is generated from. One derivation for the whole
	## stack: the bands do not change with altitude.
	var morphology: SpacesimCloudModel.Morphology
	## The width of the map the material is currently sampling, so a publish happens when one lands rather
	## than every frame. `-1` is *nothing published yet*, which is not the same as width 0 (*no map*).
	var published_width := -1
## The **point of light** this body becomes once it is too small to be a disc: a camera-facing quad,
## sized to the disc it would have had and coloured by its radiance. Hidden while the body is drawn as
## geometry. Set by `SpacesimSystemScene.update_lod`.
var point: MeshInstance3D
## **The walk's last answer, and what it was taken at** — the distance, the eye's direction, ε, and the
## wireframe flag. `SpacesimPatches.walk_is_due` decides from these whether the walk has to run again, so a
## sub-millisecond walk stays off the frame when nothing about its answer has moved.
var patch_walk_distance := 0.0
var patch_walk_direction := Vector3.ZERO
var patch_walk_epsilon := -1.0
var patch_walk_wireframe := false
## **The selection the walk last produced**, as `[face, path, depth]` chunk references — a hundred entries
## where it used to be thirty thousand triangles.
var patch_chunks: Array = []
## **The rebuild in flight**, as a `WorkerThreadPool` task id, or -1. `patch_task_chunks` is what it was
## asked to build, so a newer selection is not lost while it runs.
var patch_task := -1
var patch_task_chunks: Array = []
var patch_task_wireframe := false
## The arrays the task produced. **Written on the worker and read on the main thread only after
## `is_task_completed` says so** — the handoff that makes this safe without a lock.
var patch_arrays: Array = []
## Triangles the mesh currently on the node holds. **Zero until the first build lands**, which is why a
## body draws nothing for its first frame or two rather than stalling the frame that asked for it.
var patch_triangles := 0
## The point the mesh's vertices are measured from, in body-space metres — captured with the build and written onto the
## node with the mesh it belongs to. See `SpacesimPatches.rebase`.
var patch_task_origin := Vector3.ZERO
## **This body's vertex lattice**, kept between walks so a merge is a memcpy of index blocks rather than a rebuild.
## Owned here because the slots are per body; see `SpacesimPatches.Lattice`.
var lattice := SpacesimPatches.Lattice.new()
## **The walk in flight, and the numbers it was asked with.** The selection is the expensive half of a frame and it is
## pure arithmetic over immutable data, so it runs on a pool thread; these three fields are the whole handshake.
var patch_walk_task := -1
var patch_walk_chunks: Array = []
## Whether the drawn arrays carry the depth tint, so a toggle re-walks and rebuilds them.
var patch_walk_tinted := false
## Whether an empty selection has already been reported for this body, so the reason is printed once
## rather than once a second for the rest of the session.
var patch_empty_reported := false
var atmosphere: SpacesimFrame
var surface: SpacesimFrame
var scale_body: SpacesimScaleBody
## **How tall this body's air is**, in metres — derived from the air's own scale height, floored where the
## framing says its atmosphere frame begins.
##
## Kept on the body rather than recomputed because the camera's far plane needs it
## (`SpacesimSystemScene.sky_reach`), which falls short of the air's top otherwise. Zero for a body with
## no air. It is what `SpacesimAtmospherePass` marches to — the shell that used to be built at this radius is
## gone, and the air is one volumetric march over the frame (`416294b`).
var sky_top: float = 0.0
## **The air's scattering numbers, derived once at build** — the per-channel Rayleigh coefficient, the
## absorption, the scale height, the Mie constants and the sun's intensity in frame units. Empty for a body
## with no air, which is how both the scene and the pass know to skip it. Kept here because
## `rayleigh_coefficient` walks the species table and the temperature chain, and the march wants the numbers
## every frame.
var air := {}

## **The fraction of this body's surface that is under water**, from
## `SpacesimSurfaceModel.sea_level_percentile()` — derived once at build, because it is asked for every frame
## and it walks the greenhouse to get there. The surface shader's `sea_level` is this percentile *resolved
## through the map's measured quantiles*, which is the map cache's business.
var surface_ocean_fraction: float = 0.0



static func from_content(
	content: SpacesimSystemBody, materials: SpacesimMaterialTable = null
) -> SpacesimSceneBody:
	var body := SpacesimSceneBody.new()
	body.content = content
	body.id = content.id
	body.name = content.display_name
	body.kind = content.kind_name()
	body.radius = content.radius
	body.parent_id = content.parent_id
	body.fixed_position = content.fixed_position
	body.orbit = content.orbit
	body.landable = content.landable
	body.significant = content.significant
	body.color = color_of(content, materials)
	return body


## The colour to draw a body in: what content pinned, or **the derivation** — surface coverage blended
## with the cloud deck, through the material table.
##
## Pinning still wins, because content overrides derived values everywhere else: a system that wants a
## particular look says so rather than being second-guessed. `UNPINNED_COLOR` is what a body with
## nothing to derive from gets.
static func color_of(
	content: SpacesimSystemBody, materials: SpacesimMaterialTable = null
) -> Color:
	if content.overrides != null and content.overrides.set.has("surface_color"):
		return content.overrides.surface_color
	return SpacesimSurfaceModel.color(content, materials)


func orbits() -> bool:
	return orbit != null
