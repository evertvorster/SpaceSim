extends RefCounted
## That the shader layers are wired to the derivation.
##
## **Not that they look right, and not even that they compile.** Headless Godot does not compile
## shaders at all: `load()` hands back a valid `Shader` with a syntax error sitting inside it, and
## `--import` says nothing — verified by breaking one deliberately. Compilation is checked by
## `tests/shader_check.sh`, which needs a window (`xvfb-run` counts).
##
## What is checkable here is the **wiring**, and that is worth checking on its own: every value a
## shader is handed must have come from the derivation, and a constant that should be derived must not
## be hiding in the shader.

const SOL_PATH := "res://systems/sol.tres"


func run(h, root: Node) -> void:
	print("  render layers")
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	h.check(sol != null, "Sol loads")
	if sol == null:
		return

	var scene := SpacesimSystemScene.from_content(sol)
	h.check(scene != null, "a scene wraps it")
	if scene == null:
		return
	scene.build(root)

	var earth := scene.body_by_id("planet:earth")
	var luna := scene.body_by_id("moon:luna")

	_test_surface_is_derived(h, earth, luna)
	_test_clouds_are_derived(h, scene, earth, luna)
	_test_hiding_bodies_hides_their_clouds(h, scene)

	scene.container.free()


func _test_surface_is_derived(h, earth: SpacesimSceneBody, luna: SpacesimSceneBody) -> void:
	var material: ShaderMaterial = earth.mesh.material_override
	h.check(material != null and material.shader != null, "the surface carries a shader material")
	if material == null:
		return

	# The two gradient stops come from the derived colour, so a world keeps its identity while gaining
	# structure — rather than two hand-picked colours that could belong to anything.
	h.check(material.get_shader_parameter("base_color") == earth.color.darkened(0.35),
		"the base colour is the derived colour, darkened")
	h.check(material.get_shader_parameter("detail_color") == earth.color.lightened(0.25),
		"and the detail colour is the derived colour, lightened")

	# One noise field, shared. Two bodies differ by offset, not by texture.
	var luna_material: ShaderMaterial = luna.mesh.material_override
	h.check(material.get_shader_parameter("noise_field") == luna_material.get_shader_parameter("noise_field"),
		"every body draws from the same noise field")
	h.check(material.get_shader_parameter("noise_offset") != luna_material.get_shader_parameter("noise_offset"),
		"and each body is given its own place in it")
	h.check(SpacesimBodyRenderer.offset_for("planet:earth") == material.get_shader_parameter("noise_offset"),
		"which is stable for a given id")


## The link that matters: the **authored cloud fraction is the coverage**, so content's number is what
## the shader draws rather than a figure it politely ignores.
func _test_clouds_are_derived(h, scene: SpacesimSystemScene, earth: SpacesimSceneBody, luna: SpacesimSceneBody) -> void:
	h.check(luna.cloud_mesh == null, "Luna has no cloud shell — content gives it no deck")

	h.check(earth.cloud_mesh != null, "Earth has one")
	if earth.cloud_mesh == null:
		return
	var shell := earth.cloud_mesh.mesh as SphereMesh
	h.check_near(shell.radius, earth.radius * SpacesimBodyRenderer.CLOUD_SHELL,
		"the deck sits just above the surface, so it draws over it rather than fighting it", 1.0)

	var material: ShaderMaterial = earth.cloud_mesh.material_override
	h.check(material != null and material.shader != null, "with its own shader material")
	if material == null:
		return
	h.check_near(material.get_shader_parameter("coverage"), earth.content.clouds.fraction,
		"whose coverage IS the authored fraction (%.2f)" % earth.content.clouds.fraction, 1.0e-6)
	h.check(material.get_shader_parameter("cloud_color") == earth.content.clouds.color,
		"and whose colour is the authored one")

	# A body under a solid deck: the fraction is 1.0, so the shader has nothing left to decide.
	var venus_material := SpacesimBodyRenderer.cloud_material(scene.body_by_id("planet:venus"))
	h.check(venus_material != null and venus_material.get_shader_parameter("coverage") == 1.0,
		"a body under a solid deck reports full coverage")

	# And a body with no deck at all gets no material, rather than one drawing nothing.
	h.check(SpacesimBodyRenderer.cloud_material(luna) == null,
		"a body without a deck is given no cloud material at all")


func _test_hiding_bodies_hides_their_clouds(h, scene: SpacesimSystemScene) -> void:
	# `P` hides the bodies. Leaving the decks behind would look like a bug rather than a debug key.
	var meshes := scene.meshes()
	var clouds := 0
	for mesh in meshes:
		if mesh.name.ends_with("Clouds"):
			clouds += 1
	h.check(clouds > 0, "the debug key's mesh list includes the cloud decks (%d)" % clouds)
