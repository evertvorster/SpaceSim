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

## The Sun's disk is **derived, not stated** — see `SpacesimLod.angular_radius`, which this feeds into
## Godot's `light_angular_distance` as the angular *diameter* it wants. It follows the observer exactly
## as the strength does, and for the same reason: a value fixed at 1 au is 2.6x too small at Mercury
## and 30x too large at Neptune.

var luminosity: float = 0.0
## The star's own radius in metres, so its angular size can be derived at whatever distance the
## observer happens to be.
var radius: float = 0.0
var light: DirectionalLight3D


func create(parent: Node, star_luminosity: float, temperature: float, star_radius: float) -> DirectionalLight3D:
	luminosity = star_luminosity
	radius = star_radius
	light = DirectionalLight3D.new()
	light.name = "StarLight"
	# The temperature is handed to Godot rather than a colour being computed here: Godot already
	# turns a temperature into a spectrum, and re-implementing Planck-to-sRGB would only be a worse
	# version of what it does internally.
	light.light_temperature = temperature if temperature > 0.0 else 6500.0
	# `light_angular_distance` is set in `aim_at`, not here: it is a property of the observer's
	# distance, and a star with no radius has an angular size of zero, which `angular_radius` returns.
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


## Aim the light from the star at wherever the observer is, and set its strength **and its angular
## size** for that distance.
##
## One directional light cannot light a whole system from a star, so it lights the place the player
## actually is — which is the only place the player can see, and the only place whose distance the
## strength should be computed from. The disk's size is a fact about that same distance, so it is read
## from it here rather than being a constant.
func aim_at(observer_position: Vector3, star_position: Vector3) -> void:
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
	light.light_intensity_lux = lux_at(distance)
	light.light_angular_distance = rad_to_deg(2.0 * SpacesimLod.angular_radius(radius, distance))
