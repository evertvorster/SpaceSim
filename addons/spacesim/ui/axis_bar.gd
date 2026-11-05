class_name SpacesimAxisBar
extends Control
## **One axis as a line**: its travel, its deadband boxed in red, and where it is right now.
##
## The line is the **profile's travel**, not `−1 … +1`: a trigger that runs `0 … +1` gets a line it can
## fill, and the box and the dot are in the same coordinates as the travel they belong to. Drawing the
## box from the raw centre and the dot from the shaped value — which this did — puts the two in different
## spaces, so a centred axis showed a dot that was not in the middle of its own deadband.
##
## A picture rather than a number because the two things a player is judging here are *where the deadband
## sits* and *how much of the travel is left outside it* — and neither reads from a value.
##
## It draws and nothing else: the caller sets the three numbers and the control repaints. The deadband is
## drawn as **`centre ± deadband`**, which is why the profile's number is a half-width.

const AxisProfile := preload("res://addons/spacesim/input/axis_profile.gd")

const LINE_COLOR := Color(1.0, 1.0, 1.0, 0.35)
const CENTRE_COLOR := Color(1.0, 1.0, 1.0, 0.55)
const DEADBAND_COLOR := Color(1.0, 0.3, 0.25, 0.9)
const DOT_COLOR := Color(1.0, 0.9, 0.3)

const HEIGHT := 26.0
const DOT_RADIUS := 4.0

## Where the axis is, **raw** — the same units as the travel it is drawn against.
var value := 0.0
## The travel, the rest and the band being drawn. Defaults so the control is valid before it is fed.
var profile := AxisProfile.new()


func _init() -> void:
	custom_minimum_size = Vector2(180.0, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


## The reading and the profile, then one repaint — called every frame by the screen that owns it.
func set_state(raw_value: float, p_profile: SpacesimAxisProfile) -> void:
	var reshaped := (
		not is_equal_approx(p_profile.low, profile.low)
		or not is_equal_approx(p_profile.high, profile.high)
		or not is_equal_approx(p_profile.centre, profile.centre)
		or not is_equal_approx(p_profile.deadband, profile.deadband)
	)
	var moved := not is_equal_approx(raw_value, value)
	value = raw_value
	profile = p_profile
	if moved or reshaped:
		queue_redraw()


func _draw() -> void:
	var mid := size.y * 0.5
	draw_line(Vector2(0.0, mid), Vector2(size.x, mid), LINE_COLOR, 1.0)

	# **The band is the profile's, converted into travel units**: `deadband` is a fraction of the
	# normalised deviation, and each side has its own span, so an asymmetric axis gets a box that means
	# the same thing on both sides.
	var band_from := _x(profile.centre - profile.deadband * (profile.centre - profile.low))
	var band_to := _x(profile.centre + profile.deadband * (profile.high - profile.centre))
	draw_rect(
		Rect2(Vector2(band_from, mid - 8.0), Vector2(maxf(band_to - band_from, 1.0), 16.0)),
		DEADBAND_COLOR,
		false,
		1.5
	)

	# Where it rests — **the dot lands in the middle of the box** the moment Centred has been pressed,
	# which is the whole of what that button does.
	draw_line(
		Vector2(_x(profile.centre), mid - 9.0), Vector2(_x(profile.centre), mid + 9.0), CENTRE_COLOR, 1.0
	)

	draw_circle(Vector2(_x(clampf(value, profile.low, profile.high)), mid), DOT_RADIUS, DOT_COLOR)


## Across the width, in the travel's own units.
func _x(v: float) -> float:
	var span := profile.high - profile.low
	if span <= 0.0:
		return 0.0
	return (v - profile.low) / span * size.x
