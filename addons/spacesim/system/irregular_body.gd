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


## **The body's whole geometry and material, built once.** `parent` is the body's own node, already placed in
## the system frame.
##
## `body.mesh` is the static mesh and stays that mesh for the body's life: nothing in the planet path can reach
## it, because `body.irregular` keeps `update_lod` from ever asking for a walk for this body.
static func build(parent: Node3D, body: SpacesimSceneBody) -> void:
	body.irregular = true
	# **The shape is the seed's, not the body's radius alone** — `hash(body.id)` means two 11 km rocks are two
	# rocks, and the same body is the same rock every load.
	#
	# **A field, not a swept outline**: a few seeded balls fused with a smooth minimum, so a lump is somewhere
	# rather than all the way round one axis, and a pinch or a crater is not a special case. See
	# `SpacesimBlobShape` for why and for the cost. The swept Julia (`SpacesimJuliaShape`) is kept as the record
	# of the first attempt — it is what the flight of 2026-11-12 showed as a ribbed crescent.
	var shape: ArrayMesh = SpacesimBlobShape.mesh(
		hash(body.id), body.radius, RESOLUTION, body.removals
	)
	# **Its altitude is measured to its own vertices**, not to a mean sphere — the relief is hundreds of metres, and
	# the vertex bin is what makes that answer cost a handful of cell lookups instead of a scan per tick.
	var surface := SpacesimSurfacePoints.new(
		shape.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], body.radius * 0.12
	)
	body.scale_body = SpacesimScaleBody.new(parent, body.radius, surface)
	var material := material_for(body)
	var mesh := MeshInstance3D.new()
	mesh.name = "%sSurface" % body.name
	mesh.mesh = shape
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mesh)
	body.mesh = mesh
	body.mesh_material = material
	body.solid_mesh = shape
	# **Counted once, from the mesh that is drawn**, so the HUD's total includes a rock and a static mesh needs
	# no walk to be counted from.
	body.static_triangles = shape.get_faces().size() / 3
	# **The point of light**, so the body is a pixel of its own brightness once it is smaller than one rather
	# than an aliased speck of geometry.
	body.point = SpacesimBodyRenderer.add_point(parent, body.name)


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
