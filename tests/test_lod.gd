extends RefCounted
## The LOD law: geometric error in pixels rather than a triangle count.
##
## **The law itself is pure arithmetic**, so all of it is checkable with no GPU — which is the reason to
## do it before there is an icosphere to point it at, and why the assertions are values and boundaries
## rather than pictures. The second half checks the *application*: that a built scene hands its bodies
## the levels the law asks for, that the meshes really are shared icosphere levels, and that a body
## sitting on a crossing does not flicker. That part needs nodes but still no GPU.
##
## What neither half can check is whether `epsilon` is the right number. That is a render set and a
## judgement, and it comes later (phase 5 of the mesh LOD plan).
##
## The numbers are the plan's own worked table (§2), recomputed. **Where the plan and the arithmetic
## disagree the arithmetic wins and the plan gets corrected** — the project's standing rule — and two
## disagreements are recorded in the comments below rather than absorbed.

const RENDER_HEIGHT := 1080.0 ## The render target's height, which the law must be built on
const FOV := 70.0 ## `camera.fov`'s default, and what the game runs at
const EARTH_RADIUS := 6.371e6
const AU := 1.495978707e11
const SOL_PATH := "res://systems/sol.tres"
const BUDGET := 4.0 ## `lod.error_budget`'s default, and what the headless suite sees
const CENTRE_PIXEL_ANGLE := 1.2966806e-3 ## Radians subtended by the centre pixel of a 1080p 70-degree frame: 2*tan(35 deg)/1080


func run(h, root: Node) -> void:
	print("  lod")
	_test_the_law(h)
	_test_the_scene_applies_it(h, root)


func _test_the_law(h) -> void:

	var p := SpacesimLod.pixel_angle(FOV, RENDER_HEIGHT)

	# --- the pixel, which is the law's unit ---------------------------------------------------------
	# **The plan wrote 1.13e-3 rad, 0.065 degrees, and that is the frame's AVERAGE pixel angle** — `fov/H`
	# — not the centre pixel's. `2*tan(fov/2)/H` is what the statement of the law asks for and what a
	# projection actually is, and at 70 degrees the two differ by 15%: 0.0743 degrees at the centre
	# against 0.0648 averaged over the frame. Recorded rather than absorbed, because `epsilon` is
	# calibrated against whatever pixel size it was judged with, and a 15% error in `p` is a 15% error
	# in every triangle count.
	h.check_near(p, CENTRE_PIXEL_ANGLE,
		"a pixel at the centre of a 1080p 70-degree frame is %.4f degrees" % rad_to_deg(p), 1.0e-9)
	h.check(rad_to_deg(p) > 0.07 and rad_to_deg(p) < 0.08,
		"which is the centre pixel and NOT the 0.0648-degree frame average the plan first recorded")
	h.check(SpacesimLod.pixel_angle(FOV, 0.0) == 0.0,
		"and a frame with no height has no pixels rather than a division by nothing")

	# --- the plan's worked table, recomputed --------------------------------------------------------
	# Angular radius and screen radius, at the three distances the plan's §2 table names. It is the
	# **radius** in both columns there, and its 1 au row is not: 0.073 px is the DIAMETER, twice the
	# 0.033 this gives. That row is the one the plan's own argument rests on — "a body at 1 au is 0.073
	# px across and still gets 16,384 triangles" — and it holds either way, since the level is 0 well
	# below a pixel. So this is a correction to the table, not to the conclusion.
	var at_one_au := SpacesimLod.angular_radius(EARTH_RADIUS, AU)
	h.check_near(at_one_au, 4.2588e-5, "Earth at one au subtends %.6f degrees of radius"
		% rad_to_deg(at_one_au), 1.0e-9)
	var one_au_px := SpacesimLod.screen_radius_pixels(at_one_au, p)
	h.check(one_au_px < 0.1,
		"which is %.4f px of radius — %.4f px across, against the plan's 0.073 px column, and the "
			% [one_au_px, one_au_px * 2.0]
			+ "difference is the two pixel angles, not a disagreement about the body")

	var orbit := SpacesimLod.angular_radius(EARTH_RADIUS, 1.0e8)
	h.check_near(rad_to_deg(orbit), 3.6533, "Earth at 100,000 km subtends 0.0638 rad of radius", 1.0e-3)
	var orbit_px := SpacesimLod.screen_radius_pixels(orbit, p)
	h.check(orbit_px > 45.0 and orbit_px < 55.0,
		"which is %.1f px — the plan's 57 px at its own pixel angle" % orbit_px)

	var close := SpacesimLod.angular_radius(EARTH_RADIUS, 1.0e7)
	var close_px := SpacesimLod.screen_radius_pixels(close, p)
	h.check(close_px > 600.0 and close_px < 700.0,
		"and at 10,000 km %.0f px, against the plan's 611 — the projection it linearised" % close_px)

	# --- the levels, against the law's own triangle column ------------------------------------------
	# `N ~ 5 * r_px / epsilon`, quantised up to the icosphere's `20 * 4^k`. The plan's table gives ~280
	# triangles for the 100,000 km case at epsilon 1 and ~70 at epsilon 4; these are the levels those
	# counts land in.
	h.check(SpacesimLod.level_for_screen_radius(orbit_px, 4.0) == 1,
		"Earth at 100,000 km takes level 1 — 80 triangles — at a 4 px budget")
	h.check(SpacesimLod.level_for_screen_radius(orbit_px, 1.0) == 2,
		"and level 2 at a 1 px budget, which is what a tighter budget buys")
	h.check(SpacesimLod.level_for_screen_radius(close_px, 4.0) == 3,
		"a body at 10,000 km takes level 3")
	h.check(SpacesimLod.level_for_screen_radius(one_au_px, 1.0) == 0,
		"and a sub-pixel body takes the coarsest level there is, which is the floor rather than a cull "
		+ "— deciding not to draw it is the cull's business, not the law's")

	# Deep space, as the game's own default start is: the numbers phase 0 measured.
	var deep := SpacesimLod.screen_radius_pixels(SpacesimLod.angular_radius(EARTH_RADIUS, 9.95e9), p)
	h.check(deep > 0.4 and deep < 0.6,
		"from 9.95 Gm — where the game begins — a planet is %.2f px" % deep)
	h.check(SpacesimLod.level_for_screen_radius(deep, 4.0) == 0, "and takes level 0")

	# --- the boundaries, and the direction of travel -------------------------------------------------
	# A level change is a **crossing**, so the boundary is where the policy is wrong if it is wrong
	# anywhere. Level 0 to 1 sits at `20 * 4 / 5.836` = 13.708 px and level 1 to 2 at 54.832, so these
	# straddle them by a tenth of a pixel rather than a hundredth — the comparison is `>=` on a float
	# count, and a boundary test that only passes by rounding is not testing the boundary.
	h.check(SpacesimLod.level_for_screen_radius(13.6, 4.0) == 0,
		"13.6 px needs level 0's 20 triangles, so it stays on level 0")
	h.check(SpacesimLod.level_for_screen_radius(13.8, 4.0) == 1,
		"and a fifth of a pixel past that boundary crosses to level 1")
	h.check(SpacesimLod.level_for_screen_radius(54.7, 4.0) == 1, "54.7 px is still level 1")
	h.check(SpacesimLod.level_for_screen_radius(54.9, 4.0) == 2, "and 54.9 has crossed to level 2")
	h.check(SpacesimLod.level_for_screen_radius(219.3, 4.0) == 2, "219.3 px is still level 2")
	h.check(SpacesimLod.level_for_screen_radius(219.4, 4.0) == 3, "and 219.4 has crossed to level 3")

	# Monotonic in both directions, which is the property the crossing behaviour depends on: more screen
	# means never fewer triangles, and a more generous budget means never more.
	var monotone := true
	for i in 400:
		var radius := float(i) * 8.0
		if SpacesimLod.level_for_screen_radius(radius + 8.0, 4.0) \
				< SpacesimLod.level_for_screen_radius(radius, 4.0):
			monotone = false
		if SpacesimLod.level_for_screen_radius(radius, 8.0) \
				> SpacesimLod.level_for_screen_radius(radius, 0.5):
			monotone = false
	h.check(monotone,
		"a bigger body never takes fewer triangles, and a looser budget never takes more")

	# And it stops: level 6 is the last, so the law cannot ask for a mesh nobody built.
	h.check(SpacesimLod.level_for_screen_radius(1.0e9, 0.25) == SpacesimLod.MAX_LEVEL,
		"a body filling the sky at the tightest budget asks for the last level and no further")

	# --- the levels themselves ----------------------------------------------------------------------
	h.check(SpacesimLod.triangles_at(0) == 20, "a level 0 icosphere is 20 triangles")
	var counts := []
	var total := 0
	for level in 6:
		counts.append(SpacesimLod.triangles_at(level))
		total += SpacesimLod.triangles_at(level)
	h.check(counts == [20, 80, 320, 1280, 5120, 20480],
		"and each subdivision is exactly four times the one before: %s" % [counts])
	h.check(total == 27300,
		"so levels 0 to 5 are %d triangles — 20 * (1+4+16+64+256+1024) — of SHARED mesh data for the "
			% total
			+ "whole engine, against ~16,000 PER BODY before this")

	# Degenerate inputs, which a policy called once a frame for every body will meet.
	h.check(SpacesimLod.level_for_screen_radius(0.0, 4.0) == 0, "a zero-size body takes level 0")
	h.check(SpacesimLod.level_for_screen_radius(-5.0, 4.0) == 0, "and so does a negative one")
	h.check(SpacesimLod.level_for_screen_radius(100.0, 0.0) == 0,
		"and a zero budget is level 0 rather than a division by nothing")
	h.check(SpacesimLod.screen_radius_pixels(0.5, 0.0) == 0.0, "as is a frame with no pixels")
	h.check(SpacesimLod.angular_radius(EARTH_RADIUS, 1.0e3) == PI * 0.5,
		"an observer inside the body is at the horizon, clamped rather than NaN")

	# --- hysteresis, which is what makes a discrete level usable on a continuous input -----------------
	# **A crossing is a place a body can sit.** Level 2 gives way to 3 at `320 * 4 / 5.836` = 219.33 px,
	# and without a dead band a body hovering there — which is any body under manual throttle — swaps
	# meshes on the frames its screen radius jitters across.
	var crossing := SpacesimLod.level_exit(2, BUDGET)
	h.check_near(crossing, 219.33, "level 2 gives way to level 3 at %.2f px" % crossing, 0.01)

	# Climbing from level 2: held below the crossing plus the band, released past it.
	h.check(SpacesimLod.level_with_hysteresis(2, crossing, BUDGET) == 2,
		"a body at the crossing keeps the coarser level rather than flapping onto the finer one")
	h.check(SpacesimLod.level_with_hysteresis(2, crossing * 1.05, BUDGET) == 2,
		"and it is still held five percent past it")
	h.check(SpacesimLod.level_with_hysteresis(2, crossing * 1.2, BUDGET) == 3,
		"but twenty percent past, it has clearly grown and takes level 3")

	# And descending, where the band is on the other side.
	h.check(SpacesimLod.level_with_hysteresis(3, crossing * 0.95, BUDGET) == 3,
		"coming back down, level 3 is kept five percent below the crossing")
	h.check(SpacesimLod.level_with_hysteresis(3, crossing * 0.85, BUDGET) == 2,
		"and released fifteen percent below it")

	# **A jump of more than one level is flying, not jitter, and is taken at once** — stepping one level
	# per frame would make a fast approach crawl through five levels over five frames of real time.
	h.check(SpacesimLod.level_with_hysteresis(0, crossing * 1.05, BUDGET) == 3,
		"a body two or more levels out takes the level it has earned immediately")
	h.check(SpacesimLod.level_with_hysteresis(5, crossing * 0.1, BUDGET) == 1,
		"in either direction — five levels down to one, at once")
	h.check(SpacesimLod.level_with_hysteresis(2, crossing, BUDGET, 0.0)
			== SpacesimLod.level_for_screen_radius(crossing, BUDGET),
		"and a zero band is exactly the plain policy, so the dead band is not baked into the law")

	# The property that matters in flight: shivering around a crossing moves nothing.
	var held := true
	var settled := 2
	for i in 40:
		var jitter := 1.0 + 0.02 * (1.0 if i % 2 == 0 else -1.0)
		settled = SpacesimLod.level_with_hysteresis(settled, crossing * jitter, BUDGET)
		if settled != 2:
			held = false
	h.check(held, "and forty alternating two-percent jitters around the crossing never move the level")


## That a built scene hands its bodies the levels the law asks for — the wiring, not the arithmetic.
##
## **Headless, because a mesh assignment needs no GPU**: the scene is built, a camera is placed at a
## computed distance, and what the body ends up drawn with is read back. What this cannot check is
## whether a **scaled unit mesh renders correctly under the double-precision vertex emulation** — that is
## a render, and it is the one thing this phase owes Evert's eyes.
func _test_the_scene_applies_it(h, root: Node) -> void:
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	h.check(sol != null, "Sol loads for the scene half")
	if sol == null:
		return
	var scene := SpacesimSystemScene.from_content(sol)
	h.check(scene != null, "a scene wraps it")
	if scene == null:
		return
	scene.build(root)
	var earth := scene.body_by_id("planet:earth")
	if earth == null or earth.node == null:
		h.check(false, "Earth is in it")
		return

	# A camera in the tree, because the pixel angle is measured from the render target rather than from
	# the canvas rect.
	var camera := Camera3D.new()
	camera.fov = FOV
	root.add_child(camera)
	var viewport: Viewport = camera.get_viewport()
	if viewport == null or viewport.size.y <= 0.0:
		h.check(false, "a camera in a tree has a render target to measure")
		camera.queue_free()
		return
	var pixel := SpacesimLod.pixel_angle(camera.fov, float(viewport.size.y))
	h.check(pixel > 0.0, "and the pixel angle comes from that render target")

	# **The geometry is a shared icosphere level, scaled by the body's radius** — which is the whole
	# reason the levels are built at unit radius, and the reason one mesh can serve every body.
	var mesh := earth.mesh
	h.check(mesh.mesh is ArrayMesh and mesh.mesh == SpacesimIcosphere.mesh_at(earth.mesh_level),
		"the body draws the SHARED icosphere mesh for its level")
	h.check(mesh.scale.is_equal_approx(Vector3.ONE * earth.radius),
		"scaled by its own radius, so one mesh of 20 triangles serves a moon and a gas giant alike")
	h.check(not (mesh.mesh is SphereMesh), "and no lat-long sphere is left in the tree")

	# A distance that puts Earth at a chosen screen radius, exactly:
	#   tan(asin(R/d)) = r_px * p   ->   d = R / sin(atan(r_px * p))
	# Measured from the body's own node, so nothing here depends on where the scene was placed.
	var to_earth := Vector3(1.0, 0.0, 0.0)

	_place_at_screen_radius(camera, earth, to_earth, 200.0, pixel)
	scene.update_lod(camera)
	var wanted := SpacesimLod.level_for_screen_radius(200.0, BUDGET)
	h.check(earth.mesh_level == wanted, "at 200 px it takes level %d" % wanted)
	h.check(earth.mesh.mesh == SpacesimIcosphere.mesh_at(earth.mesh_level),
		"and the mesh it is actually drawn with is that level's")

	# Closing the distance never gives a body a coarser mesh — and the ladder is the law's, not a guess:
	# each step is four times the screen radius, which is one level.
	var levels := []
	for step in range(1, 7):
		_place_at_screen_radius(camera, earth, to_earth, pow(4.0, float(step)), pixel)
		scene.update_lod(camera)
		levels.append(earth.mesh_level)
	var rising := true
	for i in range(1, levels.size()):
		if levels[i] < levels[i - 1]:
			rising = false
	h.check(rising, "and closing the distance never gives it a coarser mesh: %s" % [levels])
	h.check(levels == [0, 1, 2, 3, 4, 5],
		"a four-fold step in screen radius is one level, which is what quantisation means: %s" % [levels])

	# **The instrument the plan's first trap names.** If the policy were being computed and not applied,
	# the picture would be unchanged and this number with it.
	var expected := 0
	for body in scene.bodies:
		expected += SpacesimLod.triangles_at(body.mesh_level)
		if body.atmosphere_mesh != null:
			expected += SpacesimLod.triangles_at(SpacesimSystemScene.ATMOSPHERE_SHELL_LEVEL)
	h.check(scene.triangles() == expected,
		"the reported triangle count is the sum of the levels in place, and not a prediction (%d)"
			% expected)

	# The same scene, seen from far away, is a fraction of what it cost before — which is the claim this
	# plan exists to make. The lat-long meshes were 416,000 triangles at every distance (measured,
	# phase 0); a sub-pixel body now takes twenty.
	_place_at_screen_radius(camera, earth, to_earth, 0.4, pixel)
	scene.update_lod(camera)
	h.check(scene.triangles() < 40000,
		"and from far enough out the whole system is under 40,000 triangles against 416,000 (%d)"
			% scene.triangles())

	scene.container.free()
	camera.queue_free()


## Put the camera at the distance where a body's silhouette is `screen_radius` pixels across.
func _place_at_screen_radius(
	camera: Camera3D, body: SpacesimSceneBody, direction: Vector3, screen_radius: float, pixel: float
) -> void:
	var angular := atan(screen_radius * pixel)
	var distance := body.radius / maxf(sin(angular), 1.0e-9)
	camera.global_position = body.node.global_position + direction.normalized() * distance
