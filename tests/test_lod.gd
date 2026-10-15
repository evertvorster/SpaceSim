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

	# **The budget in force, not the default.** `update_lod` reads `lod.error_budget`, so a scene test
	# that asserted 4.0 would fail the moment anyone trimmed it by flying — which is the point of the
	# trim, and exactly what happened the first time this test ran.
	var budget := float(SpacesimSettings.get_value("lod.error_budget"))
	_place_at_screen_radius(camera, earth, to_earth, 200.0, pixel)
	scene.update_lod(camera)
	var wanted := SpacesimLod.level_for_screen_radius(200.0, budget)
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
	var ladder := true
	for i in levels.size():
		if levels[i] != int(levels[0]) + i:
			ladder = false
	h.check(ladder,
		"and a four-fold step in screen radius is exactly one level, whatever the budget is: %s"
			% [levels])

	# **The instrument the plan's first trap names.** If the policy were being computed and not applied,
	# the picture would be unchanged and this number with it.
	# Counted from the MESHES rather than from the law, so this is an independent check of the HUD's
	# number rather than the same arithmetic twice: `face_count` walks the mesh that is actually there.
	var drawn := 0
	for body in scene.bodies:
		if body.point != null and body.point.visible:
			drawn += SpacesimBodyRenderer.POINT_TRIANGLES
		if body.mesh != null and body.mesh.visible:
			drawn += SpacesimIcosphere.face_count(body.mesh_level)
		if body.atmosphere_mesh != null and body.atmosphere_mesh.visible:
			drawn += SpacesimIcosphere.face_count(body.shell_level)
	h.check(scene.triangles() == drawn,
		"the reported triangle count is what is actually drawn, counted off the meshes (%d)" % drawn)

	# The same scene, seen from far away, is a fraction of what it cost before — which is the claim this
	# plan exists to make. The lat-long meshes were 416,000 triangles at every distance (measured,
	# phase 0); a sub-pixel body now takes twenty.
	_place_at_screen_radius(camera, earth, to_earth, 0.4, pixel)
	scene.update_lod(camera)
	h.check(scene.triangles() < 40000,
		"and from far enough out the whole system is under 40,000 triangles against 416,000 (%d)"
			% scene.triangles())

	# --- the point of light, and the coupling that must NOT exist ---------------------------------
	# **A body too small to be a disc stops being geometry.** Below the threshold its mesh and its air
	# shell go and its splat appears; above it, the other way round. Luna is lit from the star's own
	# direction, so it is a full disc and its luminance is its maximum.
	var luna := scene.body_by_id("moon:luna")
	var star_node := scene.body_by_id("star:sol")
	if luna == null or luna.node == null or luna.point == null:
		h.check(false, "Luna has a point of light")
		scene.container.free()
		camera.queue_free()
		return
	var to_star_from_luna := (star_node.node.global_position - luna.node.global_position).normalized()

	# Just under the threshold: no geometry, a splat, and the splat is the size of the disc it replaces.
	_place_at_screen_radius(camera, luna, to_star_from_luna,
		SpacesimSystemScene.POINT_TIER_SCREEN_RADIUS * 0.9, pixel)
	scene.update_lod(camera)
	h.check(not luna.mesh.visible, "under the threshold a body's mesh is not drawn")
	h.check(luna.atmosphere_mesh == null or not luna.atmosphere_mesh.visible,
		"nor is its air shell — the heavier shader of the two")
	h.check(luna.point.visible, "and its point of light is")
	var luna_distance := camera.global_position.distance_to(luna.node.global_position)
	var expected_size := 2.0 * luna_distance * tan(
		SpacesimLod.angular_radius(luna.radius, luna_distance))
	h.check_near(luna.point.scale.x, expected_size,
		"sized to the disc it would have had, so a body is one continuous object across the handoff",
		expected_size * 1.0e-4)
	var splat := luna.point.material_override as StandardMaterial3D
	h.check(splat != null and splat.blend_mode == BaseMaterial3D.BLEND_MODE_ADD,
		"drawn additively, because a point of light is something seen through the sky behind it")
	h.check(splat != null and splat.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED,
		"and facing the eye, so its size is an angle rather than an orientation")

	# **The exposure cannot tell whether a body is drawn** — the trap the plan names, made into a
	# measurement: if `view_luminance_at` ever learns to skip an invisible body, this goes red, because
	# Luna's mesh is hidden at the moment of the second call and the two must still agree.
	var tan_half := Vector2(tan(deg_to_rad(FOV * 0.5)) * 16.0 / 9.0, tan(deg_to_rad(FOV * 0.5)))
	var looking := (luna.node.global_position - camera.global_position).normalized()
	var observer := camera.global_position
	var culled: float = scene.view_luminance_at(observer, looking, tan_half)
	scene.update_lod(camera)
	var culled_again: float = scene.view_luminance_at(observer, looking, tan_half)
	h.check(culled > 0.0, "a lit body is what the exposure follows even when it is a point (%.4f)" % culled)
	h.check(culled == culled_again,
		"and the sum is the same before and after a cull, so what is drawn cannot change what is lit")

	# Over the threshold the other way round, and the body is still a body the overlay can find.
	_place_at_screen_radius(camera, luna, to_star_from_luna,
		SpacesimSystemScene.POINT_TIER_SCREEN_RADIUS * 10.0, pixel)
	scene.update_lod(camera)
	h.check(luna.mesh.visible, "over the threshold the mesh comes back")
	h.check(luna.atmosphere_mesh == null or luna.atmosphere_mesh.visible, "with its air shell")
	h.check(not luna.point.visible, "and the splat goes")
	var marked := false
	for node in scene.significant_nodes():
		if node == luna.node:
			marked = true
	h.check(marked, "while staying a body the navigation overlay marks, so a dot remains findable")

	# --- a star is a body too -------------------------------------------------------------------------
	# **No body is exempt, the star included** (Evert, 2026-10-15). Its disc is a fraction of a pixel from
	# any distance, so it spends almost all of its time as a point — and it must not vanish there, which
	# is exactly what the reflector formula would do to it: **a star has no albedo, so its luminance is
	# zero.** A star EMITS, and that is the one by-kind difference left.
	_place_at_screen_radius(camera, star_node, Vector3(0.0, 1.0, 0.0), 2.0, pixel)
	scene.update_lod(camera)
	h.check(not star_node.mesh.visible and star_node.point.visible,
		"far enough out, the star is a point of light rather than a sphere, like any other body")
	var sun_colour := (star_node.point.material_override as StandardMaterial3D).albedo_color
	h.check(sun_colour.get_luminance() > 1.0,
		"lit as the star it is — its own emission, not the zero a reflector's albedo would give (%.1f)"
			% sun_colour.get_luminance())

	# --- a planet's point keeps the planet's colour ---------------------------------------------------
	# The splat carries the body's radiance **tinted by the body's own colour and normalised to unit
	# luminance**, so tinting cannot change how bright it is. Without the normalisation the tint would
	# multiply the brightness by the colour's own luminance (~0.3) — a plausible mistake, and the one
	# this measures.
	var mars := scene.body_by_id("planet:mars")
	if mars != null and mars.point != null:
		var to_star := (star_node.node.global_position - mars.node.global_position).normalized()
		_place_at_screen_radius(camera, mars, to_star,
			SpacesimSystemScene.POINT_TIER_SCREEN_RADIUS * 0.5, pixel)
		scene.update_lod(camera)
		h.check(mars.point.visible, "a planet small enough is a point too")
		# **`albedo_color` is sRGB-decoded by Godot**, so the value read back is the *encoded* one and has
		# to be decoded to be comparable with a radiance. Verified in Godot's source: the default spatial
		# material declares `uniform vec4 albedo : source_color` (`scene/resources/material.cpp`).
		var spot := (mars.point.material_override as StandardMaterial3D).albedo_color
		var decoded := spot.srgb_to_linear()
		var expected_radiance := scene.body_luminance(mars, camera.global_position,
			star_node.node.global_position) / SpacesimBodyRenderer.UNIT_LUX_PER_SR
		h.check_near(decoded.get_luminance(), expected_radiance,
			"what arrives in the shader is the body's radiance, unchanged by the tint or the encode",
			maxf(expected_radiance * 0.02, 1.0e-6))
		h.check_near(decoded.r / maxf(decoded.g, 1.0e-6), mars.color.r / maxf(mars.color.g, 1.0e-6),
			"while its HUE is the body's own, so a planet is a coloured point and not a white one",
			1.0e-6)
		# And the round trip itself, which is what makes the line above meaningful rather than a
		# coincidence of two curves that happen to meet.
		var probe := Color(0.37, 0.37, 0.37, 1.0)
		h.check_near(probe.linear_to_srgb().srgb_to_linear().r, probe.r,
			"and the encode is the exact inverse of what Godot decodes, so the two cancel", 1.0e-6)

	# --- the air shell's own rules --------------------------------------------------------------------
	# **A shell's LOD is draw-or-not**, decided by the thickness of the air rather than by the body's
	# angular size: a shell is bigger than the planet it wraps, and from outside what it contributes is
	# the ring between the two radii. Below a pixel of thickness that ring is a smear, not a ring.
	var venus := scene.body_by_id("planet:venus")
	if venus != null and venus.atmosphere_mesh != null:
		# Well outside: Venus's ring is under a pixel, so its shell is not drawn while its disc is.
		_place_at_screen_radius(camera, venus, to_star_from_luna, 6.0, pixel)
		scene.update_lod(camera)
		var venus_distance := camera.global_position.distance_to(venus.node.global_position)
		var ring := SpacesimLod.screen_radius_pixels(
				SpacesimLod.angular_radius(venus.radius + venus.sky_top, venus_distance), pixel) \
			- SpacesimLod.screen_radius_pixels(
				SpacesimLod.angular_radius(venus.radius, venus_distance), pixel)
		h.check(not venus.atmosphere_mesh.visible,
			"a shell whose air is under a pixel thick is not drawn, while the body itself still is (%.3f px)"
				% ring)

		# Close enough for the ring to read: the same body at 40 px.
		_place_at_screen_radius(camera, venus, to_star_from_luna, 40.0, pixel)
		scene.update_lod(camera)
		h.check(venus.atmosphere_mesh.visible, "and one whose air is thick enough on screen is")

		# **An observer inside the shell needs no special case** — the ring test answers yes on its own,
		# because the outer radius clamps to the horizon. Checked rather than trusted, which is the whole
		# point of measuring it this way.
		camera.global_position = venus.node.global_position \
			+ to_star_from_luna * (venus.radius + venus.sky_top * 0.5)
		scene.update_lod(camera)
		h.check(venus.atmosphere_mesh.visible,
			"from INSIDE it, the shell is the sky, and the ring test says so by itself")

		# **The shell wears the body's level** (Evert, 2026-10-15), rather than a fixed one: its ring's
		# outer edge carries the same `sagitta * screen_radius` error the body's silhouette does, at a
		# radius only ~2% larger, so the same level gives the same error to within a level.
		_place_at_screen_radius(camera, venus, to_star_from_luna, 400.0, pixel)
		scene.update_lod(camera)
		# **And its level is its own**, judged on its own metric and a looser budget: an atmosphere's
		# edge is soft, so it may carry an error a planet's could not.
		h.check(venus.atmosphere_mesh.mesh == SpacesimIcosphere.mesh_at(venus.shell_level),
			"and it has a level of its own, which its mesh wears (level %d)" % venus.shell_level)
		h.check(venus.shell_level <= venus.mesh_level,
			"and that level is never finer than the body's own, because its budget is the looser one (%d vs %d)"
				% [venus.shell_level, venus.mesh_level])

	# --- what the dome costs from inside, and why it is not the finest level ---------------------------
	# **From inside there is no silhouette at all**, so the law's input is a *direction* error rather than
	# an edge: `body_atmosphere` casts its ray along `normalize(VERTEX)`, the interpolated position on the
	# triangle, so a facet's deviation tilts every ray by `s` radians — which is `s / p` pixels anywhere on
	# screen. The honest screen radius for it is therefore `1 / p`, and using the clamped angular size
	# instead asks for the finest level there is.
	var inside_distance := venus.radius + venus.sky_top * 0.5
	h.check(venus.atmosphere_mesh.mesh == SpacesimIcosphere.mesh_at(venus.shell_level),
		"inside the shell its mesh is still its own level")
	var from_inside := SpacesimLod.level_with_hysteresis(
		0, 1.0 / pixel, float(SpacesimSettings.get_value("lod.error_budget")) * 4.0)
	h.check(venus.shell_level == from_inside,
		"and that level is the one the direction error earns, not the clamped angular size (%d, so the "
			% venus.shell_level
			+ "dome is %d triangles rather than 81,920)" % SpacesimLod.triangles_at(venus.shell_level))
	h.check(venus.shell_level < SpacesimLod.MAX_LEVEL,
		"which is what keeps a sky dome off the maximum level")

	# --- the point of light must follow the exposure ---------------------------------------------------
	# **Godot does not scale the frame by the camera's exposure; it bakes the factor into the sky and into
	# the light energy.** So a material that is `unshaded` — no light, no sky — receives none of it, and a
	# splat is the one such thing in the 3D pass that is not the star's own disc. Found by flight test:
	# flying toward Venus with Sol entering and leaving the frame stepped the whole sky up and down and left
	# the splat exactly where it was (Evert, 2026-10-15).
	#
	# Pinned here by measuring the ratio, because the symptom is invisible at a multiplier of about 1 —
	# which is where the handoff comparison happened to be measured, and why it looked free.
	var venus_point := venus.point
	if venus_point != null:
		var venus_material := venus_point.material_override as StandardMaterial3D
		var attributes := CameraAttributesPractical.new()
		camera.attributes = attributes
		attributes.exposure_multiplier = 1.0
		_place_at_screen_radius(camera, venus, to_star_from_luna,
			SpacesimSystemScene.POINT_TIER_SCREEN_RADIUS * 0.5, pixel)
		scene.update_lod(camera)
		# Decoded, because the stored value is sRGB-encoded — see `point_colour`. The *ratio* is what this
		# checks, and it is only a ratio in linear terms.
		var at_one := venus_material.albedo_color.srgb_to_linear()
		attributes.exposure_multiplier = 8.0
		scene.update_lod(camera)
		var at_eight := venus_material.albedo_color.srgb_to_linear()
		h.check_near(at_eight.get_luminance(), at_one.get_luminance() * 8.0,
			"a body's point of light scales with the exposure, so it steps with the sky and the surfaces",
			maxf(at_one.get_luminance() * 0.05, 1.0e-9))
		h.check(at_one.get_luminance() > 0.0,
			"and it was not zero to begin with, so the ratio means something (%.6f)" % at_one.get_luminance())

		# **And a star's point is deliberately not scaled**, because its own disc is not either — scaling
		# only the splat would break the handoff the star keeps free.
		attributes.exposure_multiplier = 1.0
		_place_at_screen_radius(camera, star_node, Vector3(0.0, 1.0, 0.0), 2.0, pixel)
		scene.update_lod(camera)
		var sun_one := (star_node.point.material_override as StandardMaterial3D).albedo_color
		attributes.exposure_multiplier = 8.0
		scene.update_lod(camera)
		var sun_eight := (star_node.point.material_override as StandardMaterial3D).albedo_color
		h.check_near(sun_eight.get_luminance(), sun_one.get_luminance(),
			"while a star's point is the same at either exposure, matching its own unshaded disc",
			1.0e-6)
		camera.attributes = null

	scene.container.free()
	camera.queue_free()


## Put the camera at the distance where a body's silhouette is `screen_radius` pixels across.
func _place_at_screen_radius(
	camera: Camera3D, body: SpacesimSceneBody, direction: Vector3, screen_radius: float, pixel: float
) -> void:
	var angular := atan(screen_radius * pixel)
	var distance := body.radius / maxf(sin(angular), 1.0e-9)
	camera.global_position = body.node.global_position + direction.normalized() * distance
