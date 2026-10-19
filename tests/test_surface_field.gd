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
			earth.belt_width, earth.gain, earth.lacunarity]:
		h.check(value > 0.0, "no mechanism is switched off by a zero (%.3f)" % value)
	for octaves in [earth.continent_octaves, earth.ridge_octaves, earth.warp_octaves]:
		h.check(octaves >= 1, "and every octave count is at least one (%d)" % octaves)
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
