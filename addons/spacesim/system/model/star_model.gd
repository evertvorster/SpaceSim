class_name SpacesimStarModel
extends RefCounted
## What a star puts out, from what it is made of and how big it is.
##
## Deliberately small. It exists because the lighting needs a luminosity, and luminosity is a
## **derived** property rather than something content should have to state. The rest of the star
## chain — spectral class, the spectral energy distribution — belongs beside it when it is needed.

const SOLAR_MASS := 1.9884e30 ## kg
const SOLAR_LUMINOSITY := 3.828e26 ## watts
const STEFAN_BOLTZMANN := 5.670374419e-8


## Luminosity in watts: what content pinned, or the mass-luminosity relation otherwise.
##
## Piecewise, because one blanket exponent is wrong at both ends — the relation flattens both for
## the smallest stars and for the most massive.
static func luminosity(body: SpacesimSystemBody) -> float:
	if body.overrides != null and body.overrides.set.has("luminosity"):
		return body.overrides.luminosity
	if body.mass <= 0.0:
		return 0.0
	var ratio := body.mass / SOLAR_MASS
	var exponent := 4.0
	if ratio < 0.43:
		exponent = 2.3
	elif ratio < 2.0:
		exponent = 4.0
	elif ratio < 20.0:
		exponent = 3.5
	else:
		exponent = 1.0
	return SOLAR_LUMINOSITY * pow(ratio, exponent)


## Effective temperature in kelvin, from luminosity and radius by Stefan-Boltzmann.
##
## **This is a check on the data rather than a restatement of it.** L and R are measured
## independently, so an error in either shows up here: the Sun's 3.828e26 W and 6.957e8 m have to
## come out at 5772 K, which is the measured value.
static func effective_temperature(luminosity_watts: float, radius: float) -> float:
	if radius <= 0.0 or luminosity_watts <= 0.0:
		return 0.0
	return pow(luminosity_watts / (4.0 * PI * radius * radius * STEFAN_BOLTZMANN), 0.25)


## The star's **angular radius** seen from a distance, in radians: `asin(R / d)`.
##
## A star's disk is the one quantity in the scene that is the same in kind at every distance and
## wrong at every distance but one — so it is derived for the same reason the light's strength is. The
## constant this replaces was the Sun's disk at 1 au (0.533 degrees across): correct there, **2.6x too
## small at Mercury and 30x too large at Neptune**.
##
## **One quantity, four consumers, and two of them are a diameter:** the **drawn disc's size**, the
## **penumbra width** of a body's shadow, and **total versus annular** (a comparison of two angular
## radii whose margin is only a few percent) all want this radius; Godot's `light_angular_distance`
## wants an angular **diameter in degrees** — the engine's own doc gives the Sun from Earth as
## "approximately 0.5" — so it takes `rad_to_deg(2 * angular_radius(R, d))`, which is where that
## 0.533 came from. It softens engine shadow *maps* and is not the analytic penumbra: the two read the
## same number and are not the same mechanism.
static func angular_radius(radius: float, distance: float) -> float:
	if radius <= 0.0 or distance <= 0.0:
		return 0.0
	return asin(clampf(radius / distance, 0.0, 1.0))


## A star's colour, from its effective temperature.
##
## Tanner Helland's compact blackbody fit — the same one the Shaders project uses in `star-colour.md`,
## taken rather than invented, which is the standing rule about that site: it is short, fast and good
## enough, and a second implementation would only be a worse copy.
##
## It is **linearised** on the way out. The fit yields sRGB-ish numbers, and using those as though they
## were linear is the exact mistake that cost the Shaders project hours (its "pale and milky" field),
## so the conversion is explicit rather than left to whoever reads it next.
static func color(temperature: float) -> Color:
	var t := clampf(temperature, 1000.0, 40000.0) / 100.0
	var r: float = 255.0
	var g: float = 99.4708025861 * log(t) - 161.1195681661
	if t > 66.0:
		r = 329.698727446 * pow(t - 60.0, -0.1332047592)
		g = 288.1221695283 * pow(t - 60.0, -0.0755148492)
	var b: float = 255.0
	if t < 66.0:
		if t <= 19.0:
			b = 0.0
		else:
			b = 138.5177312231 * log(t - 10.0) - 305.0447927307
	return Color(
		pow(clampf(r, 0.0, 255.0) / 255.0, 2.2),
		pow(clampf(g, 0.0, 255.0) / 255.0, 2.2),
		pow(clampf(b, 0.0, 255.0) / 255.0, 2.2)
	)
