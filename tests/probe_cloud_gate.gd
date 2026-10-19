extends Node
## **Step 1 of the layered field: the supersaturation gate alone.** No cells, no streaks, no eddies —
## just `T_cond − T(lat, h)`, thresholded softly. A probe, not a test: the output is numbers and a picture.
##
##     timeout 60 godot-double-mono --headless --path . res://tests/probe_cloud_gate.tscn
##
## ## Why this goes first
##
## From `Cloud Layers` §8: *"if a derived T(lat) cannot reproduce the band positions that
## `condensation_favouring` gets right by construction, the design needs rethinking before anything is
## built on it."* Everything else in the layered design is built on this gate, so it is checked before
## it is believed.
##
## ## The two terms, and why a monotonic T(lat) cannot make bands
##
## `T(lat) = T_surf * (cos lat)^q / mean(cos^q)` is the **pole-to-equator gradient**, normalised so the
## area-weighted mean is the surface temperature the model already derives. It falls monotonically toward
## the poles, so on its own it puts cloud poleward of **one** latitude — no bands at all.
##
## **The bands come from vertical motion, not from insolation.** Rising air cools adiabatically aloft and
## sinking air warms, so what alternates with latitude is a *temperature anomaly at the level*:
##
##     T_cell(lat) = -A * (2 * favouring(lat) - 1)      # colder where air rises
##
## with `A` in kelvin. That makes `condensation_favouring`'s cosine **a temperature perturbation rather
## than a coverage factor**, which is the whole point: cloud is then a soft threshold on a temperature
## margin, and no latitude multiplies by zero.
##
## `q` and `A` are both calibrations and are swept here. `q = 0.25` is radiative equilibrium with no heat
## transport; smaller is a body that redistributes, and Earth's annual profile sits near 0.25.

const SOL_PATH := "res://systems/sol.tres"
const OUT_DIR := "/tmp/spacesim-clouds/gate"
const WIDTH := 1024
const HEIGHT := 512

## How soft the threshold is, in kelvin. Not a look constant: it is the width of the temperature band over
## which the phase change actually completes, and 2 K is generous rather than tight.
const GATE_WIDTH := 2.0

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	if sol == null:
		print("PROBE: %s did not load" % SOL_PATH)
		get_tree().quit(1)
		return
	var scene := SpacesimSystemScene.from_content(sol)
	if scene == null:
		print("PROBE: the scene did not wrap the system")
		get_tree().quit(1)
		return
	scene.build(self)

	var materials := SpacesimMaterialTable.engine_table()
	var luminosity := SpacesimStarModel.luminosity(scene.star().content)

	print("SpaceSim supersaturation gate probe")
	print("q sweeps the pole-to-equator gradient; A the cell's temperature anomaly in kelvin")
	print("")

	for body_id in ["planet:earth", "planet:jupiter", "planet:venus"]:
		var body := scene.body_by_id(body_id)
		if body == null:
			print("PROBE: no %s" % body_id)
			continue
		_report(body, materials, luminosity, scene.star().position)

	scene.container.free()
	get_tree().quit(0)


func _report(
	body: SpacesimSceneBody, materials: SpacesimMaterialTable, luminosity: float, star_position: Vector3
) -> void:
	var content := body.content
	var morphology := SpacesimCloudModel.morphology(
		content, materials, luminosity, body.position.distance_to(star_position)
	)
	var gravity := SpacesimAtmosphereModel.surface_gravity(content)
	var equilibrium := SpacesimAtmosphereModel.equilibrium_temperature(
		content, materials, luminosity, body.position.distance_to(star_position)
	)
	var levels := SpacesimCloudModel.layers(content.atmosphere, materials, gravity, equilibrium)

	print("%s  %s, cells %.2f, %d level(s)" % [
		body.id, _banding_name(morphology.banding), morphology.cells, levels.size()
	])
	if levels.is_empty():
		print("  no LEVEL-regime condensation level — nothing to gate on")
		print("")
		return

	# **The level seen from outside**, which is the first in `layers()`'s highest-first order.
	var level: SpacesimAtmosphereModel.Condensation = levels[0]
	var species := materials.by_name(level.species)
	if species == null:
		print("  %s has no species row" % level.species)
		print("")
		return
	var condensing := species.condensation_temperature
	var surface_temperature := SpacesimAtmosphereModel.surface_temperature(
		content.atmosphere, materials, gravity, equilibrium
	)
	var lapse := SpacesimAtmosphereModel.lapse_rate(content.atmosphere, materials, gravity)
	var tropopause := SpacesimAtmosphereModel.tropopause_temperature(equilibrium)

	print("  %s at %.0f m; T_cond %.1f K, T_surface %.1f K, lapse %.5f K/m, tropopause %.1f K" % [
		level.species, level.height, condensing, surface_temperature, lapse, tropopause
	])
	print("  %-10s %8s %8s %8s %8s %6s" % [
		"q / A", "min", "max", "mean", "cover", "bands"
	])

	for setup in [[0.25, 0.0], [0.25, 4.0], [0.25, 8.0], [0.15, 4.0], [0.35, 4.0]]:
		var q: float = setup[0]
		var amplitude: float = setup[1]
		var profile := _gate_profile(
			morphology.cells, condensing, level.height, surface_temperature, lapse, tropopause, q, amplitude
		)
		var low := 1.0
		var high := 0.0
		var total := 0.0
		var covered := 0
		for value in profile:
			low = minf(low, value)
			high = maxf(high, value)
			total += value
			if value > 0.5:
				covered += 1
		print("  %-10s %8.3f %8.3f %8.3f %7.1f%% %6d" % [
			"%.2f / %.0f" % [q, amplitude], low, high, total / float(profile.size()),
			100.0 * float(covered) / float(profile.size()), _rises_in(profile)
		])
		if q == 0.25 and amplitude == 4.0:
			_write_map(profile, "%s/%s.png" % [OUT_DIR, body.id.replace("planet:", "")])

	# What the gate has to agree with, for comparison: the cell structure on its own.
	var favouring := PackedFloat32Array()
	for row in HEIGHT:
		var latitude := PI * 0.5 - (float(row) + 0.5) / float(HEIGHT) * PI
		favouring.append(SpacesimCloudModel.condensation_favouring(latitude, morphology.cells))
	print("  condensation_favouring alone: %.0f rises, min %.3f max %.3f" % [
		_rises_in(favouring), _lowest(favouring), _highest(favouring)
	])
	print("")


## The gate as a 1-D profile of latitude, north pole first — the same row order a map uses.
func _gate_profile(
	cells: float, condensing: float, height: float, surface_temperature: float,
	lapse: float, tropopause: float, q: float, amplitude: float
) -> PackedFloat32Array:
	var profile := PackedFloat32Array()
	var mean_cos_q := _mean_of_cos_power(q)
	for row in HEIGHT:
		var latitude := PI * 0.5 - (float(row) + 0.5) / float(HEIGHT) * PI
		var cos_latitude := maxf(cos(latitude), 0.0)
		# The pole-to-equator gradient, normalised to the model's own surface temperature.
		var surface := surface_temperature * pow(cos_latitude, q) / mean_cos_q
		var at_level := SpacesimAtmosphereModel.temperature_at(
			height, surface, lapse, tropopause
		)
		# **Vertical motion as a temperature anomaly at the level**, not as a coverage factor.
		var favouring := SpacesimCloudModel.condensation_favouring(latitude, cells)
		at_level -= amplitude * (2.0 * favouring - 1.0)
		var margin := condensing - at_level
		profile.append(smoothstep(-GATE_WIDTH, GATE_WIDTH, margin))
	return profile


## The area-weighted mean of `cos^q`, so `T(lat)` averages to the model's surface temperature.
func _mean_of_cos_power(q: float) -> float:
	var total := 0.0
	var weight := 0.0
	for index in 2048:
		var latitude := -PI * 0.5 + (float(index) + 0.5) / 2048.0 * PI
		var cos_latitude := maxf(cos(latitude), 0.0)
		total += pow(cos_latitude, q) * cos_latitude
		weight += cos_latitude
	return total / weight


## Write the profile as a map, repeated across longitude, so the gate can be looked at as a layer.
func _write_map(profile: PackedFloat32Array, path: String) -> void:
	var bytes := PackedByteArray()
	bytes.resize(WIDTH * HEIGHT)
	for row in HEIGHT:
		var value := int(clampf(profile[row], 0.0, 1.0) * 255.0)
		for column in WIDTH:
			bytes[row * WIDTH + column] = value
	var image := Image.create_from_data(WIDTH, HEIGHT, false, Image.FORMAT_L8, bytes)
	var error := image.save_png(path)
	if error != OK:
		print("  PROBE: could not write %s (error %d)" % [path, error])


func _rises_in(profile: PackedFloat32Array) -> int:
	var rises := 0
	for index in range(1, profile.size() - 1):
		if profile[index] > 0.5 and profile[index - 1] <= 0.5:
			rises += 1
	return rises


func _lowest(profile: PackedFloat32Array) -> float:
	var low := 1.0
	for value in profile:
		low = minf(low, value)
	return low


func _highest(profile: PackedFloat32Array) -> float:
	var high := 0.0
	for value in profile:
		high = maxf(high, value)
	return high


func _banding_name(banding: int) -> String:
	match banding:
		SpacesimCloudModel.Banding.BANDED:
			return "BANDED"
		SpacesimCloudModel.Banding.SHREDDED:
			return "SHREDDED"
		SpacesimCloudModel.Banding.FEATURELESS:
			return "FEATURELESS"
		_:
			return "UNKNOWN"
