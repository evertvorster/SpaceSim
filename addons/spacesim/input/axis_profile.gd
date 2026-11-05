class_name SpacesimAxisProfile
extends RefCounted
## **One physical axis, shaped**: where its travel ends, where it rests, and how much of the middle is
## nothing.
##
## A profile belongs to the **device's axis**, not to a binding — two bindings on one stick would
## otherwise have two deadbands for it. A binding on the axis inherits this.
##
## | | from | default | is |
## |---|---|---|---|
## | `low`, `high` | **calibration** | −1, +1 | the axis's real travel |
## | `centre` | the player | 0 | where the axis actually rests — **not** forced to the midpoint, because a worn stick's rest is not its middle |
## | `deadband` | the player | 0.15 | the **half-width** around `centre` that reads as nothing. A box spanning ±0.15 is *deadband 0.15* |
##
## Nothing consumes a profile yet: there are no axis bindings, so these numbers are stored, shown and
## calibrated but change no behaviour. That is worth knowing before looking for the effect of one.
##
## `low`/`high` rather than `min`/`max`: those are GDScript's own functions, and a member that shadows
## them is a trap waiting for the first line inside this file that wants the function.

const DEFAULT_DEADBAND := 0.15
## The smallest travel a calibration will accept. Below this the axis never spoke — an unplugged device,
## or a Save pressed before the stick was touched — and storing it would make a healthy control dead.
const MIN_CALIBRATED_TRAVEL := 0.2
## The four numbers, in the order they are written.
const SEPARATOR := ", "

var low := -1.0
var high := 1.0
var centre := 0.0
var deadband := DEFAULT_DEADBAND


## **What an axis is assumed to be before it is calibrated.** A trigger rests at zero and travels to +1,
## so its whole useful range is *above* its rest — showing it a `−1 … +1` bar puts half a line on screen
## that the device can never reach.
static func default_for(axis: String) -> SpacesimAxisProfile:
	var profile := SpacesimAxisProfile.new()
	if axis.begins_with("TRIGGER"):
		profile.low = 0.0
	return profile


## A profile from its stored text, or the defaults when the text is empty or unusable. **A bad number
## falls back to that field's default rather than the whole profile**, so one typo does not throw away
## a calibration.
static func from_text(text: String) -> SpacesimAxisProfile:
	var profile := SpacesimAxisProfile.new()
	var parts := text.split(",", false)
	if parts.size() >= 1 and parts[0].strip_edges().is_valid_float():
		profile.low = parts[0].strip_edges().to_float()
	if parts.size() >= 2 and parts[1].strip_edges().is_valid_float():
		profile.high = parts[1].strip_edges().to_float()
	if parts.size() >= 3 and parts[2].strip_edges().is_valid_float():
		profile.centre = parts[2].strip_edges().to_float()
	if parts.size() >= 4 and parts[3].strip_edges().is_valid_float():
		profile.deadband = parts[3].strip_edges().to_float()
	profile._clamp()
	return profile


func to_text() -> String:
	return SEPARATOR.join(
		PackedStringArray(
			[_num(low), _num(high), _num(centre), _num(deadband)]
		)
	)


func duplicate_profile() -> SpacesimAxisProfile:
	var copy := SpacesimAxisProfile.new()
	copy.low = low
	copy.high = high
	copy.centre = centre
	copy.deadband = deadband
	return copy


## **The axis value, made symmetric about its own rest and scaled by its own two spans.** The two spans
## are separate so an asymmetric axis (`−0.95 … +0.88`) maps onto `−1 … +1` exactly: its ends are the
## ends, and its centre is the centre.
func normalise(raw: float) -> float:
	var up := high - centre
	var down := centre - low
	if raw >= centre:
		return 0.0 if up <= 0.0 else (raw - centre) / up
	return 0.0 if down <= 0.0 else (raw - centre) / down


## The value after the deadband, rescaled so that **full deflection is still full deflection** — the
## division by `1 − deadband` is what keeps the response continuous at the edge of the band instead of
## stepping and losing the top of the range.
func shape(raw: float) -> float:
	var v := normalise(raw)
	if v == 0.0:
		return 0.0
	var outside := absf(v) - deadband
	if outside <= 0.0:
		return 0.0
	return signf(v) * minf(outside / maxf(1.0 - deadband, 0.001), 1.0)


## Whether the numbers make sense.
##
## **The centre is normalised to zero, so there is no "offset plus band must stay under 1" rule here** —
## whatever the centre is, the travel is measured either side of it and runs to ±1. What can be wrong is
## the travel itself (`low >= high`, which a bad calibration produces), a centre outside it, and a band of
## 1.0 or more, where nothing can ever be deflected. The centre sitting *at* an end is legal: a trigger
## rests at the bottom of its travel. A band of 0.9 is silly and *legal*: the bar shows the
## red box swallowing the line, and that is the feedback — refusing it would be hiding the picture behind
## a rule.
func is_sane() -> bool:
	if low >= high:
		return false
	# **The centre may be an end** — a trigger rests at the bottom of its travel, and a lever that rests
	# at one stop is a real device. What is refused is a centre outside the travel altogether.
	if centre < low or centre > high:
		return false
	if deadband < 0.0 or deadband >= 1.0:
		return false
	return true


## The measured travel taken from a calibration, keeping the typed centre and band.
func with_travel(measured_low: float, measured_high: float) -> SpacesimAxisProfile:
	var copy := duplicate_profile()
	copy.low = measured_low
	copy.high = measured_high
	copy._clamp()
	return copy


func _clamp() -> void:
	low = clampf(low, -1.0, 1.0)
	high = clampf(high, -1.0, 1.0)
	centre = clampf(centre, -1.0, 1.0)
	deadband = clampf(deadband, 0.0, 1.0)


static func _num(value: float) -> String:
	# Three decimals is what a stick is worth, and it keeps the file readable.
	return "%.3f" % value
