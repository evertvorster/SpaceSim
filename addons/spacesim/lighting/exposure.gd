class_name SpacesimExposure
extends RefCounted
## How bright the camera treats the scene.
##
## **Computed from the physics, not metered from the image.** Godot's auto-exposure averages the
## frame and drives that average toward middle grey, and it has no metering mode — probed on 4.7.2,
## the API is `auto_exposure_enabled`, `_scale`, `_speed` and an EV clamp, and nothing else. So on a
## frame that is mostly empty space with one lit body in it, it has exactly one way to reach its
## target: raise exposure until that body is white. Which is what it did.
##
## We do not have to guess, because the illuminance at the observer is already derived. The exposure
## that puts a lit body at middle grey is therefore arithmetic — and unlike image-based metering it is
## deterministic, it cannot be fooled by an empty frame, it does not pump, and it can be tested
## headlessly.
##
## On the emitter: the star is a *source*, not a reflector. It cannot be brought into range without
## making everything else black, so it is allowed to clip and `glow_*` handles how that reads. Nothing
## here tries to expose for it.

## Godot's own reference for a directional light: `light_intensity_lux` defaults to 100,000, so a
## multiplier of 1.0 is "the light Godot considers normal". Everything else is measured from there,
## which is why this is 100,000 rather than the measured 128,000 lux of daylight — the difference is
## a fraction of a stop and one fewer constant to explain.
const REFERENCE_LUX := 100000.0

## How far we will correct. It has to be **above `DARK_ADAPTED_MULTIPLIER`**, or the cap would
## silence the sky it exists to show — 4096 did exactly that, thirty years of stops short.
const MAX_MULTIPLIER := 100000.0

## How fast exposure follows a change. Slow on purpose: what you notice about a night side is that it
## stays dark, and a hard cut when flying between planets looks like a bug.
const ADAPTATION_RATE := 0.6

## A clear blue sky's own **luminance**, in lux per steradian (the same number as cd/m²). Schlyter's
## "full daylight, not direct sun" is 10,000-25,000 lux *on a horizontal surface*, and a uniform sky of
## luminance L gives pi*L on the ground — so L = 25,000/pi = 8,000, which is the order a real clear sky
## measures.
##
## It matters because **you do not have to look at the Sun to lose the stars.** Stand in a lit
## atmosphere with the Sun behind you and the sky in front of you is still daylight.
const DAYLIGHT_SKY_LUMINANCE := 8000.0

## The solid angle below which a source is a **POINT** and does not set adaptation: about 9.6e-6 sr,
## a disk 0.2 degrees across.
##
## That is the eye's own pooling scale — the vault's note is that a dark-adapted eye sums over roughly
## 0.2 degrees — and it is the whole reason a star field behaves differently from a planet. Below it a
## source cannot be resolved as a surface, so there is no surface brightness for the eye to adapt to;
## it can only dazzle.
##
## **It is what makes "looking at the Sun" mean different things in different places**, which was the
## bug it fixes. The Sun's disk is 0.53 degrees at 1 au — five times the pooling scale, so it is a sky
## you adapt to and the stars go. At Saturn it is 0.053 degrees, ten times *smaller* than the scale, so
## it is a glare source and no more, and the sky must be left alone. Evert reported exactly that on
## 2026-10-14, and it is why the exposure was anchored to the wrong thing.
const MIN_SOLID_ANGLE := 9.6e-6

## The multiplier a fully dark-adapted eye corresponds to — the exposure's resting state when there
## is nothing bright in front of it.
##
## **`target_multiplier()` above cannot serve for a star field, and the reason is worth stating.**
## That rule exposes a lit *surface*, which has a mean luminance the eye adapts to. A star field has
## no mean luminance — it is point sources on black — so there is nothing there to adapt to. What an
## observer has instead is a RANGE, and dark adaptation opens that range onto the sky. So the anchor
## is the observer, not the scene: **the multiplier that puts the brightest star at the top of the
## display**, which is what a fully dark-adapted eye sees.
##
## Derived, at the reference the sky is judged at (1920x1080, a 37.8 degree field):
##     Sirius, V = -1.44               2.54e-6 * 10^0.576        = 9.568e-6 lux
##     one pixel's solid angle          4 * tan18.9 * tan18.9*1.778 / (1920*1080) = 4.020e-7 sr
##     its radiance                     9.568e-6 / 4.020e-7      = 23.80 lux/sr
##     in Godot's units                 23.80 / (100000/pi)       = 7.477e-4
##     to the white point               AGX white is 6.0 -> 6.0 / 7.477e-4 = 8025
##
## **The sky's brightness follows the resolution and the field; this does not.** Evert chose that on
## 2026-10-14: a higher resolution concentrates the same flux into a smaller angle and the stars get
## brighter, which is what a larger aperture does to a point source.
##
## The field of view the value below was derived at. It is REFERENCE ONLY — the multiplier that is
## actually used comes from `dark_adapted_multiplier(fov)`, because a star's rendered radiance goes as
## `(height / tan(half vfov))^2` and a constant derived at one field is wrong at every other.
const DARK_ADAPTED_REFERENCE_FOV := 37.8

## **SUSPECT, and the value is knowingly wrong.** Evert measured the correction needed at
## `sky.star_gain` 2.1, which is 10^2.1 = **126x** — so the derivation below is 126 times off
## somewhere, and this number is only the value at `DARK_ADAPTED_REFERENCE_FOV`. Do not treat 8000 as
## settled, and do not absorb the remainder into it without finding it: a correction we do not
## understand comes back wearing another hat. The audit, with the numbers, is in the vault:
## `SpaceSim/Sky and Backgrounds.md` §9.
const DARK_ADAPTED_MULTIPLIER := 8000.0


## The dark-adapted multiplier **for the field of view actually in use**.
##
## Evert's idea, 2026-10-14: *"can't we use the FOV for the dark adapted multiplier?"* It is the right
## correction, and it fixes a self-inconsistency rather than papering over one — the shader's output
## goes as `(height / tan(half vfov))^2`, so a multiplier derived at one field cannot be right at
## another. Deriving it also *chooses a behaviour*: with this, the sky is **independent of the field of
## view and still dependent on the resolution**, which is the consistent reading of Evert's choice that
## stars should brighten with more pixels. A narrower field stops changing brightness; a bigger frame
## still does.
##
## Number to check it against: at 70 degrees this is 4.18x the reference value, because
## `(tan 35 / tan 18.9)^2 = (0.7002 / 0.3424)^2`.
static func dark_adapted_multiplier(fov_degrees: float) -> float:
	var tan_reference := tan(deg_to_rad(DARK_ADAPTED_REFERENCE_FOV * 0.5))
	var tan_now := tan(deg_to_rad(clampf(fov_degrees, 1.0, 179.0) * 0.5))
	var scale := tan_now / tan_reference
	return DARK_ADAPTED_MULTIPLIER * scale * scale

var attributes: CameraAttributesPhysical
var _multiplier := 1.0


func _init() -> void:
	attributes = CameraAttributesPhysical.new()
	# **Auto-exposure off.** Leaving it on would let the engine override the number below with its
	# frame average, which is the whole failure this replaces.
	attributes.auto_exposure_enabled = false
	attributes.exposure_multiplier = _multiplier


## The multiplier that puts a lit surface at middle grey, given the illuminance at the observer.
##
## A surface's luminance is proportional to the light falling on it, so the correction is proportional
## to the reciprocal of the illuminance, and `REFERENCE_LUX` is the light at which no correction is
## needed. At one au (128,000 lux) this gives 0.78; at Neptune (141 lux) it gives 709 — a little over
## nine stops, which is the honest difference between the two places.
static func target_multiplier(lux: float) -> float:
	if lux <= 0.0:
		return MAX_MULTIPLIER
	return clampf(REFERENCE_LUX / lux, 1.0 / MAX_MULTIPLIER, MAX_MULTIPLIER)


## The multiplier that puts a scene of mean **luminance** at middle grey.
##
## A luminance and an illuminance differ by pi for a Lambertian surface, so this is the rule above with
## that factor folded in — and the two agree, which is the point: `target_multiplier(E)` and
## `target_multiplier_for_luminance(E/pi)` are the same number.
##
## It is the *luminance* form that a scene wants, because adaptation follows what the eye is looking
## at, not the light arriving at the observer. See `SpacesimSystemScene.view_luminance_at`.
static func target_multiplier_for_luminance(lux_per_sr: float) -> float:
	return target_multiplier(lux_per_sr * PI)


## Follow the light. `delta` is seconds since the last update.
func update(lux: float, delta: float) -> void:
	update_to(target_multiplier(lux), delta)


## Settle on the light at once — for a jump or an arrival, where a transition would be wrong.
func snap_to(lux: float) -> void:
	_multiplier = target_multiplier(lux)
	attributes.exposure_multiplier = _multiplier


## Follow a target MULTIPLIER rather than a light level, for the case where the light level is not
## what the eye is responding to. `update()` is the special case of this.
func update_to(target: float, delta: float) -> void:
	var clamped := clampf(target, 1.0 / MAX_MULTIPLIER, MAX_MULTIPLIER)
	_multiplier = lerpf(_multiplier, clamped, clampf(ADAPTATION_RATE * delta, 0.0, 1.0))
	attributes.exposure_multiplier = _multiplier


func multiplier() -> float:
	return _multiplier


## The tone curve, the ambient and the star's glare.
##
## AgX rather than ACES: it is the one built for a wide range without the highlight colour shifts ACES
## can produce, and "not fully black or white" is the tone curve's job rather than the light's.
##
## The tone curve is deliberately left alone in the same change as the exposure, so that if the
## picture improves we know which one did it.
##
## **The ambient comes from the SKY now, not from a colour.** Evert, 2026-10-14: *"The sky should be
## the ambient light source."* That does not move an authored constant so much as delete one: an
## `AMBIENT_SOURCE_COLOR` with a look-value energy is a number that can silently disagree with the
## sky above it. Taken from the background, a night side is lit by the stars that are actually
## there — and because a sky of point sources has almost no mean radiance, a night side goes
## genuinely black. That is the physical answer, not a regression: the vault's own note is that a
## physical floor *removes* the fake one.
static func configure(environment: Environment) -> void:
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	environment.tonemap_white = 6.0
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_BG
	# The star's disk should roll off through the tonemapper rather than sit in the frame as the
	# brightest thing in the exposure histogram.
	environment.glow_enabled = true
	environment.glow_intensity = 0.4
	environment.glow_bloom = 0.05
	environment.glow_hdr_threshold = 1.0
