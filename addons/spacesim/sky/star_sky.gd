class_name SpacesimStarSky
extends RefCounted
## The background sky: the real star field, drawn from the catalogue.
##
## It owns the `Sky` and its material, and it is the only thing that knows the host plumbing the
## shader needs. Everything it hands the shader is either the catalogue itself or a property of the
## camera it was given — nothing is hand-tuned per system, so there is no per-location constant that
## could drift out of step with the physics.
##
## **Why a `Sky` and not a sphere mesh.** There is no mesh to keep centred on the camera, an infinite
## background cannot be clipped by the far plane, and `EYEDIR` is already a world-space direction —
## verified by rolling the camera, not assumed — so the `CAMERA_POSITION_WORLD - centre` subtraction
## that `body_atmosphere` needs, against a GLSL float's ~7 significant digits, cannot arise here.
##
## **The camera basis is passed in rather than taken from a built-in.** The shader computes where a
## star lands on screen and where the pixel is on screen, and those two MUST be computed the same
## way. Feeding both from the same basis is the only way to guarantee that; it is also what lets a
## test check the arithmetic without a GPU.

const SHADER := preload("res://addons/spacesim/render/sky_stars.gdshader")

## The catalogue is Sol calibration data — see `sky/PROVENANCE.md`. The generator for other systems
## is the next stage; when it exists, a system will name its own sky source and this constant goes.
const CATALOGUE_PATH := "res://addons/spacesim/sky/hyg_v44.stars"

var material: ShaderMaterial
var catalogue: SpacesimStarCatalogue
## The Sky this owns, for the Environment. Null when the catalogue could not be loaded, in which case
## the caller should keep whatever background it had.
var sky: Sky


## Returns false if the catalogue is missing or malformed, so the caller can fall back rather than
## render a black sky and let it read as a bug.
func create() -> bool:
	catalogue = SpacesimStarCatalogue.new()
	if not catalogue.load_file(CATALOGUE_PATH):
		catalogue = null
		return false

	material = ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("u_stars", catalogue.stars_texture)
	material.set_shader_parameter("u_star_colour", catalogue.colour_texture)
	material.set_shader_parameter("u_cells", catalogue.cells_texture)
	material.set_shader_parameter("u_stars_size", catalogue.star_image_size())
	material.set_shader_parameter("u_colour_size", catalogue.colour_image_size())
	material.set_shader_parameter("u_cells_size", catalogue.cell_image_size())
	material.set_shader_parameter("u_grid", catalogue.grid)

	sky = Sky.new()
	sky.sky_material = material
	return true


## The depth tunable. Changing it is a uniform write, not a rebuild: the catalogue holds the whole
## sky and this only decides how much of it is shown, so sweeping it cannot reshuffle the field.
func set_limit_magnitude(mag: float) -> void:
	if material != null:
		material.set_shader_parameter("u_limit_mag", mag)


## The hand tuner on the field's brightness, as a plain multiplier.
##
## **This is a calibration knob, not physics.** The brightness is derived from measured illuminance
## and this scales it; if the right value turns out to be far from 1, that is a fact about the model
## worth chasing, not a constant to keep. Its setting is in DECADES (`sky.star_gain`), so a slider in
## the settings screen can cross orders of magnitude — which is the only way a manual control is
## useful when the level is uncertain by that much.
func set_gain(gain: float) -> void:
	if material != null:
		material.set_shader_parameter("u_gain", gain)


## Point the sky at a camera.
##
## Only the **camera basis, the field and the aspect** are handed over. The pixel count is deliberately
## not: the shader measures its own pixel size from screen-space derivatives, which is exact at whatever
## resolution the 3D is drawn at, so there is no host number for the two to disagree about. See
## `sky_stars.gdshader` for what that replaced and why.
func update(camera: Camera3D) -> void:
	if material == null or camera == null:
		return
	var viewport := camera.get_viewport()
	if viewport == null:
		return
	# The **render target's** size in pixels — `viewport.size`, and not `get_visible_rect()`, which is
	# the CANVAS rect in screen coordinates. The two agree under the default `expand` aspect and part
	# company the moment the aspect is kept, where the canvas is letterboxed over a full-width 3D
	# buffer; the camera's horizontal field follows the buffer.
	var size := Vector2(viewport.size)
	if size.x <= 0.0 or size.y <= 0.0:
		return

	# Typed explicitly: `get_global_transform_interpolated()` has no inferable return type, so `:=`
	# on it is the `INFERENCE_ON_VARIANT` error.
	var basis: Basis = camera.get_global_transform_interpolated().basis
	material.set_shader_parameter("u_right", basis.x)
	material.set_shader_parameter("u_up", basis.y)
	material.set_shader_parameter("u_fwd", -basis.z)

	# Godot's `fov` is the VERTICAL one (keep height), so the horizontal tangent follows the aspect.
	var tan_y := tan(deg_to_rad(camera.fov * 0.5))
	material.set_shader_parameter("u_tan_half", Vector2(tan_y * size.x / size.y, tan_y))


## The sky's own light, in lux — the sum of every star at or above the depth limit.
##
## This is the number the light floor comes from: in empty space it is the only light there is, so an
## exposure set for it IS the dark-adapted eye. Computed from the catalogue rather than authored, so
## it cannot drift from the sky it describes. The whole naked-eye sky comes to ~2e-4 lux, which is
## the measured figure the calibration was checked against.
func illuminance(limit_magnitude: float = 6.5) -> float:
	if catalogue == null:
		return 0.0
	# ponytail: a full scan of 119,613 stars, and it runs once — not per frame, and not per pixel.
	# If it ever needs to be live, the catalogue's cell table is already the index for it.
	var total := 0.0
	var image := catalogue.stars_texture.get_image()
	var width := image.get_width()
	for i in catalogue.count:
		var mag := image.get_pixel(i % width, i / width).a
		if mag <= limit_magnitude:
			total += 2.54e-6 * pow(10.0, -0.4 * mag)
	return total
