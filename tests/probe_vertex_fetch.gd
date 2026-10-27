extends SceneTree
## **Does a vertex-stage sampler return the map's data, or silently zero?**
##
## B1 of the displacement investigation proved that a `spatial` shader *compiles* with `textureLod()` in `vertex()`.
## It did not prove the fetch returns anything: an unbound sampler reads zero, and a displacement of `0 × height` is
## the old picture exactly — which is the one failure a diff can see and a suite cannot.
##
## So this renders one sphere twice through a deliberately unshaded material, with the height map's own value driving
## both the displacement and the colour, and counts how many pixels differ:
##
##   xvfb-run -a godot-double-mono --path . --script res://tests/probe_vertex_fetch.gd
##
## A silent zero gives 0 pixels; a working fetch gives thousands.

const SIZE := Vector2i(256, 256)
const WIDTH := 256
const HEIGHT := 128

const SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D heights : filter_linear, repeat_disable, hint_default_black;
uniform float strength = 0.0;
varying float sampled;

void vertex() {
	vec3 unit = normalize(VERTEX);
	// The same mapping the surface shaders use, and an explicit lod because a vertex stage has no derivatives.
	vec2 uv = vec2(0.5 + atan(unit.z, unit.x) / 6.283185307179586,
		0.5 - asin(clamp(unit.y, -1.0, 1.0)) / 3.141592653589793);
	float h = textureLod(heights, uv, 0.0).r;
	sampled = h;
	VERTEX = unit * (1.0 + h * strength);
}

void fragment() {
	// **The colour is the sampled value**, so a fetch that returns zero is black and a working one is a field.
	ALBEDO = vec3(0.5 + sampled * 2.0);
}
"""


func _init() -> void:
	var gpu := SpacesimSurfaceGpu.new()
	if not gpu.open():
		print("no rendering device: ", gpu.error())
		quit(1)
		return
	var plan := SpacesimSurfaceField.plan("planet:earth", 6.371e6)
	var map := gpu.bake(plan, WIDTH, HEIGHT)
	gpu.close()
	if map == null:
		print("bake failed")
		quit(1)
		return
	var texture := ImageTexture.create_from_image(map)

	var viewport := SubViewport.new()
	viewport.size = SIZE
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)

	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 0.0, 3.0)
	camera.fov = 50.0
	viewport.add_child(camera)

	var sphere := MeshInstance3D.new()
	sphere.mesh = SphereMesh.new()
	sphere.mesh.radial_segments = 64
	sphere.mesh.rings = 32
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SHADER
	material.shader = shader
	material.set_shader_parameter("heights", texture)
	sphere.material_override = material
	viewport.add_child(sphere)

	# **Two frames at each setting**: the first can land before the map's texture is uploaded.
	var flat := await _render(viewport, material, 0.0)
	var displaced := await _render(viewport, material, 400.0)

	var differing := 0
	var biggest := 0.0
	var brightest := 0.0
	for y in SIZE.y:
		for x in SIZE.x:
			var a := flat.get_pixel(x, y)
			var b := displaced.get_pixel(x, y)
			var delta := absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
			if delta > 0.01:
				differing += 1
			biggest = maxf(biggest, delta)
			brightest = maxf(brightest, b.r)
	print("=== vertex-stage fetch")
	print("    brightest texel in the undisplaced render: %.3f" % brightest)
	print("    pixels differing between strength 0 and 400: %d of %d (worst delta %.3f)" % [
		differing, SIZE.x * SIZE.y, biggest])
	if brightest <= 0.02:
		print("    FAIL: the fragment stage saw a sampled value of zero — the sphere is uniform, so this run")
		print("          cannot distinguish a broken fetch from a working one. The vertex fetch is unproven.")
	elif differing > 200:
		print("    OK: the vertex stage's fetch drives both the geometry and the colour, and the sphere deforms.")
	else:
		print("    FAIL: the fetch returned data to the fragment stage but the vertices did not move.")
	quit()


func _render(viewport: SubViewport, material: ShaderMaterial, strength: float) -> Image:
	material.set_shader_parameter("strength", strength)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()
