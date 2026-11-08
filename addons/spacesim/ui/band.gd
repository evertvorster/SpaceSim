class_name SpacesimBand
extends Control
## **The band the 3D is drawn in, and the strip under it** — `The HUD Strip` §1, `HUD Strip Plan` §3.
##
## The picture is not the whole screen any more: the bottom fifth is an opaque black strip holding the
## readouts, and the 3D gets everything above it. **That is a band, not a bar over a picture** — a
## picture drawn full-screen with black painted over the bottom fifth would lose the bottom fifth of the
## vertical field, because the camera's vertical FOV maps to the whole viewport. So the 3D is rendered
## into a [SubViewport] sized to the band and shown in the band's rect, and the camera is *moved into
## it*: a [Camera3D] renders into the viewport that contains it, and nothing else makes it draw there.
##
## ## What this node is and is not
##
## It owns the three nodes — the `SubViewport`, the `TextureRect` that shows it, the `ColorRect` that is
## the strip — and the arithmetic that places them. It does **not** own the numbers: the band and the
## strip come from [method SpacesimDisplay.band_rect] and the pixel size from
## [method SpacesimDisplay.band_pixels], so the camera, the markers and this cannot disagree about where
## the picture is.
##
## **Two sizes, and they are different on purpose.** The rects are in canvas units — what a `Control` is
## laid out in — and the `SubViewport` is sized in *window* pixels, because `canvas_items` stretch lays
## the UI out in a canvas that a larger window then scales. Sizing a viewport from the canvas rect
## renders the 3D at canvas resolution and bleeds it up, which is a sharpness regression that shows up
## only above the canvas size.
##
## ## The camera
##
## [method take] moves a camera into the viewport, keeping its global transform. **Whoever takes it also
## has to drive it** — a camera outside the ship no longer inherits the ship's transform, and the ship is
## the thing that moves. `main.gd` does that from the ship's interpolated transform, which is the same
## reading the frame already makes for the eye position.

## The strip is painted rather than merely left empty. The root viewport's clear colour is not guaranteed
## black once anything else is drawn there, and the readouts are text: they need a defined background.
const STRIP_COLOR := Color.BLACK

## A `SubViewport` smaller than this in either axis draws nothing at all (class reference). A window
## dragged almost shut is the case that reaches it.
const MIN_VIEWPORT := 2

var _viewport: SubViewport
var _image: TextureRect
var _strip: ColorRect

## The camera this band shows, once one has been taken.
var _camera: Camera3D


func _ready() -> void:
	name = "Band"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_viewport = SubViewport.new()
	_viewport.name = "Picture"
	# **Every frame, not once.** The default is `UPDATE_WHEN_VISIBLE`, which would be right for a viewport
	# drawn into a `SubViewportContainer` and is wrong for one whose texture is assigned to a
	# `TextureRect` — nothing then tells the engine the contents are wanted.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	_image = TextureRect.new()
	_image.name = "Picture"
	_image.texture = _viewport.get_texture()
	# The rect is the authority on the size, so the texture may be any size at all.
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_SCALE
	_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_image)

	_strip = ColorRect.new()
	_strip.name = "Strip"
	_strip.color = STRIP_COLOR
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_strip)


## **Put a camera into the band.** A `Camera3D` renders into the viewport that contains it, so this is
## what makes the picture come out at the band's size and aspect rather than the window's.
##
## The global transform is kept, so the first frame after the move is the frame that would have been
## drawn without it — a camera that jumped would read as a bug in the band rather than in the move.
func take(camera: Camera3D) -> void:
	if camera == null or camera == _camera:
		return
	camera.reparent(_viewport, true)
	# **The camera keeps its own physics interpolation**, and that is load-bearing: the engine smooths it
	# between ticks exactly as it smoothed it while it was the ship's child. What drives it is
	# `main.gd::_sync_camera`, in the physics tick. Turning interpolation off and handing it an
	# already-smoothed transform each drawn frame takes the smoothing off the RENDER camera, and it then
	# lags the scene by up to a tick — which reads as the air flickering over the sea while you turn.
	_camera = camera


## Place and size both halves, and the viewport underneath them.
##
## `band` and `strip` are in canvas units; `pixels` is the band in window pixels and `scale` is the
## render resolution as a fraction of the window. **They tile exactly** — `SpacesimDisplay` gives the band
## the remainder — so the picture never shows a seam of background above the strip.
func fit(band: Rect2, strip: Rect2, pixels: Vector2i, scale: float) -> void:
	if _viewport == null:
		return
	_image.position = band.position
	_image.size = band.size
	_strip.position = strip.position
	_strip.size = strip.size
	_viewport.size = Vector2i(
		maxi(pixels.x, MIN_VIEWPORT),
		maxi(pixels.y, MIN_VIEWPORT)
	)
	_viewport.scaling_3d_scale = scale


## The `SubViewport` the picture is drawn into — for a test, and for anything that needs the render size.
func viewport() -> SubViewport:
	return _viewport


## The rect the picture occupies, in canvas units, as it was last fitted.
func picture_rect() -> Rect2:
	return Rect2(_image.position, _image.size) if _image != null else Rect2()


## The rect the strip occupies, in canvas units, as it was last fitted.
func strip_rect() -> Rect2:
	return Rect2(_strip.position, _strip.size) if _strip != null else Rect2()
