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
	# **And the same map as a `Texture2DRD`**, which is what the game samples once a rung lands: the refined map is an
	# RD texture, and a vertex stage that cannot bind it would read garbage rather than zero.
	var rd := RenderingServer.get_rendering_device()
	var rd_texture := RID()
	if rd != null:
		var format := RDTextureFormat.new()
		format.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
		format.width = WIDTH
		format.height = HEIGHT
		format.depth = 1
		format.array_layers = 1
		format.mipmaps = 1
		format.usage_bits = (RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT)
		rd_texture = rd.texture_create(format, RDTextureView.new())
		# **The bake already comes back as `R16F`**, so its own bytes are the upload — a `PackedFloat32Array` is
		# 32-bit and the device rejects it, which silently leaves the texture zeroed and makes the whole test read
		# `0.735` (the sRGB of zero) while looking like a result.
		var bytes := map.get_data()
		print("    RD upload: %d bytes for %dx%d R16F (%d expected)" % [
			bytes.size(), WIDTH, HEIGHT, WIDTH * HEIGHT * 2])
		rd.texture_update(rd_texture, 0, bytes)

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

	# **The game's own case**: the refined map is a `Texture2DRD`. Same two renders, same counts.
	if rd_texture.is_valid():
		var rd_material := ShaderMaterial.new()
		var rd_shader := Shader.new()
		rd_shader.code = SHADER
		rd_material.shader = rd_shader
		var wrapper := Texture2DRD.new()
		wrapper.texture_rd_rid = rd_texture
		rd_material.set_shader_parameter("heights", wrapper)
		sphere.material_override = rd_material
		var rd_flat := await _render(viewport, rd_material, 0.0)
		var rd_displaced := await _render(viewport, rd_material, 400.0)
		var rd_differing := 0
		var rd_brightest := 0.0
		for y in SIZE.y:
			for x in SIZE.x:
				var a := rd_flat.get_pixel(x, y)
				var b := rd_displaced.get_pixel(x, y)
				if absf(a.r - b.r) > 0.01:
					rd_differing += 1
				rd_brightest = maxf(rd_brightest, a.r)
		print("")
		print("=== the same, through a Texture2DRD (what the game samples once a rung lands)")
		print("    brightest: %.3f   pixels differing: %d of %d" % [
			rd_brightest, rd_differing, SIZE.x * SIZE.y])
		if rd_brightest <= 0.02:
			print("    ** FAIL: the vertex stage reads nothing from an RD texture. In the game that is a zero")
			print("       displacement (harmless) — unless it reads garbage instead, which would explain a vanished")
			print("       surface: NaN in VERTEX removes every triangle.")
		elif rd_differing < 200:
			print("    ** FAIL: the RD texture reaches the fragment stage but does not move the vertices.")
		else:
			print("    OK: the RD texture drives the geometry as well as the image texture.")
		if rd_texture.is_valid():
			rd.free_rid(rd_texture)
	else:
		print("")
		print("    (no rendering device for the RD half)")
	quit()


func _render(viewport: SubViewport, material: ShaderMaterial, strength: float) -> Image:
	material.set_shader_parameter("strength", strength)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()
