extends RefCounted
## **The band the 3D is drawn in, and the strip under it** — `The HUD Strip` §1.
##
## Headless, so what is checked here is the *arrangement*: which rect the picture occupies, which rect the
## strip occupies, that the two tile with nothing between them, and that the viewport underneath is the
## size and scale it was handed. **No pixel of the picture is claimed** — whether it looks right is a
## flight, and this suite cannot see a frame.

const Band := preload("res://addons/spacesim/ui/band.gd")


func run(h, root: Node) -> void:
	print("  the HUD band")
	_test_the_arrangement(h, root)
	_test_a_cockpit_has_no_strip(h, root)
	_test_the_camera_moves(h, root)


## The design's own numbers: a 1920 x 1080 canvas, a fifth for the strip, so the picture is 1920 x 864.
const CANVAS := Rect2(0.0, 0.0, 1920.0, 1080.0)
const PICTURE := Rect2(0.0, 0.0, 1920.0, 864.0)
const STRIP := Rect2(0.0, 864.0, 1920.0, 216.0)


func _test_the_arrangement(h, root: Node) -> void:
	var band: Control = Band.new()
	root.add_child(band)
	band.fit(PICTURE, STRIP, Vector2i(1920, 864), 0.75)

	h.check(band.picture_rect() == PICTURE, "the picture takes the band's rect (%s)" % str(band.picture_rect()))
	h.check(band.strip_rect() == STRIP, "and the strip sits at the bottom (%s)" % str(band.strip_rect()))
	h.check(
		band.picture_rect().end.y == band.strip_rect().position.y,
		"the two meet with no background showing between them (%s against %s)"
			% [str(band.picture_rect().end.y), str(band.strip_rect().position.y)]
	)

	# **The strip is painted, not merely empty.** The readouts are text on it, and the root viewport's clear
	# colour is not something to rely on once anything else draws there.
	var paint := band.get_node_or_null("Strip") as ColorRect
	h.check(paint != null, "the strip is a painted rect, not a gap in the layout")
	h.check(paint != null and paint.color == Color.BLACK, "and it is black (%s)" % (str(paint.color) if paint else "none"))
	h.check(
		paint != null and paint.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"and it takes no mouse events, or the view's click-to-capture stops working under it"
	)

	# **The viewport is the band in WINDOW pixels**, and the render scale is applied to that — which is what
	# keeps `video.render_resolution` describing the whole window rather than the band.
	h.check(
		band.viewport().size == Vector2i(1920, 864),
		"the viewport under the picture is the band in window pixels (%s)" % str(band.viewport().size)
	)
	h.check_near(
		band.viewport().scaling_3d_scale,
		0.75,
		"and is drawn at the render scale it was handed",
		0.0001
	)
	# **Every frame**, because the texture is worn by a `TextureRect` and nothing else tells the engine the
	# contents are wanted — the default is `UPDATE_WHEN_VISIBLE`.
	h.check(
		band.viewport().render_target_update_mode == SubViewport.UPDATE_ALWAYS,
		"and updates every frame rather than when it thinks it is visible"
	)

	# A window dragged almost shut cannot produce a viewport, so the floor is applied rather than obeyed.
	band.fit(PICTURE, STRIP, Vector2i(1, 1), 1.0)
	h.check(
		band.viewport().size == Vector2i(2, 2),
		"a viewport smaller than the engine's floor is held at it (%s)" % str(band.viewport().size)
	)
	band.free()


## **Zero is a real strip height**: a cockpit has no strip at all, and the 3D fills the screen.
func _test_a_cockpit_has_no_strip(h, root: Node) -> void:
	var band: Control = Band.new()
	root.add_child(band)
	band.fit(CANVAS, Rect2(0.0, 1080.0, 1920.0, 0.0), Vector2i(1920, 1080), 1.0)

	h.check(band.picture_rect() == CANVAS, "with no strip the picture is the whole canvas (%s)" % str(band.picture_rect()))
	h.check(band.strip_rect().size.y == 0.0, "and the strip has no height (%s)" % str(band.strip_rect().size.y))
	band.free()


## **The camera has to move into the viewport**, because a `Camera3D` renders into the viewport that
## contains it — and it must land where it already was, or the first frame of the band is a jump.
func _test_the_camera_moves(h, root: Node) -> void:
	var band: Control = Band.new()
	root.add_child(band)
	band.fit(PICTURE, STRIP, Vector2i(1920, 864), 1.0)

	var ship := Node3D.new()
	root.add_child(ship)
	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.position = Vector3(0.0, 5.0, 32.0)
	ship.add_child(camera)
	var kept := camera.global_transform

	band.take(camera)

	h.check(
		camera.get_parent() == band.viewport(),
		"the camera ends up inside the band's viewport (%s)" % str(camera.get_parent())
	)
	h.check(
		camera.get_parent() != ship,
		"and is no longer a child of the ship, which is why the mount drives it"
	)
	h.check(
		camera.global_transform.origin.is_equal_approx(kept.origin),
		"and keeps its place, so the first frame is the one it would have drawn (%s against %s)"
			% [str(camera.global_transform.origin), str(kept.origin)]
	)
	# **The camera KEEPS the engine's interpolation.** It used to be the ship's child and the engine smoothed
	# it between ticks; it is placed by `_sync_camera` in the physics tick so the engine can go on doing
	# exactly that. Turning interpolation off here — handing the render camera an already-smoothed value
	# once per drawn frame — makes it lag the scene by up to a tick, which showed as the air flickering dark
	# over the sea while turning (Evert, 2026-11-07: *"a deal breaker"*).
	h.check(
		camera.physics_interpolation_mode != Node.PHYSICS_INTERPOLATION_MODE_OFF,
		"and keeps the engine's own interpolation, so the render camera is not a tick behind"
	)

	# Taking the same camera twice is a no-op rather than a second reparent.
	band.take(camera)
	h.check(camera.get_parent() == band.viewport(), "taking it again leaves it exactly where it is")

	band.free()
