extends SceneTree
## **The surface field's CPU transcription against the GLSL** — the probe that designs the shader, and which
## is deleted with the CPU code when the shader is right.
##
##     xvfb-run -a godot-double-mono --path . --script res://tests/probe_surface_field.gd
##
## **A probe rather than a suite member**, because the arrangement is temporary: `surface_field.gdshaderinc`
## is the single implementation, and `SpacesimSurfaceField.height_at()`/`bake_cpu()` exist only to compare
## against while the composition is tuned (Evert, 2026-10-19: *"the CPU version of the shader is only to
## design the shader, and then it gets retired"*). When it retires, this file goes with it.
##
## Three things are checked, and the first two are the ones that would cost a flight:
##
##  1. **the two paths agree**, texel for texel, to `R16F`'s own precision — half float carries about 11
##     significand bits, so the tolerance is a couple of parts in a thousand and *not* a byte level;
##  2. **`FORMAT_RH` mips**, because the whole surface LOD rests on a mip chain being a low-pass: if
##     `Image.generate_mipmaps()` refuses a half-float format, the coarse reading the coastline depends on
##     does not exist;
##  3. **the distribution**, printed — the plate heights are bimodal by construction, and the sea level is a
##     percentile of this, so a shift here moves every coastline on every body.
##
## `PROBE_SIZES=256,1024` overrides the sizes; the default is small, because the CPU half is the slow half.

const DEFAULT_SIZES := "96x48,256x128"
## Half float: 11 significand bits, so ~5e-4 near 1.0. Two of those is the tolerance the *format* imposes;
## anything larger is the field disagreeing with itself.
const TOLERANCE := 1.0e-3


func _initialize() -> void:
	var gpu := SpacesimSurfaceGpu.new()
	if not gpu.open():
		print("GPU unavailable: ", gpu.error())
		quit(1)
		return

	for body_id in ["planet:earth", "moon:luna"]:
		var plan := SpacesimSurfaceField.plan(body_id, 6.371e6)
		print("--- %s  seed %d  phase %.3f  amplitude %.0f m" % [
			body_id, plan.seed, plan.plate_phase, plan.amplitude
		])
		for entry in OS.get_environment("PROBE_SIZES").split(",", false) if OS.get_environment("PROBE_SIZES") != "" else DEFAULT_SIZES.split(","):
			var parts := String(entry).split("x")
			var width := int(parts[0])
			var height := int(parts[1])
			_compare(gpu, plan, width, height)

	_check_mipmaps()
	gpu.close()
	print("the probe is a design tool: delete it with the CPU transcription")
	quit(0)


func _compare(gpu: SpacesimSurfaceGpu, plan: SpacesimSurfaceField.Plan, width: int, height: int) -> void:
	var gpu_image := gpu.bake(plan, width, height)
	if gpu_image == null:
		print("    FAIL  the GPU bake failed: %s" % gpu.error())
		return
	# **The map as a picture, for looking at rather than measuring.** This is *data* rather than a render:
	# nothing here is exposure, tonemap or a camera, so it answers "does the field have continents, plate
	# boundaries and belts" — which no statistic does. 0.5 is mid-grey, sea level is a percentile of this.
	if OS.get_environment("PROBE_IMAGE") != "":
		var picture := Image.create_empty(width, height, false, Image.FORMAT_L8)
		for row in height:
			for column in width:
				var value := clampf(0.5 + 0.5 * gpu_image.get_pixel(column, row).r, 0.0, 1.0)
				picture.set_pixel(column, row, Color(value, value, value, 1.0))
		var path := "%s/%s.png" % [OS.get_environment("PROBE_IMAGE"), plan.seed]
		picture.save_png(path)
		print("    map written to ", path)
	var cpu_image := SpacesimSurfaceField.bake_cpu(plan, width, height)

	var worst := 0.0
	var differing := 0
	var total := 0
	var low := 1.0
	var high := -1.0
	var sum := 0.0
	for row in height:
		for column in width:
			var gpu_value := gpu_image.get_pixel(column, row).r
			var cpu_value := cpu_image.get_pixel(column, row).r
			var difference := absf(gpu_value - cpu_value)
			worst = maxf(worst, difference)
			if difference > TOLERANCE:
				differing += 1
			sum += gpu_value
			low = minf(low, gpu_value)
			high = maxf(high, gpu_value)
			total += 1

	print("    %dx%d  gpu %.1f/%s ms  worst diff %.5f  over-tolerance %.2f%%  range %.3f..%.3f  mean %.3f" % [
		width, height,
		gpu.last_microseconds.get("dispatch", 0) / 1000.0,
		str(gpu.last_microseconds.get("readback", 0) / 1000.0) + " readback",
		worst, 100.0 * float(differing) / float(maxi(total, 1)), low, high,
		sum / float(maxi(total, 1))
	])
	if differing > 0:
		print("    ^ %d of %d texels differ by more than %.4f" % [differing, total, TOLERANCE])
	# **The distribution, because the sea level is a percentile of it.** Printed as quantiles rather than a
	# histogram: what matters is where the ocean's fraction falls, and whether the middle of the distribution
	# is flat (a plateau that would draw a planet of shelf) or two clumps (the bimodal hypsometry a plate
	# partition is supposed to produce).
	var values := PackedFloat32Array()
	for row in height:
		for column in width:
			values.append(gpu_image.get_pixel(column, row).r)
	values.sort()
	var quantiles := PackedStringArray()
	for share in [0.05, 0.25, 0.5, 0.75, 0.95]:
		var index := clampi(int(share * float(values.size() - 1)), 0, values.size() - 1)
		quantiles.append("p%d %.3f" % [int(share * 100.0), values[index]])
	print("    quantiles: " + ", ".join(quantiles))


## **A mip chain on `FORMAT_RH`** — the one thing the whole coarse reading rests on.
func _check_mipmaps() -> void:
	var image := Image.create_empty(64, 32, false, Image.FORMAT_RH)
	image.fill(Color(0.5, 0.0, 0.0, 1.0))
	var status := image.generate_mipmaps()
	if status != OK:
		print("    FAIL  FORMAT_RH refuses mipmaps (error %d) — the coarse low-pass has no home" % status)
		return
	var levels := image.get_mipmap_count()
	# **Read through the raw data**, because `Image` has no per-mip pixel accessor: `get_mipmap_offset()`
	# gives the byte offset of a level, and `FORMAT_RH` stores one half float there.
	var coarse := 0.0
	if levels >= 2:
		coarse = image.get_data().decode_half(image.get_mipmap_offset(2))
	print("    FORMAT_RH mips: %d levels, a constant field reads %.4f at level 2" % [levels, coarse])
	if levels < 2:
		print("    FAIL  FORMAT_RH produced fewer than two mip levels — the coarse low-pass has no home")
	elif absf(coarse - 0.5) > TOLERANCE:
		print("    FAIL  mipping FORMAT_RH did not average the value it was given")
