class_name SpacesimSurfaceField
extends RefCounted
## **A body's surface height field: the plan, and the shape of it.**
##
## This class owns the **numbers**; the GLSL in `surface_field.gdshaderinc` ("surface_field", "gdshaderinc")
## owns the arithmetic — and it is the *only* implementation of that arithmetic. `plan()` derives every
## constant once, so the bake and the fragment shader cannot be told different ones.
##
## ## Land is not cloud
##
## The cloud field's generator is built from zonal stretching, advection and eddies, because air is carried
## and torn. **None of that is here**, and the docstring on the GLSL says why per mechanism: what shapes rock
## is tectonic, and it acts at plate boundaries. A surface field that reused the weather's structure would
## draw a planet whose continents flow.
##
## What *is* shared is `noise.gdshaderinc` — a FastNoiseLite primitive, which is a noise function rather than
## a model of anything.
##
## ## The plan is a function of the body's address, and of nothing else
##
## A body's seed is its id, so a world regains its own continents without anything being stored, and two
## bodies in one system are not one continent repeated. The frequencies are in **unit-sphere** units — two
## and a half features across the planet is the broad shape inside a plate, eleven is a mountain crest —
## because the field is sampled on the unit direction and never in world metres.
##
## ## There is no CPU twin, and that is the point
##
## A `double` transcription of the field lived here while the shader was being designed — it is how the plate
## lattice, the belts and the warp were compared texel for texel against the GLSL. **It is retired** (Evert,
## 2026-10-19: *"the CPU version of the shader is only to design the shader, and then it gets retired"*), so the
## GLSL in `surface_field.gdshaderinc` is the **only** implementation of what a body's surface is.
##
## **The consequence, planned for rather than discovered:** a bake needs a rendering device, so a headless run has
## no surface maps, and the field's *shape* cannot be asserted in `tests/run.sh` — only the plan's determinism and
## its ranges can. The shape is checked by `tests/shader_check.sh` (it compiles), by a throwaway probe under
## `xvfb-run` when one is needed, and by the flight. That is the price of one implementation rather than two that
## agree until they do not.

## Frequencies, in unit-sphere cycles: a feature is `1/frequency` of the sphere across.
##
## **Chosen against the picture the map has to produce**, not derived from anything. The continental
## frequency is the structure *inside* a plate; the continents themselves are the plate partition, which is
## why this can be as low as two and a half without the planet becoming a single blob.
const CONTINENT_FREQUENCY := 2.5
const RIDGE_FREQUENCY := 11.0
const WARP_FREQUENCY := 3.0

## **The region frequency: slower than a plate, by design.** Evert, 2026-10-19: *"the noise is far too
## uniform. It needs an extra slow octave to make higher and lower peaks, as well as create flat areas."*
## A plate is about 1/14 of the sphere, so 0.7 is a handful of regions across a planet — things a continent can
## sit inside rather than things a continent is made of. **Aggressive on purpose for the first flight**: the
## point of this rung is to find out whether the lever does what it says, and a lever that has to be judged at
## 5 % is a lever nobody can judge.
const REGION_FREQUENCY := 0.7

## Octaves per mechanism. The interior wants five to carry a coastline's worth of shape; the ridges want
## four for a crest; the warp wants three, because a warp is a displacement and not a texture.
const CONTINENT_OCTAVES := 5
const RIDGE_OCTAVES := 4
const WARP_OCTAVES := 3
## Three for the region: it is one slow shape, and octaves below it are the continent frequency's job.
const REGION_OCTAVES := 3

## The FBM gain and lacunarity — **0.5 and 2.0**, half the amplitude per doubling, the ordinary pair and the
## cloud field's own. They describe a spectrum, not a planet, so sharing them is right.
const NOISE_GAIN := 0.5
const NOISE_LACUNARITY := 2.0

## How far the warp may push a sample. **0.35 is about a third of a plate**, which bends a boundary and makes
## the cells irregular without folding the field back on itself — a warp past the feature size closes loops
## and reads as smoke.
const WARP_STRENGTH := 0.35

## **The three shares of the height range**, and the number that makes the hypsometry bimodal.
##
## `PLATE_BIAS_SHARE` is the one to notice: it is the *plate levels*, standing or sagging, and it has to
## dominate for the elevation histogram to have the two modes that Earth's has — continents and ocean
## basins. The interior variation and the ridges are smaller on purpose, because they are detail *on* a plate
## rather than the shape of one.
##
## **0.85 and 0.12 rather than 0.6 and 0.25, and the first flight is why.** At 0.6 the within-plate variation
## was large enough that a standing plate wandered back and forth across the sea level: its interior was half
## drowned and only the higher parts — the belts — broke the surface, so every "continent" was a thin
## meandering *strip* of coast rather than a landmass. A plate now stands clear of the water as a body, with
## the belts as its mountains, which is the shape a continent actually has.
const PLATE_BIAS_SHARE := 0.85
const CONTINENT_SHARE := 0.07
const RIDGE_STRENGTH := 0.5

## **How far the region may scale a plate's level**, and it is a multiplier rather than a share: `0.5` lets a
## standing plate reach 1.5x its own height in a high region and a third of it in a low one. Multiplied because
## a plate's *interior* is a constant level — the property wanted is "this ground is higher here and lower
## there", which is a scaling of that constant and keeps it flat. An added term would tilt a plain.
const REGION_SHARE := 0.5

## **How much of the within-plate texture a sagging plate gets.** `0.15` is a sixth of what a standing plate
## gets: the low ground reads as plains, the uplands keep their grain. This is the number to raise if the plains
## come out looking like paint rather than like ground.
const MOTTLE_PLAIN_GAIN := 0.15

## **How wide a mountain belt is, in the units `1 - dot` is measured in** (0 at a plate centre, 2 at the
## antipode). A belt is where the two nearest centres are within this gap of each other, so it scales with
## the plate size: fourteen plates put a boundary about 0.3 apart on average, and 0.08 is roughly a quarter
## of that.
const BELT_WIDTH := 0.08

## **The vertical scale, as a fraction of the body's radius** — the one free scale in the field, and derived
## rather than authored so no content has to carry it. Earth's real spread is ±9 km on 6,371 km, which is
## **0.14 %**, and that is where this number comes from.
##
## It is deliberately *not* per body: Mars' relief is larger on a smaller body, so a single fraction is wrong
## by a factor somewhere. The alternative — an authored amplitude per body — is content that has to be got
## right before anything can be drawn, and the picture does not depend on the third digit.
const RELIEF_FRACTION := 0.0014

## **There is no width constant here, and that is deliberate.** A map's widths belong to
## `SpacesimSurfaceMaps` — the build width, the ceiling the display implies, and the rungs between them — so a
## second copy of those numbers in the field could only drift from the one the ladder actually bakes at. Two
## constants used to live here (`FLOOR_WIDTH`, `COARSE_WIDTH`) and **nothing read either**; they are gone rather
## than left as a skeleton that looks like a decision.


## Every number the bake and the shader share, derived once by [method plan].
class Plan:
	var seed := 0
	var continent_frequency := CONTINENT_FREQUENCY
	var continent_octaves := CONTINENT_OCTAVES
	var ridge_frequency := RIDGE_FREQUENCY
	var ridge_octaves := RIDGE_OCTAVES
	var warp_frequency := WARP_FREQUENCY
	var warp_octaves := WARP_OCTAVES
	var warp_strength := WARP_STRENGTH
	var ridge_strength := RIDGE_STRENGTH
	var continent_share := CONTINENT_SHARE
	var plate_bias_share := PLATE_BIAS_SHARE
	var belt_width := BELT_WIDTH
	## Where the plate lattice starts, in radians — the body's own turn on it.
	var plate_phase := 0.0
	var gain := NOISE_GAIN
	var lacunarity := NOISE_LACUNARITY
	## The FBM normalisers, `1 / (1 + g + g² + …)` per octave count, so a sum of octaves comes back on ±1.
	var continent_bounding := 1.0
	var warp_bounding := 1.0
	var region_frequency := REGION_FREQUENCY
	var region_octaves := REGION_OCTAVES
	var region_share := REGION_SHARE
	var mottle_plain_gain := MOTTLE_PLAIN_GAIN
	var region_bounding := 1.0
	## The field's own value times this is metres. Zero for a body with no radius to speak of.
	var amplitude := 0.0


## **The compute source, assembled once for every caller**: `#version`, the noise, the field, the kernel.
##
## A source string handed to `shader_compile_spirv_from_source()` gets no preprocessor, so `#include` is not
## available to it — the concatenation *is* the include mechanism. Two bakes compile this: the build-time one
## in `SpacesimSurfaceGpu` (which reads the map back so the distribution can be measured) and the render-thread
## one in `SpacesimSurfaceBakePass`. **One assembler, so they cannot be two fields.**
static func source() -> String:
	return (
		"#version 450\n"
		+ FileAccess.get_file_as_string(NOISE_PATH)
		+ FileAccess.get_file_as_string(FIELD_PATH)
		+ FileAccess.get_file_as_string(KERNEL_PATH)
	)


## **The push-constant block**, written field by field so the layout is readable beside the kernel's.
##
## **Every number comes off the plan**, including the FBM normalisers — a constant typed into the GLSL would be
## a second copy of a number the plan already knows, and it would drift. The block is `ivec2` plus four
## 4-byte fields, then eighteen more: **112 bytes, and it must be supplied at exactly that size** — the driver
## rejects both more and less (*"requires (76) bytes of push constant data, supplied: (80)"*), unlike a uniform
## block where padding is the caller's to choose.
static func push_constants(
	plan_data: Plan, width: int, height: int,
	uv_origin: Vector2 = Vector2.ZERO, uv_size: Vector2 = Vector2.ONE
) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(PUSH_CONSTANT_BYTES)
	bytes.encode_s32(0, width)
	bytes.encode_s32(4, height)
	bytes.encode_float(8, uv_origin.x)
	bytes.encode_float(12, uv_origin.y)
	bytes.encode_float(16, uv_size.x)
	bytes.encode_float(20, uv_size.y)
	bytes.encode_s32(24, plan_data.seed)
	bytes.encode_float(28, plan_data.continent_frequency)
	bytes.encode_s32(32, plan_data.continent_octaves)
	bytes.encode_float(36, plan_data.ridge_frequency)
	bytes.encode_s32(40, plan_data.ridge_octaves)
	bytes.encode_float(44, plan_data.warp_frequency)
	bytes.encode_s32(48, plan_data.warp_octaves)
	bytes.encode_float(52, plan_data.warp_strength)
	bytes.encode_float(56, plan_data.ridge_strength)
	bytes.encode_float(60, plan_data.continent_share)
	bytes.encode_float(64, plan_data.plate_bias_share)
	bytes.encode_float(68, plan_data.belt_width)
	bytes.encode_float(72, plan_data.plate_phase)
	bytes.encode_float(76, plan_data.gain)
	bytes.encode_float(80, plan_data.lacunarity)
	bytes.encode_float(84, plan_data.continent_bounding)
	bytes.encode_float(88, plan_data.warp_bounding)
	## **Appended, never inserted**: these offsets are the kernel's struct order, so a field put in the middle
	## would silently shift every number after it.
	bytes.encode_float(92, plan_data.region_frequency)
	bytes.encode_s32(96, plan_data.region_octaves)
	bytes.encode_float(100, plan_data.region_share)
	bytes.encode_float(104, plan_data.region_bounding)
	bytes.encode_float(108, plan_data.mottle_plain_gain)
	return bytes


const NOISE_PATH := "res://addons/spacesim/system/model/noise.gdshaderinc"
const FIELD_PATH := "res://addons/spacesim/system/model/surface_field.gdshaderinc"
const KERNEL_PATH := "res://addons/spacesim/system/model/surface_kernel.gdshaderinc"
## 112: `ivec2`, two `vec2`, then twenty-two 4-byte fields. Exact, not padded — see [method push_constants].
const PUSH_CONSTANT_BYTES := 112


## A body's address, as the seed its surface grows from.
static func seed_for(body_id: String) -> int:
	return hash(body_id)


## The plan for a body: its seed from its id, its plate lattice's turn from the same seed, and its relief
## amplitude from its size.
static func plan(body_id: String, radius: float) -> Plan:
	var result := Plan.new()
	result.seed = seed_for(body_id)
	result.gain = NOISE_GAIN
	result.lacunarity = NOISE_LACUNARITY
	result.continent_bounding = _bounding(result.continent_octaves, result.gain)
	result.warp_bounding = _bounding(result.warp_octaves, result.gain)
	result.region_bounding = _bounding(result.region_octaves, result.gain)
	# **The lattice's turn, not its points.** A Fibonacci sphere is the same lattice for every body, so the
	# phase is what makes one world's plates sit somewhere other than another's — and because it moves whole
	# plate boundaries rather than each centre independently, two bodies do not look like one map with the
	# continents jittered.
	result.plate_phase = float(absi(result.seed) % 6283) * 0.001
	result.amplitude = maxf(radius, 0.0) * RELIEF_FRACTION
	return result


## `1 / (1 + g + g² + …)` — the same normaliser `SpacesimCloudField` derived and its GLSL carries, and it is
## **borrowed rather than copied** because it is the one number the CPU and the shader must agree on exactly:
## a second definition is a second normaliser waiting to drift.
static func _bounding(octaves: int, gain: float) -> float:
	return SpacesimCloudField.fractal_bounding(octaves, gain)
