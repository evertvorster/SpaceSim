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
## **The datum lattice, drawn as its own wireframe** — the same chunks and the same points the surface uses, with
## nothing translated. It exists so the wireframe view can show the SUBDIVISION beside the things built on it: the
## sphere, the surface translated off it, and each deck translated to its level are three consumers of one tessellation,
## and the point of the view is to see all three. `render.wireframe_sphere` owns it, and it is never drawn outside a
## wireframe — in every other mode the surface is the visible thing and a ball under it would only hide it.
var sphere: MeshInstance3D
## The lines the worker built for it: empty until a build lands, and cleared when they are published.
var sphere_arrays: Array = []
## **The body's surface field plan, derived once**, and the datum a translated vertex measures from.
##
## Both exist because the geometry needs what the shader already had: `plan.amplitude` is how many metres a field unit
## is, and `sea_level` is the level the land stands from. Keeping them on the body rather than re-deriving them at the
## translation means the shader and the mesh cannot be given two different datums.
var surface_plan: SpacesimSurfaceField.Plan
## **A body drawn by [SpacesimIrregularBody] instead of by the planet path**, because its own gravity never rounded
## it. Set once, at build, and never cleared: it is what keeps `update_lod` from asking for a patch walk for a body
## whose mesh is generated and final. There is no second place that has to ask the question.
var irregular := false
## **The triangles its own mesh draws**, counted from that mesh at build. A static mesh has no walk to be counted
## from, and the HUD's total has to include it.
var static_triangles := 0
## **The generated solid, and the wireframe's line version of it**, for a body built by `SpacesimIrregularBody`.
## Both are kept because wireframe mode swaps the node's mesh and the solid has to come back when the view does;
## `wire_mesh` is built the first time a wireframe view asks for it, so a debug view is not a cost every rock pays.
var solid_mesh: ArrayMesh
var wire_mesh: ArrayMesh
var sea_level := 0.0
## **The field's measured extremes for this body** — `quantiles[0]` and `quantiles[last]`, which are NOT ±1: the
## shares are summed and the warp pushes past the normaliser, so Earth measures **-1.139 to +1.516**. The translation
## normalises about the datum by these spans, so they are what makes "the highest ground stands `amplitude` metres up"
## true; dividing by the nominal ±1 put the peaks at 35 km on Earth (2026-11-02). The field's own floor for bodies with
## no measurement, which is the barren case where nothing below the datum exists anyway.
var field_min := -1.0
var field_max := 1.0
## **The sea**, when the body has a liquid on it: a node wearing the GROUND's own mesh at ratio 1.0, because the sea's
## surface IS the sphere the ground is displaced from. Empty arrays mean the walk has not published yet.
var ocean: MeshInstance3D
var ocean_material: ShaderMaterial
var ocean_arrays: Array = []
var ocean_arrays_origin := Vector3.ZERO
## **The opaque floor under a body with no surface**: a gas giant's interior, drawn so a gap between two decks
## shows darkness rather than stars. Empty on every body that has a ground — its own surface is the floor.
var interior: MeshInstance3D
var interior_material: ShaderMaterial
var interior_arrays: Array = []
var interior_arrays_origin := Vector3.ZERO
## Metres BELOW the datum, derived from where the model stops claiming to know the troposphere — see
## `SpacesimSystemScene._build_interior`.
var interior_depth := 0.0
## **The air, as one shell per band** — the atmosphere's top boundary for now (2026-11-02), a deck's base once
## the stack is split. Its own icosphere at the band's outer radius, NOT the patch walk: a surface that must be
## visible everywhere cannot borrow a mesh whose coverage was selected for the ground.
var air_shell: MeshInstance3D
var air_shell_material: ShaderMaterial

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
	## A diffuse haze rather than a cloud on a condensation level: it sits at the top of the highest deck and
	## carries no map — see `SpacesimCloudLayer.haze`.
	var haze := false
	var albedo := 0.0
	var palette := Color.WHITE
	## The layer's optical depth at full thickness as CONTENT stated it, or 0 where it stated none. Kept apart
	## from `tau` because it is the authored number and `tau` is the one that is actually used.
	var optical_depth := 0.0
	## **The layer's optical depth at a full column — ONE number, and every use reads it** (2026-11-03).
	##
	## `ALPHA = covered · veil · (1 − exp(−tau · thickness / mu))` draws the deck, `exp(−tau · path)` lights its
	## base and shades the ground, and the ramp gain is fitted to `mean(R(tau))` measured at this same depth. It
	## used to be two numbers: the deck drew with the depth the map's mean thickness implied and the shadow cast
	## with `−ln(1 − opacity)`, which were 3.07x apart on Earth and 6.81x on Neptune, with no law relating them.
	##
	## **It is `optical_depth` where content states one, and `−ln(1 − opacity)` otherwise** — the second is what
	## "how opaque it is where it covers" already means, since `α = 1 − e^{−τ}` at a full column. Zero for a
	## layer that states neither, which is a deck that draws nothing.
	var tau := 0.0
	## The body's cloud organisation, which is what the field is generated from. One derivation for the whole
	## stack: the bands do not change with altitude.
	var morphology: SpacesimCloudModel.Morphology
	## The width of the map the material is currently sampling, so a publish happens when one lands rather
	## than every frame. `-1` is *nothing published yet*, which is not the same as width 0 (*no map*).
	var published_width := -1
	## **The deck's geometry: the GROUND's selection, translated to this level.** Written on the worker beside the
	## ground's arrays and published beside its transform, so a deck and the surface under it are always the same
	## tessellation of the same points — the whole point of the shared lattice. Empty until the first build lands.
	var arrays: Array = []
	## Whether `arrays` is EDGES rather than triangles — the wireframe view draws a deck as lines too, so a deck's
	## geometry is whatever the *view* asked for, exactly as the ground's is.
	var arrays_lines := false
	## The origin those points are measured from: the near-eye point at *this* level's radius. Metres, like the
	## ground's, so the node's scale stays 1 and its basis cannot round a planet-sized coordinate.
	var origin := Vector3.ZERO
## The **point of light** this body becomes once it is too small to be a disc: a camera-facing quad,
## sized to the disc it would have had and coloured by its radiance. Hidden while the body is drawn as
## geometry. Set by `SpacesimSystemScene.update_lod`.
var point: MeshInstance3D
## **The walk's last answer, and what it was taken at** — the distance, the eye's direction, ε, the extent the
## selection had to reach, and the wireframe flag. `SpacesimPatches.walk_is_due` decides from these whether the walk
## has to run again, so a sub-millisecond walk stays off the frame when nothing about its answer has moved.
var patch_walk_distance := 0.0
var patch_walk_direction := Vector3.ZERO
var patch_walk_epsilon := -1.0
var patch_walk_wireframe := false
## **How far out the last walk reached, in radians** — the largest `SpacesimPatches.cover_angle` over the layers drawn
## on this body. `-1` is *never walked*, which is not the same as a zero cap.
var patch_walk_cover := -1.0
## **The facet angle the last walk ran with**, in radians — `lod.facet_angle`, which is a setting. `walk_is_due` compares
## it, because it is an input to the selection and a change to it has to re-walk even though the eye has not moved.
var patch_walk_facet := -1.0
## **The selection the walk last produced**, as `[face, path, depth]` chunk references — a hundred entries
## where it used to be thirty thousand triangles.
var patch_chunks: Array = []
## **The rebuild in flight**, as a `WorkerThreadPool` task id, or -1. What it was asked to build travels
## with its output (`patch_arrays_chunks`), not here — see below.
var patch_task := -1
## The arrays the task produced. **Written on the worker and read on the main thread only after
## `is_task_completed` says so** — the handoff that makes this safe without a lock.
var patch_arrays: Array = []
## **The origin the arrays in hand were measured from.** A publish must place the mesh at THIS, never at
## `patch_task_origin` — that member is overwritten by every request, so a build that lands after a later request has
## already moved the origin would be drawn `|new - old|` away from where its vertices were measured. That is a
## whole-mesh jump, and Evert saw it in flight on 2026-10-30 as *"a regular jump for the surface ... the publishing of
## the updated vertexes after a walk"*.
var patch_arrays_origin := Vector3.ZERO
## **The selection those arrays were built for, and whether they are lines.** The other two things the publish
## needs, written on the worker beside the arrays for exactly the reason above: the request members are
## overwritten by the next request *before* its in-flight guard returns, so reading them at publish names
## whatever was asked for last, not what landed.
##
## **(V)** The wireframe half published a LINES mesh built from solid arrays; the selection half made the
## staleness check compare the newest request with itself, so a stale build was judged fresh and never
## re-requested until the next walk fired.
var patch_arrays_chunks: Array = []
var patch_arrays_wireframe := false
## Triangles the mesh currently on the node holds. **Zero until the first build lands**, which is why a
## body draws nothing for its first frame or two rather than stalling the frame that asked for it.
var patch_triangles := 0
## The point the mesh's vertices are measured from, in body-space metres — this build's **bind argument** to the
## worker, and nothing else. **The publish must never read it**: it is overwritten by every request, so it names
## the latest request rather than the build that landed. The publish uses `patch_arrays_origin`. See
## `SpacesimPatches.rebase`.
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
## no air. **It is the outer radius of the body's first air shell** (`air_shell.gdshader`), and the gate —
## `SpacesimLod.air_ring_pixels` — is measured from it.
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
