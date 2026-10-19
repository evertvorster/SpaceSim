extends RefCounted
## The surface field's plan and its plate partition — everything about it that a run with no GPU can still
## assert.
##
## **The baked map is not here**, and that is deliberate: the GLSL is the only implementation of the field
## (Evert, 2026-10-19: *"the CPU version of the shader is only to design the shader, and then it gets
## retired"*), and a bake needs a rendering device. What remains headless is what the shader is *given* —
## the numbers off the plan, and the plate lattice that the field's whole shape rests on — plus the CPU
## transcription while it exists, which `tests/probe_surface_field.gd` compares against the GLSL under
## `xvfb-run`.
##
## The lattice and the plate levels are checked here rather than in the probe because **both are
## cross-language invariants**: the GLSL recomputes them from the same arithmetic, so a change to either
## side that is not made in both would put a different planet under the same map.


func run(h, _root: Node) -> void:
	print("  surface field")
	_test_plan(h)
	_test_plate_lattice(h)
	_test_the_field(h)


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


## The plate partition: a lattice of unit points, and a *minority* of them standing.
func _test_plate_lattice(h) -> void:
	var phase := 5.584
	var standing := 0
	var sagging := 0
	var off_sphere := 0.0
	for index in SpacesimSurfaceField.PLATE_COUNT:
		off_sphere = maxf(off_sphere, absf(SpacesimSurfaceField.plate_centre(index, phase).length() - 1.0))
		var level := SpacesimSurfaceField.plate_level(index, phase)
		if level >= 1.0:
			standing += 1
		if level <= -1.0:
			sagging += 1
	# **A standing minority is the point** — see `surface_plate_level` in the GLSL: as many plates up as down
	# puts the sea level's percentile in the gap between the modes, which drowns every continent to its peaks.
	h.check(standing > 0 and sagging > 0,
		"some plates stand and some sag (%d up, %d down)" % [standing, sagging])
	h.check(standing < sagging,
		"and the standing ones are the minority — %d of %d" % [standing, SpacesimSurfaceField.PLATE_COUNT])

	# The normals, since it is a *lattice* on the sphere: every point a unit vector, and the phase turns it.
	h.check_near(off_sphere, 0.0, "every lattice point is a unit vector", 1.0e-12)

	var other := SpacesimSurfaceField.plate_centre(3, phase + 1.0)
	var base := SpacesimSurfaceField.plate_centre(3, phase)
	h.check(absf(other.dot(base)) < 0.999,
		"and the phase turns the lattice rather than being decorative")


## The field as a function of direction — the CPU transcription's arithmetic, which the GLSL mirrors.
func _test_the_field(h) -> void:
	var plan := SpacesimSurfaceField.plan("planet:earth", 6.371e6)
	var noises := SpacesimSurfaceField.noises_for(plan)
	var current := Vector3(0.3, 0.4, 0.87).normalized()

	# **A function of direction and nothing else**: the same direction gives the same height, because that is
	# what lets two levels of the quadtree agree at a shared vertex.
	var first := SpacesimSurfaceField.height_at(current, plan, noises)
	h.check_near(SpacesimSurfaceField.height_at(current, plan, noises), first,
		"the same direction gives the same height twice (%.4f)" % first, 1.0e-12)

	# Bounded, and by the shares it is built from rather than by a clamp: the plate level is ±1, the interior
	# and the ridges are ±1 each, so 1.35 is the arithmetic ceiling and anything past it is a bug.
	var low := 1.0e9
	var high := -1.0e9
	var total := 0.0
	var samples := 200
	for index in samples:
		var t := float(index) / float(samples)
		var direction := Vector3(cos(TAU * t), sin(TAU * t * 3.0) * 0.8, sin(TAU * t)).normalized()
		var value := SpacesimSurfaceField.height_at(direction, plan, noises)
		low = minf(low, value)
		high = maxf(high, value)
		total += value
	h.check(low > -1.5 and high < 1.5, "and it stays inside its shares (%.3f .. %.3f)" % [low, high])
	h.check(high - low > 0.5, "with real relief across the sphere (%.3f)" % (high - low))

	# **Inside a plate vs at a boundary**, which is the mechanism: the belt is 0 well inside a plate and 1 on
	# an edge, and the cell the centre lands in is its own.
	var centre := SpacesimSurfaceField.plate_centre(4, plan.plate_phase)
	var inside := SpacesimSurfaceField.plates_at(centre, plan.plate_phase, plan.belt_width)
	h.check_near(float(inside["belt"]), 0.0,
		"a plate's own centre is not near a boundary", 1.0e-9)
	h.check_near(float(inside["level"]), SpacesimSurfaceField.plate_level(4, plan.plate_phase),
		"and it belongs to that plate", 1.0e-9)

	# A direction halfway between two centres is a boundary: find one by walking from a centre toward the next.
	var a := SpacesimSurfaceField.plate_centre(4, plan.plate_phase)
	var b := SpacesimSurfaceField.plate_centre(5, plan.plate_phase)
	var belt_seen := 0.0
	for index in range(1, 20):
		var t := float(index) / 20.0
		var between := a.slerp(b, t)
		belt_seen = maxf(belt_seen, float(
			SpacesimSurfaceField.plates_at(between, plan.plate_phase, plan.belt_width)["belt"]
		))
	h.check(belt_seen > 0.5,
		"and walking between two plates does cross a belt (%.3f at its strongest)" % belt_seen)
