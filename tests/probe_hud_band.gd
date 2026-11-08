extends SceneTree
## Slice 0 of the HUD strip — the four Godot facts the plan rests on, measured rather than assumed.
##
##     xvfb-run -a godot-double-mono --path . --script res://tests/probe_hud_band.gd
##
## `HUD Strip Plan` §3 asks four questions before any of the strip is built, because if any of them
## answers "no" the mechanism changes and the plan is wrong:
##
##   1. does a camera inside a `SubViewport` render the scene it renders in the root viewport?
##   2. does a `Compositor` on that camera still fire `POST_TRANSPARENT` with `RenderSceneBuffersRD`?
##      The exposure pass and the surface bake live there; if this is no, the feature stops.
##   3. does `RemoteTransform3D` carry a transform from the ship to a camera that is no longer its
##      child — and does it carry the *interpolated* one?
##   4. does a `SubViewport`'s own `scaling_3d_scale` actually scale its 3D buffer?
##
## ## How it answers
##
## The scene is two unshaded quads filling the frame, white on the left and black on the right, so a
## rendered frame has a hard vertical edge down the middle. From that edge:
##
##   * Q1 is "is the left pixel white and the right one black, in the SubViewport, as they are in the
##     root viewport";
##   * Q4 is the count of INTERMEDIATE grey pixels along that edge — a buffer rendered at a quarter
##     scale and bled back up has a wide soft edge, one rendered at full scale has a hard one. The count
##     going up when the scale goes down is the scale working;
##   * Q2 is a `CompositorEffect` that counts its own callbacks and records whether the render buffers
##     and the colour texture were reachable. It writes nothing.
##
## **Q3 is measured, not proved.** A remote transform copies *some* transform, and this rig can only
## compare the copied value against the ship's plain and interpolated ones on the frames it renders. If
## those two agree here the harness cannot tell them apart, and the answer is a flight — which is said
## in the report rather than glossed.
##
## The probe is reverted when it has run, per the project's rule. Its findings go to the vault and to
## the `godot` skill.

const VIEW := Vector2i(320, 180)
## 80 % of the root's height, the band the design asks for, at the same width.
const BAND := Vector2i(320, 144)
const SETTLE := 3

var _ship: Node3D
var _camera: Camera3D
var _band: SubViewport
var _counter: Counter

var _frames := 0
var _phase := 0

var _root_left := 0.0
var _root_right := 0.0
var _band_left := 0.0
var _band_right := 0.0
var _edge_at_full := 0
var _edge_at_quarter := 0
var _copied := Vector3.ZERO
var _plain := Vector3.ZERO
var _interpolated := Vector3.ZERO


## Counts its own callbacks and records what it could reach. **It writes nothing** — the question is
## whether the hook exists inside a SubViewport, not whether a pass can write a frame (that is
## `probe_compositor.gd`, and it already answered yes for the root viewport).
class Counter:
	extends CompositorEffect

	var callbacks := 0
	var buffers := false
	var color := false

	func _init() -> void:
		effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT

	func _render_callback(_type: int, render_data: RenderData) -> void:
		callbacks += 1
		var scene_buffers := render_data.get_render_scene_buffers()
		buffers = scene_buffers != null
		if scene_buffers != null:
			color = scene_buffers.get_color_texture().is_valid()


func _initialize() -> void:
	get_root().size = VIEW

	var world := Node3D.new()
	get_root().add_child(world)

	# **Black behind, white in front and on the left.** Both unshaded and drawn through a shader, so the
	# value is linear and known — an `albedo_color` is a `source_color` and gets sRGB-decoded on the way
	# in, which round-trips and hides what is being measured.
	_quad(world, Vector2(8.0, 8.0), Vector3(0.0, 0.0, -3.0), 0.0)
	_quad(world, Vector2(4.0, 2.0), Vector3(-1.0, 0.0, -2.0), 1.0)

	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 2.0
	_camera.position = Vector3(0.0, 0.0, 2.0)
	_camera.current = true

	# Identity exposure: `attributes = null` is NOT identity — it skips the factor that implements the
	# lux convention and lands ~95x out (the B1 finding, `probe_compositor.gd`).
	var attributes := CameraAttributesPhysical.new()
	attributes.auto_exposure_enabled = false
	attributes.exposure_multiplier = 1.0
	_camera.attributes = attributes

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.tonemap_white = 1.0
	environment.glow_enabled = false
	var holder := WorldEnvironment.new()
	holder.environment = environment
	world.add_child(holder)

	# The ship, and the camera as its child — the shape the game has today.
	_ship = Node3D.new()
	_ship.name = "Ship"
	get_root().add_child(_ship)
	_ship.add_child(_camera)


func _quad(parent: Node3D, size: Vector2, at: Vector3, value: float) -> void:
	var mesh := QuadMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = at
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)

	var shader := Shader.new()
	shader.code = (
		"shader_type spatial;\nrender_mode unshaded;\n"
		+ "void fragment() {\n\tALBEDO = vec3(%f);\n}\n" % value
	)
	var material := ShaderMaterial.new()
	material.shader = shader
	instance.material_override = material


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < SETTLE:
		return false
	match _phase:
		0:
			# Q1's control: the same world drawn in the ROOT viewport, camera a child of the ship.
			# **Sampled at 0.25 and 0.95 on purpose**: the white quad's edge lands at 0.78 of the root's
			# width and 0.725 of the band's, so a 0.75 sample straddles the two rigs and reports the
			# geometry rather than the viewport. The first run of this probe did exactly that.
			var image := get_root().get_texture().get_image()
			_root_left = _sample(image, 0.25)
			_root_right = _sample(image, 0.95)
			_build_band(image.get_height() > 0)
			_phase = 1
			_frames = 0
		1:
			# Q1 + Q2: the same world, same camera, now inside a band-sized SubViewport with a compositor.
			var image := _band.get_texture().get_image()
			_band_left = _sample(image, 0.25)
			_band_right = _sample(image, 0.95)
			_edge_at_full = _soft_edge(image)
			_band.scaling_3d_scale = 0.25
			_phase = 2
			_frames = 0
		2:
			# Q4: the same frame at a quarter of the 3D buffer's resolution.
			_edge_at_quarter = _soft_edge(_band.get_texture().get_image())
			_band.scaling_3d_scale = 1.0
			_remote()
			_phase = 3
			_frames = 0
		3:
			# Q3: the ship has moved and the remote transform has had frames to carry it.
			_copied = _camera.global_position
			_report()
			return true
	return false


## The band, as the game would build it: a SubViewport the size of the band, the camera moved into it
## with its global transform kept, and a compositor on the camera.
func _build_band(_unused: bool) -> void:
	_band = SubViewport.new()
	_band.name = "Band"
	_band.size = BAND
	_band.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_band.own_world_3d = false
	get_root().add_child(_band)

	var parent := _camera.get_parent()
	var kept := _camera.global_transform
	parent.remove_child(_camera)
	_band.add_child(_camera)
	_camera.global_transform = kept
	_camera.current = true

	_counter = Counter.new()
	var effects: Array[CompositorEffect] = [_counter]
	var compositor := Compositor.new()
	compositor.compositor_effects = effects
	_camera.compositor = compositor


## A `RemoteTransform3D` in the ship, pointing at a camera that is no longer its child. The path is
## written for this rig's tree: RemoteTransform -> Ship -> root, then down into the band.
func _remote() -> void:
	var remote := RemoteTransform3D.new()
	remote.name = "CameraMount"
	remote.remote_path = NodePath("../../Band/Camera")
	remote.use_global_coordinates = true
	remote.update_position = true
	remote.update_rotation = true
	remote.update_scale = false
	_ship.add_child(remote)

	_ship.position = Vector3(1.5, 0.5, 0.0)
	_plain = _ship.global_position
	_interpolated = _ship.get_global_transform_interpolated().origin


## A pixel on the left or right quarter of the frame, in sRGB.
func _sample(image: Image, fraction: float) -> float:
	var size := image.get_size()
	return image.get_pixel(int(size.x * fraction), size.y / 2).r


## How many pixels along the middle row are neither white nor black — the width of the soft edge. **A
## count of intermediate values, not of threshold crossings**: the question is how wide the transition
## is, and a threshold cannot say.
func _soft_edge(image: Image) -> int:
	var size := image.get_size()
	var count := 0
	for x in size.x:
		var value := image.get_pixel(x, size.y / 2).r
		if value > 0.02 and value < 0.98:
			count += 1
	return count


func _report() -> void:
	print("HUD BAND PROBE — the four facts the strip's plan rests on")
	print("HUD BAND PROBE: root viewport %dx%d, band %dx%d" % [VIEW.x, VIEW.y, BAND.x, BAND.y])
	print("HUD BAND PROBE:")
	print("HUD BAND PROBE: 1. DOES A CAMERA IN A SUBVIEWPORT RENDER?")
	print("HUD BAND PROBE:    root   left %.3f  right %.3f  (expect 1.000 / 0.000)" % [_root_left, _root_right])
	print("HUD BAND PROBE:    band   left %.3f  right %.3f" % [_band_left, _band_right])
	print("HUD BAND PROBE:    verdict: %s" % ("RENDERS" if absf(_band_left - 1.0) < 0.02 and _band_right < 0.02 else "DOES NOT RENDER"))
	print("HUD BAND PROBE:")
	print("HUD BAND PROBE: 2. DOES THE COMPOSITOR FIRE IN A SUBVIEWPORT?")
	print("HUD BAND PROBE:    callbacks %d, render buffers %s, colour texture %s"
		% [_counter.callbacks, _counter.buffers, _counter.color])
	print("HUD BAND PROBE:    verdict: %s" % ("POST_TRANSPARENT RUNS WITH BUFFERS" if _counter.callbacks > 0 and _counter.buffers and _counter.color else "NO — the exposure pass has no home here"))
	print("HUD BAND PROBE:")
	print("HUD BAND PROBE: 4. DOES A SUBVIEWPORT'S scaling_3d_scale SCALE ITS BUFFER?")
	print("HUD BAND PROBE:    soft-edge pixels at scale 1.00 %d, at 0.25 %d" % [_edge_at_full, _edge_at_quarter])
	print("HUD BAND PROBE:    verdict: %s" % ("SCALES" if _edge_at_quarter > _edge_at_full * 2 else "DOES NOT SCALE — the render-resolution knob needs another route"))
	print("HUD BAND PROBE:")
	print("HUD BAND PROBE: 3. DOES A REMOTE TRANSFORM CARRY IT?")
	print("HUD BAND PROBE:    ship plain %.3f,%.3f,%.3f  interpolated %.3f,%.3f,%.3f"
		% [_plain.x, _plain.y, _plain.z, _interpolated.x, _interpolated.y, _interpolated.z])
	print("HUD BAND PROBE:    camera arrived at %.3f,%.3f,%.3f" % [_copied.x, _copied.y, _copied.z])
	print("HUD BAND PROBE:    verdict: %s" % ("CARRIES (plain == interpolated in this rig, so interpolation is NOT settled here)" if _copied.distance_to(_plain) < 1.0e-4 else "DOES NOT CARRY"))
