extends RefCounted
## **The testing platform**: three modes, the EV switch, and the tree's own numbers.
##
## These are the things every later judgement depends on, so they are asserted rather than eyeballed: `flat` must draw
## exactly what the ground's material draws (it *is* the ground's material), `wireframe` must swap in the unshaded line
## material, and **`rendered` must draw nothing** until a body has a rendered texture — the failure this guards against is
## a mode that quietly falls back to `flat` and quietly becomes the only way to see the ground.
##
## Evert, 2026-10-28: *"return to a testing platform where we can draw either wire frames, solid textures, or rendered
## textures"* and, on the third: *"It should just draw nothing, until we have the texture ready."*

const SOL_PATH := "res://systems/sol.tres"
const FOV := 70.0
const MODE_KEY := "render.mode"
const TINT_KEY := "render.depth_tint"


func run(h, root: Node) -> void:
	print("  platform")

	# **The modes are declared settings**, which is what makes the key, the HUD and the screen one value.
	h.check(SpacesimSettings.REGISTRY.has(MODE_KEY), "render.mode is a declared setting")
	h.check(SpacesimSettings.REGISTRY.has(TINT_KEY), "render.depth_tint is a declared setting")
	h.check(
		SpacesimSettings.REGISTRY.has("render.ev_compensation"),
		"and render.ev_compensation, so the EV can be turned off for a geometry judgement"
	)
	var choices: Array = SpacesimSettings.REGISTRY[MODE_KEY]["choices"]
	h.check(
		choices.size() == 3 and choices.has("wireframe") and choices.has("flat") and choices.has("rendered"),
		"with three modes: %s" % str(choices)
	)

	# --- the chunk colours the tint reads ------------------------------------------------------
	# **A hue per level, and distinct between levels** — the whole point of the tint is that a boundary between two
	# levels is visible, so two adjacent depths must not come out the same colour.
	var shallow := SpacesimPatches.depth_tint(2)
	var deeper := SpacesimPatches.depth_tint(3)
	h.check(not shallow.is_equal_approx(deeper),
		"two adjacent levels are different colours (%s against %s)" % [shallow.to_html(false), deeper.to_html(false)])

	var sol: SpacesimSolarSystem = load(SOL_PATH)
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null or sol == null:
		h.check(false, "Sol loads for the platform half")
		return
	scene.build(root)
	var earth := scene.body_by_id("planet:earth")
	if earth == null or earth.node == null:
		h.check(false, "Earth is in the scene")
		return
	var camera := Camera3D.new()
	camera.fov = FOV
	root.add_child(camera)
	var pixel := SpacesimLod.pixel_angle(camera.fov, float(camera.get_viewport().size.y))
	# A screen radius that puts Earth well inside the mesh tier.
	var distance := earth.radius / sin(atan(300.0 * pixel))
	camera.global_position = earth.node.global_position + Vector3(distance, 0.0, 0.0)

	# --- `flat` is the ground's own material ---------------------------------------------------
	SpacesimSettings.set_value(MODE_KEY, "flat")
	scene.wireframe = false
	scene.surface_hidden = false
	scene.update_lod(camera)
	scene.await_patch_builds()
	h.check(earth.mesh.visible, "flat draws the ground")
	h.check(earth.mesh.material_override == earth.mesh_material,
		"with the body's own material — flat is the surface, not a lookalike")
	h.check(earth.patch_triangles > 0,
		"and the tree's numbers are the drawn mesh's (%d triangles, %d chunks, depth %d)"
			% [scene.triangles(), scene.chunks(), scene.deepest_level()])
	h.check(scene.chunks() > 0 and scene.deepest_level() > 0,
		"with chunks and a deepest level for the HUD to show")

	# --- `wireframe` swaps in the unshaded line material ----------------------------------------
	SpacesimSettings.set_value(MODE_KEY, "wireframe")
	scene.wireframe = true
	scene.update_lod(camera)
	scene.await_patch_builds()
	h.check(earth.mesh.visible, "wireframe still draws the body")
	h.check(earth.mesh.material_override == SpacesimBodyRenderer.wireframe_material(),
		"as unshaded lines — white everywhere by construction, which the viewport's own wireframe is not")

	# --- `rendered` draws NOTHING until there is a texture --------------------------------------
	SpacesimSettings.set_value(MODE_KEY, "rendered")
	scene.wireframe = false
	scene.surface_hidden = true
	scene.update_lod(camera)
	scene.await_patch_builds()
	h.check(not earth.mesh.visible,
		"rendered draws no ground at all until a body has a rendered texture")

	# --- the tint is published only when the setting moves --------------------------------------
	SpacesimSettings.set_value(MODE_KEY, "flat")
	scene.surface_hidden = false
	SpacesimSettings.set_value(TINT_KEY, false)
	scene.update_lod(camera)
	scene.await_patch_builds()
	var material := earth.mesh_material as ShaderMaterial
	h.check_near(float(material.get_shader_parameter("tint_amount")), 0.0,
		"with the tint off, the multiplier is zero and the picture is the surface's own", 1.0e-6)
	SpacesimSettings.set_value(TINT_KEY, true)
	scene.update_lod(camera)
	h.check_near(float(material.get_shader_parameter("tint_amount")), 1.0,
		"and with it on, the vertex colours carry the tree", 1.0e-6)

	# Leave the settings as they were found: this suite now owns its file (`tests/run.sh` sets a scratch
	# `XDG_CONFIG_HOME`), but a rig run outside it must not inherit a debug mode.
	SpacesimSettings.set_value(TINT_KEY, false)
	SpacesimSettings.set_value(MODE_KEY, "flat")
