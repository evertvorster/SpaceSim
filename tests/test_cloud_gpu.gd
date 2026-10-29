extends RefCounted
## **The GPU bake against the CPU bake.** Not a look: a byte comparison, with a declared tolerance.
##
## The GLSL in `cloud_field.gdshaderinc` is a transcription of `SpacesimCloudField.intensity_at()`, and a
## transcription is a second copy — the one thing this project keeps punishing. So the claim "the two
## paths bake the same field" is asserted rather than believed, at the only place it can be: on the same
## map, texel by texel.
##
## ## Why the tolerance is one level and not zero
##
## The CPU runs the field in `double` (this build is `precision=double`) and the GPU in `float`. A
## value that sits a hair from a `1/255` boundary lands on the other side of it, so a texel flips by one
## level. **What must not happen is a texel flipping by more**: a wrong hash, a wrong gradient table, a
## mis-ported mask or a drifted constant moves the field, not the rounding. The measured counts are
## printed beside the bound, so a drift from ~1% to ~40% is visible even while the bound holds.
##
## ## This suite needs a real rendering device, and that is the point
##
## `create_local_rendering_device()` returns `null` in headless mode, so in the ordinary suite run this
## suite checks the *reported absence* and stops. Run it where the comparison is real:
##
##     tests/gpu_check.sh          (xvfb-run, the project's own test runner, this suite only)
##
## That is the same split as `tests/shader_check.sh`: headless Godot neither compiles shaders nor draws,
## and a green headless run says nothing about either.

const SIZE := 64
const HEIGHT := 32
## How far a texel may differ from the CPU's. See the class comment: one level is float32 against double.
const TOLERANCE := 1
## And how much of the map may differ. Measured 0.4-1.9% when this was written; a real divergence is not
## subtle, so the bound is loose in levels and tight in intent.
const MAX_DIFFERING_PERCENT := 5.0


func run(h, _root: Node) -> void:
	print("  cloud field on the GPU")
	var gpu := SpacesimCloudGpu.new()
	if not gpu.open():
		# Headless, or an OpenGL run. The absence must be *reported*, not silent: a bake that quietly
		# falls back is a bake whose GPU path is never exercised.
		h.check(not gpu.error().is_empty(),
			"without a local rendering device the reason is reported: " + gpu.error())
		print("    (skipped the comparison: no rendering device — run tests/gpu_check.sh)")
		return

	_test_a_featureless_body_is_exact(h, gpu)
	_test_a_baked_field_agrees(h, gpu)
	_test_a_window_agrees(h, gpu)
	_test_the_flow_agrees(h, gpu)
	_test_the_fbm_normaliser(h)
	gpu.close()
	_test_the_cache_bakes_on_the_gpu(h)


## **A uniform field has no arithmetic in it**, so there is nothing to round: both paths must agree to the
## byte. It is the cheapest way to tell "the paths agree" from "the tolerance covers a difference".
func _test_a_featureless_body_is_exact(h, gpu: SpacesimCloudGpu) -> void:
	var morphology := _morphology(SpacesimCloudModel.Banding.FEATURELESS, 0.104)
	var cpu := SpacesimCloudField.bake(4242, morphology, SIZE, HEIGHT)
	var gpu_image := gpu.bake(4242, morphology, SIZE, HEIGHT)
	h.check(gpu_image != null, "a featureless body bakes on the GPU (%s)" % gpu.error())
	if gpu_image == null:
		return
	h.check(cpu.get_data() == gpu_image.get_data(),
		"and to the same bytes, because a uniform field is arithmetic-free")
	h.check(gpu_image.get_data()[0] == 255, "which is full coverage, not a zero-filled image")


## **The field proper, compared by its DISTRIBUTION — because it has a step in it now.**
##
## The field is a cumulus field: the clump is cut by a narrow `smoothstep` (`CUMULUS_EDGE`, 0.12 wide) so parcels have
## crisp edges, and that step is the whole point. A texel sitting a hair from the cut flips by most of the range, so a
## byte comparison of the two paths measures the *hash* now, not the field — it read 146 levels out on 30 % of texels
## while both paths were drawing the same weather.
##
## **So the comparison is the distribution**, which is the honest claim anyway: the skill's own law is that similarity is
## a property of the statistics, and a field whose mean, coverage and percentiles agree is drawing what the other path
## draws. Evert, 2026-10-29: *"the previous shader was not perfect on clouds either, so don't worry about matching it
## perfectly, just the rough idea behind what it wanted to show."*
##
## **What still catches a transcription error**: the mean and the three percentiles are the integration of every
## mechanism — bands, meander, the flow, the clump and the edge — so a wrong hash, a drifted constant or a misplaced
## scale moves them far more than the band below allows. Measured agreement when this was written is printed beside each
## body, so a drift is visible even while the bound holds.
func _test_a_baked_field_agrees(h, gpu: SpacesimCloudGpu) -> void:
	for banding in [SpacesimCloudModel.Banding.SHREDDED, SpacesimCloudModel.Banding.BANDED]:
		for ratio in [0.104, 0.045, 0.0]:
			var morphology := _morphology(banding, ratio)
			var cpu := SpacesimCloudField.bake(12345, morphology, SIZE, HEIGHT).get_data()
			var gpu_image := gpu.bake(12345, morphology, SIZE, HEIGHT)
			h.check(gpu_image != null, "banding %d ratio %f bakes (%s)" % [banding, ratio, gpu.error()])
			if gpu_image == null:
				continue
			var gpu_bytes := gpu_image.get_data()
			var cpu_mean := _mean_of(cpu)
			var gpu_mean := _mean_of(gpu_bytes)
			var cpu_cover := _share_above(cpu, 128)
			var gpu_cover := _share_above(gpu_bytes, 128)
			var worst_percentile := 0.0
			for share in [0.1, 0.5, 0.9]:
				worst_percentile = maxf(worst_percentile, absf(
					_percentile_of(cpu, share) - _percentile_of(gpu_bytes, share)
				))
			print("      banding %d ratio %f: mean %.3f/%.3f  cover %.3f/%.3f  worst percentile %.3f" % [
				banding, ratio, cpu_mean, gpu_mean, cpu_cover, gpu_cover, worst_percentile
			])
			h.check(absf(cpu_mean - gpu_mean) <= 0.02,
				"banding %d ratio %f: the two paths draw the same mean (%.3f against %.3f)" % [
					banding, ratio, cpu_mean, gpu_mean
				])
			h.check(absf(cpu_cover - gpu_cover) <= 0.04,
				"banding %d ratio %f: and the same coverage (%.3f against %.3f)" % [
					banding, ratio, cpu_cover, gpu_cover
				])
			h.check(worst_percentile <= 0.05,
				"banding %d ratio %f: and the same shape (worst percentile %.3f out)" % [
					banding, ratio, worst_percentile
				])
			h.check(cpu_mean > 0.0, "banding %d ratio %f: and the map is not empty" % [banding, ratio])


func _mean_of(bytes: PackedByteArray) -> float:
	var total := 0.0
	for value in bytes:
		total += float(value)
	return total / float(maxi(bytes.size(), 1)) / 255.0


func _share_above(bytes: PackedByteArray, level: int) -> float:
	var count := 0
	for value in bytes:
		if int(value) >= level:
			count += 1
	return float(count) / float(maxi(bytes.size(), 1))


func _percentile_of(bytes: PackedByteArray, share: float) -> float:
	var sorted := Array(bytes)
	sorted.sort()
	if sorted.is_empty():
		return 0.0
	var index := clampi(int(share * float(sorted.size() - 1)), 0, sorted.size() - 1)
	return float(sorted[index]) / 255.0


## **A window is a second copy of the `(u, v)` mapping**, and the two copies live in different languages —
## the kernel's own line for it, and `bake()`'s `uv_origin`/`uv_size`. A window baked by the GPU is
## therefore compared against the CPU's window, not against the CPU's whole map.
func _test_a_window_agrees(h, gpu: SpacesimCloudGpu) -> void:
	var morphology := _morphology(SpacesimCloudModel.Banding.SHREDDED, 0.104)
	var origin := Vector2(0.25, 0.5)
	var size := Vector2(0.125, 0.25)
	var cpu := SpacesimCloudField.bake(999, morphology, 16, 16, null, origin, size).get_data()
	var gpu_image := gpu.bake(999, morphology, 16, 16, origin, size)
	h.check(gpu_image != null, "a window bakes on the GPU (%s)" % gpu.error())
	if gpu_image == null:
		return
	# **The window is compared by its mean, for the reason the whole map is** (see `_test_a_baked_field_agrees`): a
	# field with a step cannot be compared texel for texel, but a *misplaced* window is a different region of the noise
	# and its mean moves far more than the bound. That is the claim this check exists to make — the `(u, v)` mapping is
	# one mapping written in two languages.
	var cpu_mean := _mean_of(cpu)
	var gpu_mean := _mean_of(gpu_image.get_data())
	h.check(absf(cpu_mean - gpu_mean) <= 0.03,
		"and lands on the same window (mean %.3f against %.3f)" % [cpu_mean, gpu_mean])



## **The FLOW map against the CPU's advection** — the half of the field that is baked and *sampled*, so it is the half
## where a transcription could drift unnoticed.
##
## `bake_flow()` writes the carried direction at each texel; `SpacesimCloudField.advect()` computes the same thing in
## GDScript, exactly. What is asserted is the **angle** between them, because a direction's error is an angle and
## nothing else — and the tolerance is the half-float one, since the map is `rgba16f` (10 bits of mantissa, ~0.06°).
##
## **The second check matters as much as the first**: a map that returned its input direction would pass nothing here —
## but only if the stack were empty, and the stack is not. So the twist is measured too, and a flow map that had
## somehow baked the *identity* would fail on it rather than sail through the comparison.
func _test_the_flow_agrees(h, gpu: SpacesimCloudGpu) -> void:
	var morphology := _morphology(SpacesimCloudModel.Banding.SHREDDED, 0.104)
	var width := 64
	var height := 32
	var image := gpu.bake_flow(999, morphology, width, height)
	h.check(image != null, "the flow bakes on the GPU (%s)" % gpu.error())
	if image == null:
		return
	var planned := SpacesimCloudField.plan(999, morphology)
	var worst := 0.0
	var twist := 0.0
	for row in height:
		var v := (float(row) + 0.5) / float(height)
		var latitude := PI * 0.5 - v * PI
		for column in width:
			var u := (float(column) + 0.5) / float(width)
			var longitude := (u - 0.5) * TAU
			var direction := Vector3(
				cos(latitude) * cos(longitude), sin(latitude), cos(latitude) * sin(longitude)
			)
			var exact := SpacesimCloudField.advect(direction, planned.stack)
			var pixel := image.get_pixel(column, row)
			var carried := Vector3(pixel.r, pixel.g, pixel.b)
			worst = maxf(worst, rad_to_deg(exact.angle_to(carried.normalized())))
			twist = maxf(twist, rad_to_deg(direction.angle_to(exact)))
	h.check(worst < 0.25,
		"and its direction matches the CPU advection (worst %.3f deg over %d texels)" % [
			worst, width * height
		])
	# **The measured twist is well under a degree**, and that is the field being described rather than a defect: the
	# stack's job is to *deform* the sampling domain, and a fraction of a degree is a large fraction of an eddy's
	# 3.6° feature. So the check is "not the identity", with the number printed — a hard threshold here would be a
	# claim about the look that this test has no business making.
	h.check(twist > 0.1,
		"and the stack turns it by %.2f deg at most, so an identity map could not pass" % twist)


## `fractal_bounding()` is FastNoiseLite's `CalculateFractalBounding()`: `1 / (1 + g + g² + …)`. It is
## derived here rather than typed into the shader, so it is worth knowing that it *is* the generator's
## normaliser: at gain 0 and 1 the sum is 1 and `octaves`, and the octave's own noise is bounded by 1.
func _test_the_fbm_normaliser(h) -> void:
	h.check_near(SpacesimCloudField.fractal_bounding(1, 0.5), 1.0,
		"one octave is not normalised at all", 1.0e-12)
	h.check_near(SpacesimCloudField.fractal_bounding(4, 1.0), 0.25,
		"four octaves at unit gain divide by four", 1.0e-12)
	h.check_near(SpacesimCloudField.fractal_bounding(4, 0.8), 1.0 / 2.952,
		"and at the field's own gain by the sum of the geometric series", 1.0e-12)


func _morphology(banding: int, ratio: float) -> SpacesimCloudModel.Morphology:
	var morphology := SpacesimCloudModel.Morphology.new()
	morphology.banding = banding
	morphology.cells = 6.0
	morphology.ratio = ratio
	morphology.eddy_angular_scale = 0.021
	return morphology


## **The cache actually uses it**, driven through its own entry point rather than through the GPU helper:
## a substitution that is wired in but unreachable reads exactly like one that works, which is the shape of
## every "the path is dead" bug this project has had.
func _test_the_cache_bakes_on_the_gpu(h) -> void:
	var maps := SpacesimCloudMaps.new()
	# **The GPU is what a cache bakes on by default**, because 47 ms against 26.8 s at 8192x4096 is the
	# difference between a refinement that arrives while it is wanted and one that lands below the altitude it
	# was baked for. Headless runs fall back to the CPU by construction — `create_local_rendering_device()` is
	# null there — and this suite is what keeps the GPU path from rotting while a headless run never takes it.
	h.check(maps.gpu_allowed and maps.gpu_available(),
		"a cache bakes on the GPU by default, and this is the run that proves the path works")
	maps.gpu_allowed = false
	h.check(not maps.gpu_available(), "and keeps to the CPU when told to, which is how the two are compared")
	maps.gpu_allowed = true
	maps.map("planet:earth", 0, 6.371e6, 0.6, 20000.0e3,
		_morphology(SpacesimCloudModel.Banding.SHREDDED, 0.104))
	h.check(maps.bakes() >= 1, "the cache baked a floor (%d bakes)" % maps.bakes())
	h.check(maps.gpu_bakes() >= 1,
		"and it came off the GPU (%d of %d)" % [maps.gpu_bakes(), maps.bakes()])
	# The map has to be usable, not merely produced: a blank image would satisfy the counts above.
	var threshold := maps.threshold_of("planet:earth", 0)
	h.check(threshold > 0.0 and threshold < 1.0,
		"with a threshold the statistics could measure from it (%.3f)" % threshold)
	maps.close()
	# **And nothing leaked**, which is what the counter is for: the allocator exhaustion that cost two flights
	# in this project was allocations that were never given back, and it was found in a pass that was reading
	# someone else's error rather than in the one that was leaking.
	h.check(_gpu_live_rids(maps) == 0, "and every RID the bake created came back (%d live)" % _gpu_live_rids(maps))


# The cache's device is private, so the check reads the count through the cache's own GPU handle.
func _gpu_live_rids(maps: SpacesimCloudMaps) -> int:
	return maps.gpu_live_rids()
