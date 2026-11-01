extends RefCounted
## **The surface field's plan** — the numbers the shader is given, and the only part of the field a run with no
## GPU can assert.
##
## The field itself is GLSL and GLSL only: its CPU twin was retired on 2026-10-19 (Evert: *"the CPU version of
## the shader is only to design the shader, and then it gets retired"*), so there is nothing headless to compare
## the shape against — `tests/shader_check.sh` proves it compiles, a throwaway probe under `xvfb-run` measures it
## when a question needs a number, and the picture is the flight. **What is left here is the contract**: the plan
## is deterministic per body, differs between bodies, and is in ranges the shader can use.


func run(h, _root: Node) -> void:
	print("  surface field")
	_test_plan(h)


## The plan: derived from the address, deterministic, and in ranges the shader can use.
func _test_plan(h) -> void:
	var earth := SpacesimSurfaceField.plan("planet:earth", 6.371e6)
	var again := SpacesimSurfaceField.plan("planet:earth", 6.371e6)
	h.check(earth.seed == again.seed and earth.plate_phase == again.plate_phase,
		"a body's plan is the same twice (%d)" % earth.seed)

	# **The address, not a counter**: two bodies in one system must not be one continent repeated.
	var luna := SpacesimSurfaceField.plan("moon:luna", 1.7374e6)
	h.check(earth.seed != luna.seed, "and another body gets another seed")
	h.check(absf(earth.plate_phase - luna.plate_phase) > 1.0e-6,
		"with its plate lattice turned elsewhere (%.3f against %.3f)" % [earth.plate_phase, luna.plate_phase])

	# **The relief is a fraction of the radius**, derived rather than authored: Earth's real spread is 0.14 %
	# of its radius, which is where the constant comes from and what makes 8.9 km come out here.
	h.check_near(earth.amplitude, 6.371e6 * SpacesimSurfaceField.RELIEF_FRACTION,
		"Earth's relief is %.0f m, 0.14 %% of its radius" % earth.amplitude, 1.0)
	h.check(earth.amplitude > 8000.0 and earth.amplitude < 10000.0,
		"which is the order of the real 9 km")

	# Everything the shader reads has to be a number rather than a zero: a frequency of 0 would make a
	# mechanism constant, and a belt width of 0 a field with no boundaries.
	for value in [earth.continent_frequency, earth.ridge_frequency, earth.warp_frequency,
			earth.region_frequency, earth.belt_width, earth.gain, earth.lacunarity]:
		h.check(value > 0.0, "no mechanism is switched off by a zero (%.3f)" % value)
	for octaves in [earth.continent_octaves, earth.ridge_octaves, earth.warp_octaves,
			earth.region_octaves]:
		h.check(octaves >= 1, "and every octave count is at least one (%d)" % octaves)

	# **The region is slower than a plate, and that is the whole point of it**: a plate is about 1/14 of the
	# sphere, so a frequency at or above the continental one would be texture rather than regions.
	h.check(earth.region_frequency < earth.continent_frequency,
		"the region is slower than the within-plate structure (%.2f against %.2f)" % [
			earth.region_frequency, earth.continent_frequency
		])
	# **A share of 0 would make the term a constant and a share of 1 a level that can invert sign**, and either
	# is the mechanism removed by a wrong number rather than by a decision.
	h.check(earth.region_share > 0.0 and earth.region_share < 1.0,
		"the region scales the level by up to %.2fx" % (1.0 + earth.region_share))
	# **The mottling is thinned over low ground, never removed and never amplified**: 0 would make a plain a
	# painted surface with no grain at all, 1 would make the attenuation a no-op.
	h.check(earth.mottle_plain_gain > 0.0 and earth.mottle_plain_gain < 1.0,
		"a sagging plate keeps %.0f %% of the texture" % (earth.mottle_plain_gain * 100.0))
	h.check(earth.gain < 1.0 and earth.lacunarity > 1.0,
		"the spectrum falls off: gain %.2f, lacunarity %.2f" % [earth.gain, earth.lacunarity])
	# The normalisers are the FBM's own, so a sum of octaves comes back on ±1 rather than growing with the
	# octave count — which is what stops a five-octave mechanism outweighing a three-octave one.
	h.check(earth.continent_bounding < 1.0 and earth.continent_bounding > 0.1,
		"and the continental normaliser is %s" % earth.continent_bounding)
	h.check(earth.continent_bounding < earth.warp_bounding,
		"smaller for five octaves (%.4f) than for three (%.4f)" % [
			earth.continent_bounding, earth.warp_bounding
		])

	# ===== THE TWO KERNELS ARE ONE FIELD ======================================================
	#
	# **The compute sources are assembled by the field, and the two kernels must read the same plan block.** Nothing
	# headless can compile a shader, so what is asserted here is the ASSEMBLY: the shared block is placed before either
	# kernel, both kernels use it, and each carries its own bindings and nothing of the other's. The behaviour — that a
	# heights dispatch agrees with a baked texel — is `tests/test_surface_gpu.gd`'s, where a device exists.
	var bake_source := SpacesimSurfaceField.source()
	var heights_source := SpacesimSurfaceField.source_for_heights()
	h.check(
		bake_source.begins_with("#version 450")
			and heights_source.begins_with("#version 450"),
		"both compute sources start with `#version`, because a source string is not preprocessed")
	# **The block before the kernel, or `SurfacePlan` does not exist where it is assembled.** The order is the
	# assembler's, and a reorder would fail to compile rather than silently — but only in the run that compiles it,
	# which is the GPU one.
	for pair in [["the bake", bake_source], ["the heights", heights_source]]:
		var source: String = pair[1]
		h.check(
			source.find("layout(push_constant") >= 0
				and source.find("layout(push_constant") < source.find("layout(local_size"),
			"%s source places the plan's block before its kernel" % pair[0])
		h.check(source.contains("surface_plan_params()"),
			"and the kernel reads the plan through the shared assembly, not a copy of it")
	h.check(heights_source.contains("surface_height(unit, surface_plan_params(), 0.0)"),
		"the heights kernel asks for every octave: footprint 0 is `no limit`, so a point's height never moves with the LOD")
	h.check(not heights_source.contains("imageStore"),
		"and it writes a buffer, not an image — no raster anywhere in the geometry's path")
	# **The launch shapes, by name** — an `xy` image launch against an `x`-only buffer launch. Writing this as "the
	# bake does not mention `.x`" was wrong: `gl_GlobalInvocationID.xy` contains that substring.
	h.check(bake_source.contains("imageStore") and bake_source.contains("local_size_x = 8"),
		"while the bake keeps its storage image and its 8x8 image launch")
	h.check(heights_source.contains("local_size_x = 64, local_size_y = 1"),
		"and the heights kernel is a flat 64-wide launch over a buffer, one dimension")
