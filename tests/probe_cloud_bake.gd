extends SceneTree
## **What a bake costs, on the GPU — and, only when asked, on the CPU.**
##
##     xvfb-run -a godot-double-mono --path . --script res://tests/probe_cloud_bake.gd
##     PROBE_CPU=1 ...        # and re-measure the CPU column too: minutes, not seconds
##
## **The CPU column is opt-in because it is the slow half by three orders of magnitude** — 8192 × 4096 is
## 246 ms on the GPU and **229 s** on the CPU, so a routine run of this probe would spend four minutes
## re-deriving a number that does not change. Its measured values are recorded in
## `GPU Texture Generation Plan`, and this is how to check them again after the field changes.
##
## **This is trustworthy where a frame time is not.** The number here is CPU-adjacent work around a
## function call, not a window being copied under `xvfb-run` — see `Shader Review 2026-10-17` for the
## measurements that made that distinction necessary.
##
## Sizes are the ones the game actually asks for: the synchronous floor, the 2,048 the width law reaches
## from low orbit, and the 8,192 that a whole-body Earth map saturates at.
##
## `PROBE_SIZES=1024,2048` overrides the list. Each is baked twice per path — once to warm it, once to time
## it — so the shader compile and the first texture allocation are not being measured.

const DEFAULT_SIZES := "256,1024,2048,4096,8192"


func _initialize() -> void:
	var morphology := SpacesimCloudModel.Morphology.new()
	morphology.banding = SpacesimCloudModel.Banding.SHREDDED
	morphology.cells = 6.0
	morphology.ratio = 0.104
	morphology.eddy_angular_scale = 0.021
	var seed := SpacesimCloudField.seed_for("planet:earth", 0)

	var gpu := SpacesimCloudGpu.new()
	var gpu_open := gpu.open()
	if not gpu_open:
		print("GPU unavailable: ", gpu.error())
	# **Off by default.** See the class comment: the CPU path is the reference, not a routine measurement.
	var cpu_wanted := OS.get_environment("PROBE_CPU") == "1"

	# Warm both paths: the compute shader compiles and the first texture allocation happens here.
	if gpu_open:
		gpu.bake(seed, morphology, 64, 32)
	if cpu_wanted:
		SpacesimCloudField.bake(seed, morphology, 64, 32)

	print("")
	print("%10s %12s %12s %10s" % ["width", "cpu ms", "gpu ms", "ratio"])
	var sizes := DEFAULT_SIZES
	var asked := OS.get_environment("PROBE_SIZES")
	if not asked.strip_edges().is_empty():
		sizes = asked
	for text in sizes.split(",", false):
		var width := int(text.strip_edges())
		if width < 2:
			continue
		var height := maxi(width / 2, 1)
		var cpu_usec := 0
		if cpu_wanted:
			var cpu_start := Time.get_ticks_usec()
			SpacesimCloudField.bake(seed, morphology, width, height)
			cpu_usec = Time.get_ticks_usec() - cpu_start
		var gpu_usec := 0
		if gpu_open:
			var gpu_start := Time.get_ticks_usec()
			var image := gpu.bake(seed, morphology, width, height)
			gpu_usec = Time.get_ticks_usec() - gpu_start
			if image == null:
				print("  GPU bake failed at %d: %s" % [width, gpu.error()])
				continue
		print("%10d %12s %12.1f %10s" % [
			width,
			("%.1f" % (cpu_usec / 1000.0)) if cpu_wanted else "-",
			gpu_usec / 1000.0,
			("%.1fx" % (float(cpu_usec) / float(maxi(gpu_usec, 1)))) if cpu_wanted and gpu_usec > 0 else "-"
		])
	if not cpu_wanted:
		print("\n(CPU column skipped — PROBE_CPU=1 re-measures it, in minutes)")
	if gpu_open:
		gpu.close()
	quit()
