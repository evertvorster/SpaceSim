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
	_test_the_julia_body(h)


## **A generated body has volume, and subdividing it approaches the true shape.**
##
## Evert, 2026-11-08: *"Just have to be careful which bit of the Julia we pick, so has to have a certain volume"*
## and *"When we subdivide that, we can get closer and closer to the true shape with the subdivisions."* Both are
## properties of the generator, so both are measurable with no renderer: a volume proxy on the outline, and the
## chord error falling as the grid is refined.
func _test_the_julia_body(h) -> void:
	var seed_value := hash("moon:phobos")
	var radii := SpacesimJuliaShape.outline(seed_value)
	h.check(
		radii.size() == SpacesimJuliaShape.OUTLINE_POINTS,
		"the outline has its points (%d)" % radii.size()
	)
	var share := SpacesimJuliaShape.volume_share(radii)
	h.check(
		share >= SpacesimJuliaShape.MIN_VOLUME_SHARE,
		"and Phobos's cross-section keeps enough of its reach to stand on (%.2f of a circle)" % share
	)
	var shortest := INF
	var longest := 0.0
	for r in radii:
		shortest = minf(shortest, r)
		longest = maxf(longest, r)
	h.check(
		longest / shortest <= SpacesimJuliaShape.MAX_RADIUS_RATIO,
		"and is a body rather than a starfish (%.2f : 1)" % (longest / shortest)
	)

	# **Two bodies, two shapes** — the seed picks the constant as well as the proportions.
	var other := SpacesimJuliaShape.outline(hash("moon:deimos"))
	var differs := false
	for index in mini(radii.size(), other.size()):
		if absf(radii[index] - other[index]) > 0.01:
			differs = true
			break
	h.check(differs, "and two bodies are two shapes")

	# **The mesh is the shape, not a sphere.** Its extents across three axes are a rock's, and that is what the
	# volume test above makes possible in the first place.
	var mesh := SpacesimJuliaShape.mesh(seed_value, 11080.0)
	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var lo := Vector3.ONE * INF
	var hi := Vector3.ONE * -INF
	for vertex in vertices:
		lo = Vector3(minf(lo.x, vertex.x), minf(lo.y, vertex.y), minf(lo.z, vertex.z))
		hi = Vector3(maxf(hi.x, vertex.x), maxf(hi.y, vertex.y), maxf(hi.z, vertex.z))
	var size := hi - lo
	var thin := minf(size.x, minf(size.y, size.z))
	var thick := maxf(size.x, maxf(size.y, size.z))
	h.check(
		thick / maxf(thin, 1.0) > 1.4,
		"and it is plainly not a sphere across its axes (%.1f x %.1f x %.1f km)"
			% [size.x / 1000.0, size.y / 1000.0, size.z / 1000.0]
	)

	# **Subdivision converges on the true shape.** The error is the distance from the TRUE surface at a point between
	# two grid samples to the straight chord joining them — the sagitta — and it must fall as the step squared, which
	# is the difference between refining a sampling and merely smoothing a mesh.
	var coarse := _chord_error(seed_value, 11080.0, 1)
	var fine := _chord_error(seed_value, 11080.0, 2)
	h.check(
		fine < coarse * 0.45,
		"and halving the step cuts the chord error by about four (%.2f m to %.2f m)" % [coarse, fine]
	)


## The worst sagitta on the meridian, at a given detail — the measured gap between the body and the mesh that
## approximates it.
static func _chord_error(seed_value: int, radius: float, detail: int) -> float:
	var radii := SpacesimJuliaShape.outline(seed_value)
	var rings := SpacesimJuliaShape.RINGS * detail
	var worst := 0.0
	# **The middle 80 %**, because both ends are a cone point where the taper closes the body: its sagitta is set by
	# the closure rather than by the sampling, so including it would measure the wrong thing.
	var first := int(float(rings) * 0.1)
	var last := int(float(rings) * 0.9)
	for ring in range(first, last - 1):
		var v0 := float(ring) / float(rings - 1)
		var v1 := float(ring + 1) / float(rings - 1)
		var u := 0.25
		var a := SpacesimJuliaShape.surface_point(seed_value, radius, u, v0, radii)
		var b := SpacesimJuliaShape.surface_point(seed_value, radius, u, v1, radii)
		var truth := SpacesimJuliaShape.surface_point(seed_value, radius, u, (v0 + v1) * 0.5, radii)
		worst = maxf(worst, truth.distance_to((a + b) * 0.5))
	return worst


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

	# **Metres per FIELD UNIT**, derived rather than authored — and re-derived on 2026-11-02 when the field became two
	# crust populations. It used to be 0.14 % of the radius because the field's unit was a half-range about a mean; with
	# the whole range now spanned by real crust levels, one unit of field covers the same 8.9 km of land that it used to
	# cover in 1.55. What matters is not the constant but the product: the land's measured span times this.
	h.check_near(earth.amplitude, 6.371e6 * SpacesimSurfaceField.RELIEF_FRACTION,
		"Earth's scale is %.0f m per field unit, 0.10 %% of its radius" % earth.amplitude, 1.0)
	h.check(earth.amplitude > 5000.0 and earth.amplitude < 8000.0,
		"which puts nine kilometres of land inside the field's own span")

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

	# ===== THE TRANSLATION'S ARITHMETIC =========================================================
	#
	# **What a vertex does when the geometry carries the terrain**, tested without a rendering device: the field's
	# heights are the dispatch's, but the offset applied to a point is plain arithmetic and it is where a wrong datum
	# or a wrong axis would show. Two requirements, and both have flown as faults before: the move is RADIAL, and it
	# measures from the sea level, so a point at the datum does not move.
	var points := PackedVector3Array()
	var directions := PackedVector3Array()
	for index in 4:
		var unit := Vector3(0.0, 1.0, 0.0) if index == 0 else Vector3(
			1.0, 0.0, 0.0
		).rotated(Vector3.UP, TAU * float(index) / 3.0).normalized()
		directions.append(unit)
		points.append(unit * 6.371e6)
	# **One scale, and the datum.** The field now carries the land/ocean asymmetry itself (two crust populations), so
	# the translation is one number per field unit either side of the sea — which is the whole point of the redesign.
	var sea := 0.0
	var amplitude := 8919.0
	var heights := PackedFloat32Array([sea, sea, -1.0, 1.0])
	var before := points.duplicate()
	SpacesimSystemScene.offset_vertices(points, directions, heights, sea, amplitude)
	# **A centimetre, not a micron**: the heights are a `PackedFloat32Array` — the kernel writes floats — so 0.825
	# arrives as 0.82499998 and an 8.9 km amplitude turns that into 1e-4 m. The law is exact; the input is float32.
	h.check_near(points[0].length(), 6.371e6,
		"a vertex whose height IS the sea level does not move at all — the coast is exact by construction", 0.01)
	h.check(points[0].is_equal_approx(before[0]),
		"which is the datum doing its job, not an accident of the numbers")
	h.check_near(points[1].distance_to(before[1]), 0.0,
		"and neither does a second one at the same height", 0.01)
	# **Radial**: the offset is along the direction and nothing else, so a point's angle is unchanged and its radius
	# alone moves. A lateral component would shear the mesh and move a shared point's neighbours with it.
	h.check_near(points[2].normalized().dot(directions[2]), 1.0,
		"a raised point stays on its own radial line", 1.0e-9)
	# **Both directions, one scale**, because a planet's asymmetry is the FIELD's job now and not the translation's.
	h.check_near(points[2].length(), 6.371e6 - amplitude,
		"the field's floor sinks one amplitude below the datum (%.0f m)" % amplitude, 0.01)
	h.check_near(points[3].length(), 6.371e6 + amplitude,
		"and its ceiling stands one amplitude above it (%.0f m)" % amplitude, 0.01)
	h.check(points[3].length() > 6.371e6 and points[2].length() < 6.371e6,
		"so the surface spans both sides of the datum on the same scale: up through the decks, down into the basins")

	# **And on a BARREN body the clamp does nothing, which is the case this surface is for.** `sea_level_percentile`
	# returns the LIQUID fraction of a body's coverage, so a world with no liquid gets 0 and its datum resolves to
	# `value_at(0)` — the field's own floor. Every point is then at or above the datum, so the surface keeps all of its
	# relief and the lowest ground touches the sphere. A clamp that "flattened the low ground" on an airless world would
	# be the sea mechanism leaking into a surface that has none.
	var barren := before.duplicate()
	var floor := -1.0
	var field_heights := PackedFloat32Array([floor, floor, -0.5, 0.5])
	SpacesimSystemScene.offset_vertices(barren, directions, field_heights, floor, amplitude)
	h.check_near(barren[0].length(), 6.371e6,
		"on a barren body the lowest ground sits ON the datum, unclamped", 0.01)
	h.check_near(barren[2].length(), 6.371e6 + 0.5 * amplitude,
		"and every point keeps its own relief above it (%.0f m)" % (0.5 * amplitude), 0.01)
	h.check(barren[2].length() > before[2].length() and barren[3].length() > before[3].length(),
		"which is the whole point: no ground is flattened away on a world with no sea")
