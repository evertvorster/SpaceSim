class_name SpacesimExposure
extends RefCounted
## The camera's exposure and the tone curve: what keeps a scene readable from Mercury to Neptune
## instead of black at one end and white at the other.
##
## **Auto-exposure lives on `CameraAttributes`, not on the `Environment`** — probed on 4.7.2. The
## Environment owns only the tone curve. That split is convenient: a camera can be re-exposed without
## touching the world, and the two can be reasoned about separately.

## Stops. The system spans about 16 of them: 12.6 from Mercury to Neptune, plus roughly 3.5 from
## surface albedo (ocean 0.06 to fresh ice 0.75). The window is deliberately wider than the bare
## ratio, so the tonemapper has headroom to roll off in rather than a rail to sit against.
const MIN_EXPOSURE_EV := -6.0
const MAX_EXPOSURE_EV := 16.0

## How fast exposure chases the frame. Slow on purpose: fast exposure pumps while you fly past
## something, and the thing you notice about a night side is that it stays dark.
const ADAPTATION_SPEED := 0.6

## A **floor, not physics.** Ambient light in space is starlight, which is negligible, plus what a
## planet reflects of its own star. This small constant exists so a shadowed side reads as dark
## rather than as a hole, and so auto-exposure is not driven to its ceiling by a frame containing
## almost nothing — which is the classic way a night side comes out as a blown-out white sky.
const AMBIENT_ENERGY := 0.02


## What the camera exposes with. Attach to a `Camera3D` with `camera.attributes = ...`.
static func camera_attributes() -> CameraAttributesPhysical:
	var attributes := CameraAttributesPhysical.new()
	attributes.auto_exposure_enabled = true
	attributes.auto_exposure_min_exposure_value = MIN_EXPOSURE_EV
	attributes.auto_exposure_max_exposure_value = MAX_EXPOSURE_EV
	attributes.auto_exposure_speed = ADAPTATION_SPEED
	return attributes


## The tone curve, the ambient floor and the star's glare.
##
## AgX rather than ACES: it is the one built for a wide range without the highlight colour shifts
## ACES can produce, and "not fully black or white" is the tone curve's job rather than the light's.
##
## `ambient_color` is a tint, not a colour derived from the star. Godot turns a *temperature* into a
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
