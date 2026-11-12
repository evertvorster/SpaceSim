class_name SpacesimIrregularBody
extends RefCounted
## **A body that was never rounded by its own gravity** — a rock, not a small planet.
##
## Evert, 2026-11-08: *"I think what went wrong is that we tried to re-use planets mechanism, and these smaller
## bodies are something fundamentally different."* and *"I want non-planets to have a differently shaped mesh,
## not planet-shaped at all."*
##
## So this is **not a mode of the planet builder**. It is a second builder, and what it makes shares nothing with
## the first:
##
## | | a planet | a body built here |
## |---|---|---|
## | the mesh | a patch walk, refined by angular size and stitched | **one static mesh**, generated from the shape |
## | the shape | a sphere, because gravity made one | **the generated outline, swept** — no sphere anywhere |
## | the field | a height field sampled per pixel | **none** |
## | material | a composition ramp, an ocean, decks, air | **one matte colour**, derived from what it is made of |
## | updates | re-walked as the eye moves | **never** — built once, placed once |
##
## **Radius decides, and it is the only rule.** Below the potato radius a body's own gravity was never strong
## enough to round it, so it kept the shape it accreted; above it, the planet path is right and unchanged. That
## makes a belt's fragments automatic rather than a kind somebody has to remember to author, and it is the same
## rule the relief law already carries (Evert, 2026-11-08: *"Yes, I think radius is the best discriminator"*).
##
## **What the reuse will be, when asteroids and Saturn's ring rocks arrive.** The generator is a pure function of
## (seed, radius) and takes a few hundred thousand iterations once, so a *population* is one loop of `mesh()`
## calls at build time and one shared mesh per distinct seed — not a per-frame cost and not a per-instance one.
## Nothing here draws per tick, and nothing here is a function of the eye, which is what keeps that open.

## **The radius below which a body was never rounded by its own gravity** — the *potato radius*, a few hundred
## kilometres for rock and ice. Above it the planet mechanism; below it, this one.
const POTATO_RADIUS := 300000.0

## **The field's grid, in cells across the body.** 64 is the cost/quality compromise `tests/probe_blob_rock.gd`
## measured: 10,444 triangles and 0.8 s a body at build. That is fine for a handful of moons and **too much for a
## belt** — a population needs the extraction on a worker thread or the GPU, or a small library of shapes reused.
const RESOLUTION := 64

## **How big a body has to look before its shape is worth extracting**, in pixels of RADIUS — and it is **half the
## point tier** (`SpacesimLod.POINT_TIER_SCREEN_RADIUS` is 4), because the work has to be STARTED before the eye
## arrives and finished before the handover. Every other ladder in this project starts its work the same way.
const RESOLVE_PIXELS := 2.0


## **Is this body drawn by its own mechanism?** Radius decides, because radius is what decides whether gravity
## could round a body; a star is always large enough that it never comes up, and is excluded by name because a
## star's mesh is its photosphere rather than a ground.
static func is_irregular(body: SpacesimSceneBody) -> bool:
	return (
		body.radius > 0.0
		and body.radius < POTATO_RADIUS
		and body.content != null
		and body.content.kind != SpacesimSystemBody.Kind.STAR
	)


## **Placed now, extracted when the eye is close enough to resolve it.**
##
## **Nothing here builds the shape.** Evert, 2026-11-12: *"We should only be building them when we get close
## enough to start resolving them. Does the LOD principle mean nothing to you?"* — a system with a dozen moons paid
## ten seconds at load for geometry nobody was looking at, and the meshes were built whether or not the player ever
## flew within a million kilometres of them. The LOD principle is a requirement of this engine, not an optimisation.
##
## So a body is a node, a material, a point of light and a sphere for the travel unit; [method request] is what
## extracts it, once, from [method SpacesimSystemScene.update_lod] when its disc is worth drawing.
static func build(parent: Node3D, body: SpacesimSceneBody) -> void:
	body.irregular = true
	body.scale_body = SpacesimScaleBody.new(parent, body.radius)
	var material := material_for(body)
	var mesh := MeshInstance3D.new()
	mesh.name = "%sSurface" % body.name
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh)
	body.mesh = mesh
	body.mesh_material = material
	body.point = SpacesimBodyRenderer.add_point(parent, body.name)


## **Ask for the extraction, on the worker pool.** Captured values, not members read on the worker: a removal that
## lands meanwhile must not change the shape of a build that is already described, and the shape is the one thing
## the eye cannot check while it is being used.
static func request(body: SpacesimSceneBody) -> void:
	if body.irregular_task != -1 or body.irregular_built:
		return
	body.irregular_task = WorkerThreadPool.add_task(
		_extract.bind(body, hash(body.id), body.radius, RESOLUTION, body.removals)
	)


## **The extraction itself** — arithmetic only, which is why it may run off the main thread. The mesh is made in
## [method poll], because `add_surface_from_arrays` reaches the `RenderingServer`.
static func _extract(
	body: SpacesimSceneBody, seed_value: int, radius: float, resolution: int, removals: Array
) -> void:
	body.irregular_arrays = SpacesimBlobShape.arrays(seed_value, radius, resolution, removals)


## **Publish a finished extraction, on the main thread.** No stall and no hole: until this lands the body is its own
## point of light, sized to the disc it would have had, so the picture improves rather than blinking.
static func poll(body: SpacesimSceneBody) -> void:
	if body.irregular_task == -1:
		return
	if not WorkerThreadPool.is_task_completed(body.irregular_task):
		return
	WorkerThreadPool.wait_for_task_completion(body.irregular_task)
	body.irregular_task = -1
	var surface: Array = body.irregular_arrays
	body.irregular_arrays = []
	var shape := SpacesimBlobShape.mesh_from(surface)
	if shape == null:
		return
	body.solid_mesh = shape
	body.mesh.mesh = shape
	# **Counted once, from the mesh that is drawn**, so the HUD's total includes a rock and a static mesh needs no
	# walk to be counted from.
	body.static_triangles = shape.get_faces().size() / 3
	# **The altitude datum arrives with the shape.** Until now the body was a sphere to `surface_distance_mesh`,
	# which is right at the distance its geometry was not worth; from here it answers with its own vertices.
	if body.scale_body != null:
		body.scale_body.surface = SpacesimSurfacePoints.new(
			surface[Mesh.ARRAY_VERTEX], body.radius * 0.12
		)
	body.irregular_built = true


## **The body in the debug view — its own mesh, as lines.**
##
## Evert, 2026-11-12: *"in wireframe mode, I want to see the meshes of EVERYTHING."* In this engine a wireframe is
## not a material or a render mode: the walk builds a `PRIMITIVE_LINES` mesh and the shaded one is a different
## product of the same walk. A body with no walk therefore had no wireframe at all — which is the gap this closes,
## and it closes it by drawing the line mesh of the same grid rather than by dressing the solid one white.
##
## **Unconditional**: there is no second setting, because a rock has one mesh and nothing to tell apart in it. The
## line mesh is built on first use and kept.
static func show_wireframe(body: SpacesimSceneBody, wire: bool) -> void:
	if body.mesh == null or body.solid_mesh == null:
		return
	if wire and body.wire_mesh == null:
		body.wire_mesh = SpacesimBlobShape.wire_mesh(body.solid_mesh)
	body.mesh.mesh = body.wire_mesh if wire else body.solid_mesh
	body.mesh.material_override = (
		SpacesimBodyRenderer.wireframe_material() if wire else body.mesh_material
	)


## **What it is made of, and nothing else.** A regolith scatters: full roughness, no specular, no gloss — the one
## thing a smooth untextured body gets wrong if it is given a planet's material, which is that it reads as glass
## (Evert, 2026-11-08: *"looks like a glass sphere"*).
##
## Lit by the scene's own star light, which is a real `DirectionalLight3D`, so the colour is the body's derived
## albedo and the shading is the engine's Lambert rather than a second lighting law of our own.
##
## **The datum stays the sphere, deliberately, for stage 1.** `SpacesimScaleBody` answers altitude and proximity
## from `body.radius`, so standing on a lump is wrong by up to the lump's height. The shape's own datum
## (`SpacesimBlobShape.radius_at`) is the fix and it belongs with landing, not with placing — see the vault's
## small-bodies note, §5c.
static func material_for(body: SpacesimSceneBody) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = body.color
	material.roughness = 1.0
	material.metallic_specular = 0.0
	return material
