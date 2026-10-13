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
