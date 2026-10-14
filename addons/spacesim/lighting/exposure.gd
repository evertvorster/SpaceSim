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

## A clear blue sky's own light, in lux — Schlyter's "full daylight, not direct sun" is 10,000-25,000.
## The measured 128,000 lux of direct sunlight is the *star's*, and is a different thing.
##
## It matters because **you do not have to look at the Sun to lose the stars.** Stand in a lit
## atmosphere with the Sun behind you and the sky in front of you is still daylight. Without this term
## the exposure rests at the dark-adapted multiplier and that sky blows out to solid white — which is
## exactly what the first cut did, measured at 100% of the frame lit, 5 km above Saturn.
const DAYLIGHT_SKY_LUX := 25000.0

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
const DARK_ADAPTED_MULTIPLIER := 8000.0

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
