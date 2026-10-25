class_name SpacesimCloudModel
extends RefCounted
## A body's clouds: **where they sit, and how they are organised.** Nothing here draws anything.
##
## Two halves, and they answer different questions:
##
## | | |
## |---|---|
## | **where a deck sits** | `SpacesimAtmosphereModel.condensation_levels()`, which is already built and checked against Earth's and Venus's real decks. This module only *selects* from it — `layers()` |
## | **how the deck is organised** | the two length scales below, and the ratio between them. That is this file |
##
## **The physics is a parameterisation, not a simulation, and that is deliberate.** It gets *plausible
## morphology* — something that reads as Jupiter, Earth or Venus — and it does not predict a storm. The
## scales are derived and the detail is stylised, which is the same relationship the condensation level
## already has: Venus's deck lands right *from the wrong molecule*, because what sets the level is the
## temperature profile and it does not care that our condensable list is incomplete.
##
## ## The two scales
##
## **Bands** come from the zonal jets, and jets exist because of the *gradient* of the Coriolis
## parameter. Turbulence on a rotating sphere organises into zonal bands at the **Rhines scale**:
##
##     L_Rh = sqrt(U / beta),        beta = 2 * Omega * cos(latitude) / a
##
## **Mixing** comes from the eddies, sized by the **Rossby deformation radius**, `L_D = N * H / f`.
##
## Zonal jets are **barriers to mixing**, so the *ratio* of the band scale to the planet decides what a
## world looks like: many narrow barriers keep the bands coherent, few broad ones let the eddies cross
## and shred them into weather, and a band scale as large as the planet has no bands at all. `banding()`
## turns that ratio into a verdict three planets confirm — see [constant CELLS_PER_RHINES_BAND].
##
## ## What is derived and what is authored, named rather than blurred
##
## `Omega` comes from content. `a` is the body's radius. `N` and `H` are already derived by
## `SpacesimAtmosphereModel`. **`U`, the velocity scale, is NOT derivable** — it is authored per body
## (`SpacesimAtmosphere.wind_speed`), it enters as a square root, and a body that does not carry one
## gets `UNKNOWN` rather than a plausible verdict. Everything else here is arithmetic on those.

## **The constant that turns a Rhines band count into circulation cells, and it is a CALIBRATION, not a
## derivation.** The law alone gives `(pi/2) / (L_Rh/a)` bands per hemisphere, which is 15 for Earth
## against an observed 3-4 and 35 for Jupiter against an observed 8-10. **The ratio between the two
## planets is what the law gets right** — 15/35 = 0.43 against 3.5/9 = 0.39 — so the law is a scaling
## with a constant in front of it, and this is that constant.
##
## It is `1/4` because that is what both planets want at once: Earth comes to **3.8 cells** and Jupiter
## to **8.7**, against observed counts of 3-4 and ~9. A number defended to a third digit would be a
## number pretending to be measured; this one is a calibration and says so, like `SpacesimLod`'s
## triangle-per-screen-radius.
const CELLS_PER_RHINES_BAND := 0.25

## Above this, `L_Rh/a` means the bands are a fine lattice the eddies cannot cross.
##
## **0.09 rather than 0.07 since 2026-10-17, and the fourth planet is the evidence.** Saturn comes to
## `L_Rh/a` = 0.071 with a 100 m/s mean zonal wind — just over the old bound, so it was called `SHREDDED`,
## which sets the field's floor to 0.85 and flattened its deck to a featureless disc. **Saturn is a banded
## planet**; a threshold that calls it shredded is in the wrong place, and the gap to Earth's 0.104 is
## wide enough to separate them. The original three still classify as before: Jupiter 0.045 `BANDED`,
## Earth 0.104 `SHREDDED`, Venus 0.674 `FEATURELESS`.
const BANDED_BELOW := 0.09
## Above this, the eddies are as large as the bands and break them up into weather. Past it, the band
## scale has reached the planet's own size and there is nothing to break up.
const SHREDDED_BELOW := 0.35

## **Where the eddy scale is evaluated, and it cannot be the equator.** `L_D = N*H/f` and `f` vanishes at
## the equator, so the function would divide by zero there — and the answer would not be meaningful if
## it did not: baroclinic eddies are a mid-latitude phenomenon on every body where they have been
## measured. 45 degrees is the middle of that belt.
const EDDY_LATITUDE := PI / 4.0

## How the deck is organised. Not a look, an *instruction*: a renderer reads this.
enum Banding {
	UNKNOWN, ## no reliable rotation or velocity scale, so nothing is claimed
	BANDED, ## many narrow barriers, weak cross-band mixing — belts and zones
	SHREDDED, ## a few broad bands that the eddies cross and break up — bands plus weather
	FEATURELESS, ## the band scale is the planet: one cell, no structure — **do not generate a field**
}


## A body's rotation **as the air sees it**, which is not always the body's own.
##
## **This is the piece that cannot be quietly guessed.** A solid body and its atmosphere usually turn
## together and `rotation_period` is both. Where the air **superrotates** they come apart, and the
## factor is not small: **Venus's atmosphere circles in about 4 days against a rotation period of 243**,
## a factor of **61**, which moves its band scale by an order of magnitude.
##
## **What it does not do is change Venus's verdict, and that is worth knowing.** The body's own rotation
## gives `L_Rh/a` of 5.3 against the air's 0.67 — and *both* are `FEATURELESS`, because a slowly
## rotating body has a huge band scale too. So the fallback is not a trap that flips a regime here; it
## is a trap that changes the numbers a map is built from. `tests/test_clouds.gd` asserts both rather
## than assuming the obvious. A body whose air turned *slower* than its body would cross a threshold,
## which is the case the field exists for.
class Rotation:
	extends RefCounted

	enum Source {
		AUTHORED, ## content gave the atmosphere's own rate, which is the one to use
		BODY, ## fell back to the body's rotation — right for a co-rotating air, wrong for a superrotator
		UNKNOWN, ## neither is known, so nothing is claimed
	}

	## Radians per second, positive for prograde.
	var omega := 0.0
	var source := Source.UNKNOWN
	## The atmosphere's rate over the body's own, so 1.0 is a co-rotating air and 61 is Venus.
	## Zero where either is unknown.
	var ratio := 0.0


## A body's cloud organisation in one object: the verdict and every number behind it.
class Morphology:
	extends RefCounted

	var rotation := Rotation.new()
	## Metres. Zero where the inputs are not there.
	var band_scale := 0.0
	## Metres, the eddy size. Zero likewise.
	var eddy_scale := 0.0
	## **The eddy size as an ANGLE** — `eddy_scale / radius`, in radians. This is the form a map needs:
	## the field sizes its features in angle, and the metres are meaningful for one body at a time.
	var eddy_angular_scale := 0.0
	## `L_Rh / a`, the dimensionless number the verdict comes from. Zero where unknown.
	var ratio := 0.0
	var banding := Banding.UNKNOWN
	## Circulation cells per hemisphere.
	var cells := 0.0


## The atmosphere's rotation, from content if it has one and the body's rotation if it does not.
##
## **The fallback reports itself.** A caller that gets `Rotation.Source.BODY` for a body whose air
## superrotates is being handed a wrong number, and that has to be visible rather than silent — the
## ratio is what makes it detectable. Venus's is 61.
static func rotation_of(body: SpacesimSystemBody) -> Rotation:
	var rotation := Rotation.new()
	if body == null:
		return rotation
	if body.rotation_period > 0.0:
		rotation.omega = TAU / body.rotation_period
		rotation.source = Rotation.Source.BODY
		rotation.ratio = 1.0
	if body.atmosphere == null:
		return rotation
	var period := body.atmosphere.atmospheric_rotation_period
	if period <= 0.0:
		return rotation
	var authored := TAU / period
	if rotation.omega > 0.0:
		rotation.ratio = authored / rotation.omega
	else:
		rotation.ratio = 0.0
	rotation.omega = authored
	rotation.source = Rotation.Source.AUTHORED
	return rotation


## The Coriolis parameter, `f = 2 * Omega * sin(latitude)`, in 1/s. Zero at the equator, and that
## zero is physical rather than a bug: it is why the deformation radius has no meaning there.
static func coriolis(omega: float, latitude: float) -> float:
	return 2.0 * omega * sin(latitude)


## The *gradient* of the Coriolis parameter, `beta = 2 * Omega * cos(latitude) / a`, in 1/(m s).
## Maximum at the equator, and it is this rather than `f` that makes zonal jets exist.
static func beta(omega: float, radius: float, latitude: float) -> float:
	if radius <= 0.0:
		return 0.0
	return 2.0 * omega * cos(latitude) / radius


## The Rhines scale, `sqrt(U / beta)`, in metres: where turbulence stops being isotropic and starts
## being zonal bands. **Evaluated at the equator by default**, which is where `beta` is largest and the
## bands are therefore narrowest — so the count is the most bands the body could have.
static func band_scale(omega: float, radius: float, wind: float, latitude: float = 0.0) -> float:
	var gradient := beta(omega, radius, latitude)
	if gradient <= 0.0 or wind <= 0.0:
		return 0.0
	return sqrt(wind / gradient)


## The buoyancy frequency `N`, in 1/s — **and this one is an approximation standing in for a gap, named
## rather than hidden.**
##
## The exact form is `N^2 = (g/T)(lapse_dry - lapse)`, and `SpacesimAtmosphereModel`'s profile uses
## `lapse_dry = g/c_p` for its own lapse, so **the model's atmosphere is neutrally stratified by
## construction and its `N` is exactly zero.** Reading `N` off the profile is therefore not available.
##
## What is used instead is the **isothermal** value, `N^2 = g^2 / (c_p * T)`, which is the same
## expression with `lapse = 0` — the adiabatic case's opposite, and so an **upper bound**. Earth comes
## out at **0.018 1/s** against a real tropospheric ~0.01, a factor of 1.8, and `L_D` is proportional to
## `N`, so the eddy scale is about twice life-size. Order of magnitude is what a map's eddy size needs.
static func buoyancy_frequency(
	atmosphere: SpacesimAtmosphere, materials: SpacesimMaterialTable, gravity: float, temperature: float
) -> float:
	if atmosphere == null or materials == null or gravity <= 0.0 or temperature <= 0.0:
		return 0.0
	var capacity := SpacesimAtmosphereModel.heat_capacity(atmosphere, materials)
	if capacity <= 0.0:
		return 0.0
	return gravity / sqrt(capacity * temperature)


## The Rossby deformation radius, `N * H / f`, in metres: **how big one eddy is**, as opposed to how
## wide one band is. Evaluated at [constant EDDY_LATITUDE], because `f` vanishes at the equator.
static func eddy_scale(
	air_scale_height: float, buoyancy: float, omega: float, latitude: float = EDDY_LATITUDE
) -> float:
	var f := coriolis(omega, latitude)
	if f <= 0.0 or air_scale_height <= 0.0 or buoyancy <= 0.0:
		return 0.0
	return buoyancy * air_scale_height / f


## **The verdict.** One dimensionless number, three planets, and each confirms it:
##
## | body | `L_Rh / a` | verdict | reality |
## |---|---|---|---|
## | Jupiter | 0.045 | `BANDED` | hard belts and zones |
## | Earth | 0.104 | `SHREDDED` | ITCZ and storm tracks, broken up by weather |
## | Venus | 0.674 | `FEATURELESS` | a nearly unbroken bright shroud |
##
## **`FEATURELESS` is the one that earns its place in the code.** Evert, 2026-10-16: *"if we can predict
## that the cloud coverage would be effectively noise free, we can skip the noise generation."* A
## renderer that reads this never generates a field for Venus — a decision the model makes and a test
## checks, rather than an `if` buried in a shader.
##
## The thresholds are a calibration placed between those three estimates, not a derivation.
static func banding(ratio: float) -> Banding:
	if ratio <= 0.0:
		return Banding.UNKNOWN
	if ratio < BANDED_BELOW:
		return Banding.BANDED
	if ratio < SHREDDED_BELOW:
		return Banding.SHREDDED
	return Banding.FEATURELESS


## Circulation cells per hemisphere, from the band ratio alone.
##
## One cell means air rises at the equator and sinks at the pole, which is a body with no bands to
## speak of; three pairs is Earth; many is a gas giant. **This is the same information as the verdict,
## in the form the latitude profile needs.**
static func cell_count(ratio: float) -> float:
	if ratio <= 0.0:
		return 0.0
	return CELLS_PER_RHINES_BAND * (PI * 0.5) / ratio


## **Where condensation is favoured, as a function of latitude** — the "bands where condensation is
## more likely" that every atmosphere with a circulation has.
##
## Evert, 2026-10-16: *"Even Earth has bands where condensation is more likely, and then they get mixed
## up with weather patterns that physically carry the clouds around the planet."* This is the first
## half of that; [member Morphology.banding] is how much the second half shreds it.
##
## Air rises where cells meet and sinks where they part, and rain follows the rising branch — so with
## `cells` cells per hemisphere the favouring **alternates every `90/cells` degrees**. Earth's three
## give rising at 0 and 60 and sinking at 30 and 90, which is the ITCZ, the subtropical deserts, the
## storm track and the polar high, in that order. That is the check, and it is asserted.
##
## Returns 0 for sinking air and 1 for rising; a smooth cosine between, because a cell boundary is a
## latitude band and not a line.
static func condensation_favouring(latitude: float, cells: float) -> float:
	if cells <= 0.0:
		# No cells to alternate between: a slowly rotating body has one cell over the whole hemisphere
		# and nothing to contrast it with.
		return 1.0
	var span := (PI * 0.5) / cells
	var turn := PI * absf(latitude) / span
	# A cosine counted a full period per cell: 1 at the rising branch, 0 at the sinking one.
	return (1.0 + cos(turn)) * 0.5


## Everything about how a body's clouds are organised, from content and the existing derivation.
##
## `luminosity` and `distance` are what `SpacesimAtmosphereModel` needs for the temperature; nothing
## raises the temperature here, it is passed straight through.
static func morphology(
	body: SpacesimSystemBody,
	materials: SpacesimMaterialTable,
	luminosity: float,
	distance: float
) -> Morphology:
	var result := Morphology.new()
	result.rotation = rotation_of(body)
	if body == null or body.atmosphere == null or materials == null:
		return result

	var gravity := SpacesimAtmosphereModel.surface_gravity(body)
	var equilibrium := SpacesimAtmosphereModel.equilibrium_temperature(
		body, materials, luminosity, distance
	)
	var temperature := SpacesimAtmosphereModel.reference_temperature(
		body, materials, luminosity, distance
	)
	var air_height := SpacesimAtmosphereModel.scale_height(
		body.atmosphere, materials, temperature, gravity
	)
	var wind := body.atmosphere.wind_speed

	result.band_scale = band_scale(result.rotation.omega, body.radius, wind)
	if body.radius > 0.0 and result.band_scale > 0.0:
		result.ratio = result.band_scale / body.radius
	result.banding = banding(result.ratio)
	result.cells = cell_count(result.ratio)
	result.eddy_scale = eddy_scale(
		air_height,
		buoyancy_frequency(body.atmosphere, materials, gravity, temperature),
		result.rotation.omega
	)
	if body.radius > 0.0:
		result.eddy_angular_scale = result.eddy_scale / body.radius
	return result


## **The condensables that have somewhere to sit** — the deck stack, in the order they are drawn from
## outside in.
##
## A filter over `SpacesimAtmosphereModel.condensation_levels()` rather than a second derivation: it
## returns the `LEVEL` regime only, so a `DEEP` (it genuinely condenses, but below the depth the model
## represents — a giant's water cloud) and a `NONE` (never cold enough in the troposphere) contribute
## nothing, which is their honest answer rather than a missing value.
static func layers(
	atmosphere: SpacesimAtmosphere,
	materials: SpacesimMaterialTable,
	gravity: float,
	equilibrium: float,
	body: SpacesimSystemBody = null
) -> Array:
	var stacked: Array = []
	for level in SpacesimAtmosphereModel.condensation_levels(
		atmosphere, materials, gravity, equilibrium, body
	):
		if level.regime == SpacesimAtmosphereModel.Condensation.Regime.LEVEL:
			stacked.append(level)
	return stacked
