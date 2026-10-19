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


## The field proper: noise, bands, meander, the vortex stack and the soft ceiling, all of it.
func _test_a_baked_field_agrees(h, gpu: SpacesimCloudGpu) -> void:
	for banding in [SpacesimCloudModel.Banding.SHREDDED, SpacesimCloudModel.Banding.BANDED]:
		# Three ratios: a derived wavenumber, a different one, and none at all — which is the branch where
		# the bands stop meandering.
		for ratio in [0.104, 0.045, 0.0]:
			var morphology := _morphology(banding, ratio)
			var cpu := SpacesimCloudField.bake(12345, morphology, SIZE, HEIGHT).get_data()
			var gpu_image := gpu.bake(12345, morphology, SIZE, HEIGHT)
			h.check(gpu_image != null, "banding %d ratio %f bakes (%s)" % [banding, ratio, gpu.error()])
			if gpu_image == null:
				continue
			var gpu_bytes := gpu_image.get_data()
			var worst := 0
			var differing := 0
			var total := 0
			for index in cpu.size():
				total += int(cpu[index])
				var delta := absi(int(gpu_bytes[index]) - int(cpu[index]))
				worst = maxi(worst, delta)
				if delta != 0:
					differing += 1
			var percent := 100.0 * float(differing) / float(cpu.size())
			print("      banding %d ratio %f: %d of %d texels differ (%.2f%%), worst %d level(s)" % [
				banding, ratio, differing, cpu.size(), percent, worst
			])
			h.check(worst <= TOLERANCE,
				"banding %d ratio %f: no texel is more than %d level(s) out (worst %d)" % [
					banding, ratio, TOLERANCE, worst
				])
			h.check(percent <= MAX_DIFFERING_PERCENT,
				"banding %d ratio %f: and %.2f%% of them differ at all, against a %.1f%% bound" % [
					banding, ratio, percent, MAX_DIFFERING_PERCENT
				])
			# The field itself must still be the field: a map that agreed on the mean but lost its
			# structure would pass the two checks above.
			h.check(total > 0, "banding %d ratio %f: and the map is not empty" % [banding, ratio])


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
	var worst := 0
	for index in cpu.size():
		worst = maxi(worst, absi(int(gpu_image.get_data()[index]) - int(cpu[index])))
	h.check(worst <= TOLERANCE, "and lands on the same window (worst %d level(s))" % worst)


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
