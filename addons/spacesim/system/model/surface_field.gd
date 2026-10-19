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
## ## The CPU transcription is TEMPORARY, and that is deliberate
##
## [method height_at] and [method bake_cpu] exist to *design the shader against*: a `double` reference and a
## GLSL transcription can be compared texel for texel while the composition is being tuned, which is how the
## cloud field's port was checked. **They are retired once the shader is right** (Evert, 2026-10-19: *"the
## CPU version of the shader is only to design the shader, and then it gets retired"*) — unlike the cloud
## field, where the CPU path stays because it is also the only route a headless run has.
##
## **The consequence, planned for rather than discovered:** a bake needs a rendering device, so a headless
## run has no surface maps. What the suite can still check is here — the plan's determinism, its ranges, and
## that the plate partition is deterministic too — and the picture is a flight, or a probe under `xvfb-run`.

## Frequencies, in unit-sphere cycles: a feature is `1/frequency` of the sphere across.
##
## **Chosen against the picture the map has to produce**, not derived from anything. The continental
## frequency is the structure *inside* a plate; the continents themselves are the plate partition, which is
## why this can be as low as two and a half without the planet becoming a single blob.
const CONTINENT_FREQUENCY := 2.5
const RIDGE_FREQUENCY := 11.0
const WARP_FREQUENCY := 3.0

## Octaves per mechanism. The interior wants five to carry a coastline's worth of shape; the ridges want
## four for a crest; the warp wants three, because a warp is a displacement and not a texture.
const CONTINENT_OCTAVES := 5
const RIDGE_OCTAVES := 4
const WARP_OCTAVES := 3

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
const CONTINENT_SHARE := 0.12
const RIDGE_STRENGTH := 0.5

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

## The width a map is baked at before anything asks for better, and the width of the **absolute low-pass**
## every distance-invariant reading is taken at (`coarse_lod()` is `log2(width / COARSE_WIDTH)`).
##
## **The second one is a rule, not a tuning**: mip N of a 1,024-wide map and mip N of an 8,192-wide map are
## different low-passes, so a fixed mip index would move the coastline every time the map refined.
const FLOOR_WIDTH := 256
const COARSE_WIDTH := 1024


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
## a second copy of a number the plan already knows, and it would drift. The block is `ivec2` plus seventeen
## 4-byte fields: **76 bytes, and it must be supplied at exactly that size** — the driver rejects both more and
## less (*"requires (76) bytes of push constant data, supplied: (80)"*), unlike a uniform block where padding is
## the caller's to choose.
static func push_constants(plan_data: Plan, width: int, height: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(PUSH_CONSTANT_BYTES)
	bytes.encode_s32(0, width)
	bytes.encode_s32(4, height)
	bytes.encode_s32(8, plan_data.seed)
	bytes.encode_float(12, plan_data.continent_frequency)
	bytes.encode_s32(16, plan_data.continent_octaves)
	bytes.encode_float(20, plan_data.ridge_frequency)
	bytes.encode_s32(24, plan_data.ridge_octaves)
	bytes.encode_float(28, plan_data.warp_frequency)
	bytes.encode_s32(32, plan_data.warp_octaves)
	bytes.encode_float(36, plan_data.warp_strength)
	bytes.encode_float(40, plan_data.ridge_strength)
	bytes.encode_float(44, plan_data.continent_share)
	bytes.encode_float(48, plan_data.plate_bias_share)
	bytes.encode_float(52, plan_data.belt_width)
	bytes.encode_float(56, plan_data.plate_phase)
	bytes.encode_float(60, plan_data.gain)
	bytes.encode_float(64, plan_data.lacunarity)
	bytes.encode_float(68, plan_data.continent_bounding)
	bytes.encode_float(72, plan_data.warp_bounding)
	return bytes


const NOISE_PATH := "res://addons/spacesim/system/model/noise.gdshaderinc"
const FIELD_PATH := "res://addons/spacesim/system/model/surface_field.gdshaderinc"
const KERNEL_PATH := "res://addons/spacesim/system/model/surface_kernel.gdshaderinc"
## 76: `ivec2` plus seventeen 4-byte fields. Exact, not padded — see [method push_constants].
const PUSH_CONSTANT_BYTES := 76


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


# ===== THE CPU TRANSCRIPTION — TEMPORARY, RETIRED WHEN THE SHADER IS RIGHT ============
#
# A `double` mirror of `surface_height()`, for comparing against while the composition is tuned. It follows
# the GLSL call for call, including the swizzle order, the plate loop's tie-breaking and the R3 rotation the
# fbm wrapper applies. Nothing outside the probe should call it.

## One generator per mechanism, built once per bake.
##
## **Built rather than shared**: this is state, and a bake is a long loop. The seeds are the plan's own plus
## the offsets the GLSL uses, so the two paths cannot be told different fields.
static func noises_for(plan_data: Plan) -> Dictionary:
	# **Three warp generators, not one** — the GLSL decorrelates the three components with three seeds, and
	# one generator reused across three swizzles is a different field entirely (found by the probe: the warp
	# disagreed and dragged every mechanism downstream of it along).
	return {
		"continent": _noise(plan_data.seed + 577, plan_data.continent_octaves, plan_data),
		"warp_x": _noise(plan_data.seed + 101, plan_data.warp_octaves, plan_data),
		"warp_y": _noise(plan_data.seed + 211, plan_data.warp_octaves, plan_data),
		"warp_z": _noise(plan_data.seed + 307, plan_data.warp_octaves, plan_data),
		"ridge": _noise(plan_data.seed + 991, 1, plan_data),
	}


static func _noise(seed: int, octaves: int, plan_data: Plan) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = seed
	# The scale is the *caller's*: one unit of noise space per feature, as the cloud field arranges it.
	noise.frequency = 1.0
	noise.fractal_octaves = maxi(octaves, 1)
	noise.fractal_gain = plan_data.gain
	noise.fractal_lacunarity = plan_data.lacunarity
	return noise


## The field at a unit direction, about ±1 — the CPU mirror of `surface_height()`.
static func height_at(unit: Vector3, plan_data: Plan, noises: Dictionary) -> float:
	# The warp: three samples of one generator through three swizzles, exactly as the GLSL writes them.
	var warp := Vector3(
		_fbm(noises["warp_x"], Vector3(unit.y, unit.z, unit.x), plan_data.warp_frequency),
		_fbm(noises["warp_y"], Vector3(unit.z, unit.x, unit.y), plan_data.warp_frequency),
		_fbm(noises["warp_z"], unit, plan_data.warp_frequency)
	)
	var q := (unit + plan_data.warp_strength * warp).normalized()
	var plates := plates_at(q, plan_data.plate_phase, plan_data.belt_width)
	var variation := _fbm(noises["continent"], q, plan_data.continent_frequency)
	var mountains := _ridged(noises["ridge"], q * plan_data.ridge_frequency, plan_data)
	var crest := float(plates["belt"]) * float(plates["belt"])
	return (
		plan_data.plate_bias_share * float(plates["level"])
		+ plan_data.continent_share * variation
		+ plan_data.ridge_strength * mountains * crest
	)


## `surface_plates()`, including its iteration order and its tie-breaking — a nearest-plate test that broke
## ties the other way would put a different plate's level on the same texel.
static func plates_at(q: Vector3, phase: float, belt_width: float) -> Dictionary:
	var nearest := 2.0
	var second := 2.0
	var nearest_index := 0
	for index in SpacesimSurfaceField.PLATE_COUNT:
		var distance := 1.0 - q.dot(plate_centre(index, phase))
		if distance < nearest:
			second = nearest
			nearest = distance
			nearest_index = index
		elif distance < second:
			second = distance
	return {
		"level": plate_level(nearest_index, phase),
		"belt": 1.0 - smoothstep(0.0, maxf(belt_width, 1.0e-4), second - nearest),
	}


## A plate's centre on the Fibonacci lattice — the same three lines as `surface_plate_centre()`.
static func plate_centre(index: int, phase: float) -> Vector3:
	var z := 1.0 - (2.0 * float(index) + 1.0) / float(PLATE_COUNT)
	var ring := sqrt(maxf(1.0 - z * z, 0.0))
	var angle := float(index) * GOLDEN_ANGLE + phase
	return Vector3(ring * cos(angle), z, ring * sin(angle))


## Whether that plate stands or sags, on -1..1 — `surface_plate_level()`, including the bias that keeps a
## *minority* of plates standing (`PLATE_LEVEL_GAIN`/`PLATE_LEVEL_BIAS`, and the GLSL says why).
static func plate_level(index: int, phase: float) -> float:
	return clampf(
		PLATE_LEVEL_GAIN * sin(float(index) * 12.9898 + phase * 7.0) - PLATE_LEVEL_BIAS, -1.0, 1.0
	)


## `pi * (3 - sqrt(5))`, the same golden angle the GLSL carries.
const GOLDEN_ANGLE := 2.3999632297286535
## `SURFACE_PLATES` — how many plates the sphere is partitioned into.
const PLATE_COUNT := 14
## `surface_plate_level()`'s gain and bias: the pair that makes a *minority* of plates stand, so the sea
## level's percentile lands at the foot of the continental mode rather than in the gap between the modes.
const PLATE_LEVEL_GAIN := 3.0
const PLATE_LEVEL_BIAS := 0.55


## `fnl_fbm3()`'s job on the CPU side: `GetNoise` is the R3 rotation and the octave loop, which
## `FastNoiseLite.get_noise_3d()` already is — **including** the `1/(1+g+…)` normalisation, which the GLSL
## is handed rather than deriving.
static func _fbm(noise: FastNoiseLite, sample: Vector3, frequency: float) -> float:
	return noise.get_noise_3d(sample.x * frequency, sample.y * frequency, sample.z * frequency)


## `surface_ridged3()`: one octave per rung, the seed advancing with the rung, `1 - |n|` squared and summed.
static func _ridged(noise: FastNoiseLite, sample: Vector3, plan_data: Plan) -> float:
	var seed := noise.seed
	var sum := 0.0
	var amplitude := 1.0
	var weight := 0.0
	var frequency := 1.0
	for octave in plan_data.ridge_octaves:
		noise.seed = seed + octave
		var value := noise.get_noise_3d(
			sample.x * frequency, sample.y * frequency, sample.z * frequency
		)
		var ridge := 1.0 - absf(value)
		sum += amplitude * ridge * ridge
		weight += amplitude
		amplitude *= plan_data.gain
		frequency *= plan_data.lacunarity
	noise.seed = seed
	return sum / weight


## The whole-body map on the CPU, in `FORMAT_RH` — the bake the probe compares against, and **the only thing
## that can produce a map with no GPU**. Equirectangular, north at the top row, the same mapping the shader
## inverts.
static func bake_cpu(plan_data: Plan, width: int, height: int) -> Image:
	var w := maxi(width, 1)
	var h := maxi(height, 1)
	var noises := noises_for(plan_data)
	var bytes := PackedByteArray()
	bytes.resize(w * h * 2)
	for row in h:
		var v := (float(row) + 0.5) / float(h)
		var latitude := PI * 0.5 - v * PI
		var cos_latitude := cos(latitude)
		var sin_latitude := sin(latitude)
		for column in w:
			var u := (float(column) + 0.5) / float(w)
			var longitude := (u - 0.5) * TAU
			var direction := Vector3(
				cos_latitude * cos(longitude), sin_latitude, cos_latitude * sin(longitude)
			)
			bytes.encode_half((row * w + column) * 2, height_at(direction, plan_data, noises))
	return Image.create_from_data(w, h, false, Image.FORMAT_RH, bytes)
