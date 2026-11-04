class_name SpacesimAxisBar
extends Control
## **One axis as a line**: its travel, its deadband boxed in red, and where it is right now.
##
## A picture rather than a number because the two things a player is judging here are *where the deadband
## sits* and *how much of the travel is left outside it* — and neither reads from a value.
##
## It draws and nothing else: the caller sets the three numbers and the control repaints. The deadband is
## drawn as **`centre ± deadband`**, which is why the profile's number is a half-width.

const LINE_COLOR := Color(1.0, 1.0, 1.0, 0.35)
const CENTRE_COLOR := Color(1.0, 1.0, 1.0, 0.55)
const DEADBAND_COLOR := Color(1.0, 0.3, 0.25, 0.9)
const DOT_COLOR := Color(1.0, 0.9, 0.3)

const HEIGHT := 26.0
const DOT_RADIUS := 4.0

## Where the axis is, in the normalised range. Clamped for drawing: a value outside ±1 has nowhere to go
## on a line that is exactly the travel.
var value := 0.0
var centre := 0.0
var deadband := 0.15


func _init() -> void:
	custom_minimum_size = Vector2(180.0, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


## The three numbers at once, then one repaint — called every frame by the screen that owns it.
func set_state(raw_value: float, p_centre: float, p_deadband: float) -> void:
	var moved := not is_equal_approx(raw_value, value)
	var reshaped := not is_equal_approx(p_centre, centre) or not is_equal_approx(p_deadband, deadband)
	value = raw_value
	centre = p_centre
	deadband = p_deadband
	if moved or reshaped:
		queue_redraw()


func _draw() -> void:
	var mid := size.y * 0.5
	var left := 0.0
	var right := size.x
	draw_line(Vector2(left, mid), Vector2(right, mid), LINE_COLOR, 1.0)

	# The deadband, as the box the number means.
	var band_low := _x(clampf(centre - deadband, -1.0, 1.0))
	var band_high := _x(clampf(centre + deadband, -1.0, 1.0))
	draw_rect(
		Rect2(Vector2(band_low, mid - 8.0), Vector2(maxf(band_high - band_low, 1.0), 16.0)),
		DEADBAND_COLOR,
		false,
		1.5
	)

	# Where it rests, so the band can be seen to be centred on something.
	draw_line(Vector2(_x(centre), mid - 9.0), Vector2(_x(centre), mid + 9.0), CENTRE_COLOR, 1.0)

	draw_circle(Vector2(_x(clampf(value, -1.0, 1.0)), mid), DOT_RADIUS, DOT_COLOR)


## −1 … +1 across the width.
func _x(v: float) -> float:
	return (v + 1.0) * 0.5 * size.x
