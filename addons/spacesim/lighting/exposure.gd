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

## How far we will correct. Past this a very dark or very bright body keeps some of its own character
## rather than every body being exposed to look identical.
const MAX_MULTIPLIER := 4096.0

## How fast exposure follows a change. Slow on purpose: what you notice about a night side is that it
## stays dark, and a hard cut when flying between planets looks like a bug.
const ADAPTATION_RATE := 0.6

## A **floor, not physics.** Ambient light in space is starlight, which is negligible. This exists so a
## shadowed side reads as dark rather than as a hole.
const AMBIENT_ENERGY := 0.02

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
	_multiplier = lerpf(_multiplier, target_multiplier(lux), clampf(ADAPTATION_RATE * delta, 0.0, 1.0))
	attributes.exposure_multiplier = _multiplier


## Settle on the light at once — for a jump or an arrival, where a transition would be wrong.
func snap_to(lux: float) -> void:
	_multiplier = target_multiplier(lux)
	attributes.exposure_multiplier = _multiplier


func multiplier() -> float:
	return _multiplier


## The tone curve, the ambient floor and the star's glare.
##
## AgX rather than ACES: it is the one built for a wide range without the highlight colour shifts ACES
## can produce, and "not fully black or white" is the tone curve's job rather than the light's.
##
## The tone curve is deliberately left alone in the same change as the exposure, so that if the
## picture improves we know which one did it.
##
## `ambient_color` is a tint, not a colour derived from the star: Godot turns a *temperature* into a
## spectrum internally for lights, but exposes no such conversion for ambient, so a star-coloured
## ambient would mean re-implementing Planck-to-sRGB here to no benefit.
static func configure(environment: Environment, ambient_color: Color) -> void:
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	environment.tonemap_white = 6.0
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = ambient_color
	environment.ambient_light_energy = AMBIENT_ENERGY
	# The star's disk should roll off through the tonemapper rather than sit in the frame as the
	# brightest thing in the exposure histogram.
	environment.glow_enabled = true
	environment.glow_intensity = 0.4
	environment.glow_bloom = 0.05
	environment.glow_hdr_threshold = 1.0
