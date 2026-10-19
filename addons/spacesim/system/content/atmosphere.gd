class_name SpacesimAtmosphere
extends Resource
## A body's atmosphere as content: how much of it, and what it is made of.
##
## The profiles (T(h), P(h), rho(h)), the retention test per species and the scattering
## coefficients are all **derived** from this — never authored.

@export var surface_pressure: float = 0.0 ## pascals
## Mole fractions, summing to ~1. Keys are species in the material table.
@export var species: Dictionary[String, float] = {}
## Condensables: their `species` entry is a reference value, not a fixed one, which lets a water
## world's greenhouse depend on its temperature without a feedback loop in the data.
@export var variable_species: PackedStringArray = []
## How long this body's **air** takes to circle it, in seconds. Zero means "the air turns with the
## body", which is true for most of them and is what `rotation_period` is then used for.
##
## **It is not the same number as the body's, and the difference can be enormous.** Venus's atmosphere
## superrotates: it circles in about 4 days against a rotation period of 243, a factor of **61**, which
## moves its band scale from ~31,800 km to ~4,080. **It does not, however, flip Venus's verdict** — a
## slowly rotating body has a huge band scale too, so the fallback is `FEATURELESS` as well; the field
## matters for the numbers a map is built from. Titan superrotates too. See
## `SpacesimCloudModel.rotation_of()`, and `tests/test_clouds.gd`, which asserts both.
@export var atmospheric_rotation_period: float = 0.0 ## seconds, 0 = turns with the body
## The **velocity scale the band and eddy laws use**, in metres per second — a mean zonal wind or an
## eddy velocity, whichever the source publishes. It is the one input `SpacesimCloudModel` cannot
## derive, it enters as a square root, and **zero is a real answer**: it means the scale is not known,
## and the model reports `UNKNOWN` rather than inventing a verdict from a guessed wind.
@export var wind_speed: float = 0.0 ## m/s, 0 = not known
