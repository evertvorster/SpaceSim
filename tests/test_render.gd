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
	_test_the_sky_is_derived(h, scene, sol, earth, luna)
	_test_hiding_bodies_hides_their_air(h, scene)

	scene.container.free()


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


## The sky: that the shader's inputs are the derivation's, and that the derivation agrees with
## measured air.
##
## **The coefficients are checked against a published Earth value**, the same way the albedos are
## checked against measured Bond albedos. It is a consistency check, not a fit: if a cross-section in
## the material table is wrong, this goes red by naming the number.
func _test_the_sky_is_derived(
	h,
	scene: SpacesimSystemScene,
	sol: SpacesimSolarSystem,
	earth: SpacesimSceneBody,
	luna: SpacesimSceneBody
) -> void:
	var materials := SpacesimMaterialTable.engine_table()

	# The shell reaches where the framing says the air ends, and only bodies with air get one.
	h.check(luna.atmosphere_mesh == null, "Luna has no atmosphere shell — content gives it no air")
	h.check(earth.atmosphere_mesh != null, "Earth has one")
	if earth.atmosphere_mesh == null:
		return
	var shell := earth.atmosphere_mesh.mesh as SphereMesh
	var top := earth.radius + sol.framing.atmosphere_altitude
	h.check_near(shell.radius, top, "reaching where the atmosphere is declared to end", 1.0)

	var material: ShaderMaterial = earth.atmosphere_mesh.material_override
	h.check(material != null and material.shader != null, "with the scattering shader")
	if material == null:
		return
	h.check_near(material.get_shader_parameter("atmosphere_radius"), top,
		"and the shader knows both radii, so its ray test matches the mesh", 1.0)
	h.check_near(material.get_shader_parameter("planet_radius"), earth.radius,
		"planet radius included", 1.0)

	# The mix, at a temperature we can check by hand. Earth's air is 78% nitrogen, 21% oxygen.
	var reference := SpacesimAtmosphereModel.rayleigh_coefficient(
		earth.content.atmosphere, materials, 288.15
	)
	# A coefficient is per **channel**, so a Vector3's components are red, green and blue.
	var red := reference.x
	var green := reference.y
	var blue := reference.z
	# GDScript's `%` has no `%e`, so the numbers are scaled into micro-units and printed as floats.
	h.check(blue > green and green > red,
		"blue scatters most — which is the whole reason the sky is blue (%.2f, %.2f, %.2f) e-06"
			% [red * 1.0e6, green * 1.0e6, blue * 1.0e6])
	# 5.5e-6 and 13.0e-6 are glsl-atmosphere's Earth-like values for red and green.
	h.check(absf(red / 5.5e-6 - 1.0) < 0.25,
		"and the red channel lands on the published value (%.2f against 5.50 e-06)" % (red * 1.0e6))
	h.check(absf(green / 13.0e-6 - 1.0) < 0.25,
		"as does green (%.2f against 13.00 e-06)" % (green * 1.0e6))
	h.check(reference.length_squared() > 0.0, "and the air scatters at all")

	# Scale height: kT/(m-bar g), against the model doc's ~8.5 km for Earth.
	var gravity := SpacesimAtmosphereModel.surface_gravity(earth.content)
	h.check_near(gravity, 9.81, "Earth's surface gravity from its authored mass", 0.05)
	var height := SpacesimAtmosphereModel.scale_height(
		earth.content.atmosphere, materials, 288.15, gravity
	)
	h.check(absf(height / 8500.0 - 1.0) < 0.1,
		"and a scale height of %.0f m against the model's 8.5 km" % height)

	# The temperature the coefficients are actually evaluated at, and the greenhouse-sized gap in it.
	var luminosity := SpacesimStarModel.luminosity(scene.star().content)
	var sun := scene.star()
	var earth_teq := SpacesimAtmosphereModel.equilibrium_temperature(
		earth.content, materials, luminosity, earth.position.distance_to(sun.position)
	)
	h.check(absf(earth_teq - 255.0) < 10.0,
		"Earth's equilibrium temperature is %.0f K against the published 255 K" % earth_teq)
	var venus := scene.body_by_id("planet:venus")
	var venus_teq := SpacesimAtmosphereModel.equilibrium_temperature(
		venus.content, materials, luminosity, venus.position.distance_to(sun.position)
	)
	h.check(absf(venus_teq - 229.0) < 10.0,
		"and Venus's is %.0f K against 232 K — the greenhouse is what is missing, not the geometry"
			% venus_teq)

	# **A named gap, not a silent one.** Every species the authored atmospheres use has a
	# cross-section except water vapour and hydrogen, and what that costs is written down here.
	var uncovered: Array[String] = []
	for body in scene.bodies:
		if body.content == null or body.content.atmosphere == null:
			continue
		if SpacesimAtmosphereModel.coverage(body.content.atmosphere, materials) < 1.0:
			uncovered.append(body.name)
	h.check(uncovered == ["Earth", "Titan"],
		"only Earth (water vapour) and Titan (hydrogen) are short of a cross-section: %s" % [uncovered])


func _test_hiding_bodies_hides_their_air(h, scene: SpacesimSystemScene) -> void:
	# `P` hides the bodies. Leaving the air behind would look like a bug rather than a debug key.
	# **Nothing draws a cloud deck any more** — the shell that did was removed for standing 76 km above
	# Earth and reading as the atmosphere from space. `SpacesimClouds` stays and is still read by
	# `bond_albedo`, which `test_surface.gd` guards: Earth's 0.302 against a measured 0.306.
	var meshes := scene.meshes()
	var air := 0
	for mesh in meshes:
		if mesh.name.ends_with("Air"):
			air += 1
	h.check(air > 0, "the debug key's mesh list includes the air shells (%d)" % air)
