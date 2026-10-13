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
	_test_the_star_is_a_source(h, scene)
	_test_clouds_are_derived(h, scene, earth, luna)
	_test_the_air_is_a_shell(h, scene, sol)
	_test_hiding_bodies_hides_their_clouds(h, scene)

	scene.container.free()


## Evert's model: the air as a **hollow sphere** whose inner bound is below the surface and whose outer
## bound is where the atmosphere is declared to end. The planet occludes the middle, so what is left is
## the shell — dense at the surface, thinning upward.
func _test_the_air_is_a_shell(h, scene: SpacesimSystemScene, sol: SpacesimSolarSystem) -> void:
	var earth := scene.body_by_id("planet:earth")
	h.check(earth.air_volume != null, "Earth has an air shell")
	if earth.air_volume == null:
		return

	# The outer bound is not a guess: it is the altitude at which the framing says the observer crosses
	# into space, so the air ends exactly where the air is declared to end.
	var outer: float = earth.radius + sol.framing.atmosphere_altitude
	h.check_near(earth.air_volume.size.x, outer * 2.0,
		"its outer bound is where the atmosphere is declared to end", 1.0)
	h.check(earth.air_volume.shape == SpacesimBodyRenderer.AIR_SHAPE_ELLIPSOID,
		"and it is a sphere rather than a box")
	h.check(not earth.air_volume.visible, "hidden until the observer is inside it")

	var air: FogMaterial = earth.air_volume.material
	h.check(air.height_falloff > 0.0,
		"with a falloff, so it thins with height instead of filling the shell evenly")
	h.check(air.albedo.b >= air.albedo.r,
		"and pale blue air, from the nitrogen and oxygen that make it (%.2f, %.2f, %.2f)"
			% [air.albedo.r, air.albedo.g, air.albedo.b])

	# Air follows the atmosphere, so an airless body has none and a thick one has more.
	h.check(scene.body_by_id("moon:luna").air_volume == null, "Luna has no air at all")
	var venus: FogMaterial = scene.body_by_id("planet:venus").air_volume.material
	h.check(venus.density > air.density * 5.0,
		"and Venus's 92 bar is far thicker than Earth's one (%.3f against %.3f)" % [venus.density, air.density])

	# Whose air you are in is containment, not altitude — the frames already say it.
	h.check(scene.air_body(scene.system_frame) == null, "in space there is no air")
	var surface_frame := scene.frame_tree.frame_by_id("planet:earth/surface")
	h.check(scene.air_body(surface_frame) == earth, "and on Earth's surface it is Earth's")
	var air_frame := scene.frame_tree.frame_by_id("planet:venus/atmosphere")
	h.check(scene.air_body(air_frame) == scene.body_by_id("planet:venus"),
		"as it is in Venus's atmosphere")


## A star emits; it does not reflect. Drawn with the ordinary surface material it was lit by its own
## light — which travels from the star toward the observer, so its near face was back-lit and came out
## black — and it could not bloom, because nothing about it was above the glow threshold.
func _test_the_star_is_a_source(h, scene: SpacesimSystemScene) -> void:
	var sun := scene.body_by_id("star:sol")
	var material: ShaderMaterial = sun.mesh.material_override
	h.check(material != null and material.shader != null, "the star has a material of its own")
	if material == null:
		return
	h.check(material.shader.code.contains("unshaded"), "which is unshaded, so its own light cannot darken it")
	h.check(float(material.get_shader_parameter("intensity")) > 1.0,
		"and emissive well past the glow threshold, so it blooms")
	var color: Color = material.get_shader_parameter("star_color")
	h.check(color.r >= color.g and color.g >= color.b,
		"with the Sun's colour: warm white (%.3f, %.3f, %.3f)" % [color.r, color.g, color.b])


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
