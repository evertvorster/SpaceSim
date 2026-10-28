extends RefCounted
## **The surface bake on the GPU** — that it runs, that it produces a usable map, and that it gives every RID
## back.
##
## Two things this suite exists for, and neither can be checked headlessly:
##
## 1. **`create_local_rendering_device()` returns `null` under `--headless`**, so the ordinary suite run never
##    takes this path at all. `SpacesimSurfaceGpu` is nonetheless the build-time bake in flight —
##    `SpacesimSurfaceDistribution.prepare()` calls it synchronously for every body with a surface — so a fault here
##    is a fault on the first frame of the game, not in a probe.
## 2. **The RID count.** The allocator exhaustion that cost this project two flights was allocations never
##    given back, found in a pass that was reading someone else's error. The counter lives on the device
##    because that is where the allocations are.
##
## Run it where the bake is real:
##
##     tests/gpu_check.sh          (xvfb-run, the project's own runner, the GPU suites)
##
## The same split as `tests/shader_check.sh`: headless Godot neither compiles shaders nor draws, and a green
## headless run says nothing about either.

const WIDTH := 64
const HEIGHT := 32


func run(h, _root: Node) -> void:
	print("  surface gpu")

	var gpu := SpacesimSurfaceGpu.new()
	if not gpu.open():
		# **The reported absence, not a silent skip** — the same rule the cloud suite follows, so a run that
		# never reached a device says so rather than looking green.
		h.check(not gpu.error().is_empty(), "without a rendering device the reason is reported: %s" % gpu.error())
		print("    (skipped the bake: no rendering device — run tests/gpu_check.sh)")
		return
	h.check(gpu.live_rids() == 2,
		"an open device holds the shader and the pipeline, and nothing else (%d live)" % gpu.live_rids())

	# **The real entry point**: the plan is what the bake reads, exactly as `prepare()` builds it.
	var plan := SpacesimSurfaceField.plan("planet:earth", 6.371e6)
	var image := gpu.bake(plan, WIDTH, HEIGHT)
	h.check(image != null, "the bake returned a map, not null")
	if image == null:
		h.check(false, "and its error is empty: '%s'" % gpu.error())
		gpu.close()
		return
	h.check(image.get_width() == WIDTH and image.get_height() == HEIGHT,
		"at the size it was asked for (%dx%d)" % [image.get_width(), image.get_height()])
	h.check(image.get_format() == Image.FORMAT_RH,
		"in the half-float format the surface shader samples")

	# **The map has to be a field, not a blank.** A zeroed read-back would satisfy every size check above, and
	# it is the failure a storage-image dispatch has when its uniform set is bound wrong.
	var lowest := INF
	var highest := -INF
	for y in HEIGHT:
		for x in WIDTH:
			var value := image.get_pixel(x, y).r
			lowest = minf(lowest, value)
			highest = maxf(highest, value)
	h.check(highest - lowest > 0.01,
		"and it carries the field rather than a flat read-back (%.3f to %.3f)" % [lowest, highest])

	h.check(gpu.live_rids() == 2,
		"a bake gives back everything it created — only the shader and pipeline remain (%d live)"
			% gpu.live_rids())
	gpu.close()
	h.check(gpu.live_rids() == 0,
		"and closing the device leaves nothing live (%d)" % gpu.live_rids())
