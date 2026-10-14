class_name SpacesimStarLight
extends RefCounted
## The star as a **physical light source**: one directional light, aimed at the observer, whose
## strength is the light that is really there.
##
##   luminosity L  ->  irradiance E = L / (4 pi d^2)  ->  illuminance = E * efficacy, in lux
##
## A fixed light energy cannot work across a solar system. Mercury to Neptune is 6,000:1 — about
## 12.6 stops — before surface albedo is counted, so any constant is wrong everywhere except at one
## distance and wrong by three orders of magnitude at the edges. Setting the light in **lux** and
## letting the camera expose is what makes one light correct at every distance.
##
## `light_intensity_lux` only does anything when the project setting
## `rendering/lights_and_shadows/use_physical_light_units` is on. With it off Godot ignores the
## property entirely and this whole class quietly does nothing.

## Luminous efficacy of sunlight, lm/W. A constant for now: deriving it from the star's own Planck
## curve is what would make a red dwarf genuinely dimmer in the way it should be, and is a later
## refinement.
const LUMINOUS_EFFICACY := 94.0

## The Sun's disk as seen from 1 au, in degrees. Feeds Godot's shadow softening, so a terminator
## reads as a terminator rather than as a cut.
const SOLAR_ANGULAR_DIAMETER := 0.533

var luminosity: float = 0.0
var light: DirectionalLight3D


func create(parent: Node, star_luminosity: float, temperature: float) -> DirectionalLight3D:
	luminosity = star_luminosity
	light = DirectionalLight3D.new()
	light.name = "StarLight"
	# The temperature is handed to Godot rather than a colour being computed here: Godot already
	# turns a temperature into a spectrum, and re-implementing Planck-to-sRGB would only be a worse
	# version of what it does internally.
	light.light_temperature = temperature if temperature > 0.0 else 6500.0
	light.light_angular_distance = SOLAR_ANGULAR_DIAMETER if temperature > 0.0 else 0.0
	parent.add_child(light)
	return light


## Irradiance at a distance, W/m². At one au this is the solar constant, 1361 W/m².
static func irradiance(luminosity_watts: float, distance: float) -> float:
	if distance <= 0.0:
		return 0.0
	return luminosity_watts / (4.0 * PI * distance * distance)


## Illuminance at a distance, in lux. 128,000 lux at one au is the measured value for direct
## sunlight, which is the number this has to land on to be believable.
static func illuminance(luminosity_watts: float, distance: float) -> float:
	return irradiance(luminosity_watts, distance) * LUMINOUS_EFFICACY


func lux_at(distance: float) -> float:
	return illuminance(luminosity, distance)


## **The fraction of the Sun's disc still visible**, with a body's disc across it — 1.0 in the open,
## 0.0 in an umbra, and the covered fraction of the Sun in between.
##
## **Why this is computed here rather than rendered.** Godot does not ask what is in the way of a
## light. A directional light hands a fragment a direction, a colour and an energy, and the shader's
## `NdotL` is the entire test — which is why a ship behind a planet is lit, and why Evert reported
## exactly that on 2026-10-15: *"it does not appear that the planets cast shadows… the ship is fully
## lit when there is a planet between me and Sol."* The engine's only occlusion is `shadow_enabled`,
## and that is a shadow *map*: camera-relative, `directional_shadow_max_distance` 100 m by default, and
## unable to resolve a penumbra that is 0.06% of a planet wide. The physics is one disc covering
## another, so it is arithmetic instead — exact at any scale, free, and testable without a GPU.
##
## **Three angles and no distance**, because that is all the observer can see: the Sun's angular radius,
## the body's, and the angle between their centres. Everything the 3D geometry would add — umbra,
## penumbra, how far the shadow reaches — is already implied by those three at the point of
## observation. In particular the tip of an umbra is where the body's angular radius has fallen to the
## Sun's, so Earth's comes to `R / sin(sun_angle)` = **1.372 Gm** against a published **1.38 Gm**.
##
## **Neither angle is a constant, and neither is the cone they make.** The Sun's angular radius goes as
## one over the distance to the star: 0.687 degrees at Mercury, 0.266 at one au, 0.009 at Neptune. The
## cone is `sun_angle + body_angle`, and near a body the second term is the large one — a thousand
## kilometres above Earth, Earth is 81 degrees wide. So the cone's job as a filter is to reject bodies
## too *far* to touch the Sun's disc, which is the first line below.
##
## **The discs are circles in a tangent plane, which is a small-angle model** — and it is accurate
## exactly where an eclipse matters. The covered fraction at the half-covered point comes out **0.1%
## high for a body 57 degrees wide** and 5% high for one twice the Sun's own size, so the error goes as
## the ratio of the two discs: a planet eclipsing its star is always the first case, because an umbra
## exists at all only where the body is the larger disc. Measured against the exact answer, not assumed.
static func solar_transmission(sun_angle: float, body_angle: float, separation: float) -> float:
	if sun_angle <= 0.0 or body_angle <= 0.0:
		return 1.0
	if separation >= sun_angle + body_angle:
		return 1.0 ## the discs do not touch
	if body_angle >= sun_angle:
		if separation <= body_angle - sun_angle:
			return 0.0 ## the body covers the Sun whole: an umbra
	else:
		if separation <= sun_angle - body_angle:
			# The Sun covers the *body*. This is the most a body smaller than the Sun can ever block,
			# and the reason a distant moon's transit is a dip and not a night.
			return 1.0 - pow(body_angle / sun_angle, 2.0)
	# Partial: the area the two discs share, over the Sun's own area. The standard lens formula.
	var d2 := separation * separation
	var sun2 := sun_angle * sun_angle
	var body2 := body_angle * body_angle
	var lens := sun2 * acos(clampf((d2 + sun2 - body2) / (2.0 * separation * sun_angle), -1.0, 1.0)) \
		+ body2 * acos(clampf((d2 + body2 - sun2) / (2.0 * separation * body_angle), -1.0, 1.0))
	# Clamped at zero because the two triangular terms can disagree in the last bit at a grazing
	# contact, which would take the square root of a negative number.
	var root := maxf(0.0, (-separation + sun_angle + body_angle)
		* (separation + sun_angle - body_angle)
		* (separation - sun_angle + body_angle)
		* (separation + sun_angle + body_angle))
	return 1.0 - clampf((lens - 0.5 * sqrt(root)) / (PI * sun2), 0.0, 1.0)


## Aim the light from the star at wherever the observer is, and set its strength for that distance.
##
## One directional light cannot light a whole system from a star, so it lights the place the player
## actually is — which is the only place the player can see, and the only place whose distance the
## strength should be computed from.
##
## `transmission` is how much of the Sun a body is standing in front of at that place, and it belongs
## in this argument list rather than in a setter because the strength **is** the illuminance times it:
## one multiplicative factor on a quantity this class already owns, with no ordering to get wrong.
## `SpacesimSystemScene.sun_transmission` is the only thing that computes it.
func aim_at(observer_position: Vector3, star_position: Vector3, transmission := 1.0) -> void:
	if light == null:
		return
	var offset := observer_position - star_position
	var distance := offset.length()
	if distance < 1.0:
		return # standing on the star
	var direction := offset / distance
	var up := Vector3.UP
	if absf(direction.dot(up)) > 0.999:
		up = Vector3.RIGHT
	light.global_transform = light.global_transform.looking_at(light.global_position + direction, up)
	light.light_intensity_lux = lux_at(distance) * clampf(transmission, 0.0, 1.0)
