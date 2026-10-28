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

	# Deep space, as the game's own default start is: the numbers phase 0 measured.
	var deep := SpacesimLod.screen_radius_pixels(SpacesimLod.angular_radius(EARTH_RADIUS, 9.95e9), p)
	h.check(deep > 0.4 and deep < 0.6,
		"from 9.95 Gm — where the game begins — a planet is %.2f px" % deep)

	# Degenerate inputs, which the projection meets every frame for every body.
	h.check(SpacesimLod.screen_radius_pixels(0.5, 0.0) == 0.0, "a frame with no pixels is zero pixels")
	h.check(SpacesimLod.angular_radius(EARTH_RADIUS, 1.0e3) == PI * 0.5,
		"an observer inside the body is at the horizon, clamped rather than NaN")


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

	# **The surface is a PATCH TREE now, not one shared mesh per level.** Evert, 2026-10-17: *"it
	# suddenly switches to a higher density of triangles, but once only, and for the whole sphere"* — one
	# level per body could only ever do that. So what used to be "the mesh is level N's" is now "the mesh
	# is built from the leaves the eye asked for", and the property worth asserting is the one that was
	# missing: **the detail under the eye grows as it closes in**, while the count overall may fall because
	# the horizon culls more of the body.
	 # A distance that puts Earth at a chosen screen radius, exactly:
	#   tan(asin(R/d)) = r_px * p   ->   d = R / sin(atan(r_px * p))
	var to_earth := Vector3(1.0, 0.0, 0.0)
	# Built by the first `update_lod`, which is what decides what is worth drawing.
	_place_at_screen_radius(camera, earth, to_earth, 200.0, pixel)
	scene.update_lod(camera)
	scene.await_patch_builds()
	var mesh := earth.mesh
	h.check(mesh.mesh is ArrayMesh, "the body draws its own patch mesh")
	# **Unscaled, because the vertices are already metres** measured from the node's own origin — a basis carrying the
	# radius is what rounded them at 0.76 m and made the ground wave. See `SpacesimPatches.rebase`.
	h.check(mesh.scale.is_equal_approx(Vector3.ONE),
		"unscaled — the vertices carry the metres, and the basis stays identity")
	h.check(not (mesh.mesh is SphereMesh), "and no lat-long sphere is left in the tree")

	# **The budget in force, not the default.** `update_lod` reads `lod.error_budget`, so a scene test
	# that asserted 4.0 would fail the moment anyone trimmed it by flying — which is the point of the
	# trim, and exactly what happened the first time this test ran.
	var budget := float(SpacesimSettings.get_value("lod.error_budget"))
	_place_at_screen_radius(camera, earth, to_earth, 200.0, pixel)
	scene.update_lod(camera)
	scene.await_patch_builds()
	var under_eye := _triangles_under_eye(earth, to_earth)
	h.check(under_eye > 0, "at 200 px there are triangles under the eye (%d)" % under_eye)

	# **The refinement itself is measured in `test_patches.gd`**, against an explicit pixel angle and
	# epsilon: that is where the law lives, and it does not need a scene. What this suite is for is that the
	# body is drawn from that selection at all, and that closing in changes what it is drawn with.
	var before := earth.mesh.mesh
	_place_at_screen_radius(camera, earth, to_earth, 4000.0, pixel)
	scene.update_lod(camera)
	scene.await_patch_builds()
	h.check(earth.mesh.mesh != before,
		"and closing in replaces the mesh with the selection that distance asks for")

	# **The instrument the plan's first trap names.** If the policy were being computed and not applied,
	# the picture would be unchanged and this number with it.
	# Counted from the MESHES rather than from the law, so this is an independent check of the HUD's
	# number rather than the same arithmetic twice.
	var drawn := 0
	for body in scene.bodies:
		if body.point != null and body.point.visible:
			drawn += SpacesimBodyRenderer.POINT_TRIANGLES
		if body.mesh != null and body.mesh.visible and body.mesh.mesh != null:
			# **The patches the body is actually drawn with**, counted off its own mesh — a surface has no
			# level any more, so this is the only honest place to read the number.
			# **Counted off the index array**, because the surface is indexed: the vertices are shared, so
			# `size() / 3` on them would report the number of points, not of triangles.
			var arrays: Array = (body.mesh.mesh as ArrayMesh).surface_get_arrays(0)
			drawn += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	h.check(scene.triangles() == drawn,
		"the reported triangle count is what is actually drawn, counted off the meshes (%d)" % drawn)

	# The same scene, seen from far away, is a fraction of what it cost before — which is the claim this
	# plan exists to make. The lat-long meshes were 416,000 triangles at every distance (measured,
	# phase 0); a sub-pixel body now takes twenty.
	_place_at_screen_radius(camera, earth, to_earth, 0.4, pixel)
	scene.update_lod(camera)
	scene.await_patch_builds()
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
		SpacesimLod.POINT_TIER_SCREEN_RADIUS * 0.9, pixel)
	scene.update_lod(camera)
	scene.await_patch_builds()
	h.check(not luna.mesh.visible, "under the threshold a body's mesh is not drawn")
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
	# **Oriented from GDScript, not by the material.** A billboarded material rewrites `MODELVIEW_MATRIX`
	# with `INV_VIEW_MATRIX` — world-space axes against a camera-relative translation — which is the
	# transform chain the double-precision emulation cannot follow, and the project has been bitten by that
	# family twice (`world_vertex_coords`, `triplanar`). The symptom is a quad that lands somewhere other
	# than where the body is **depending on where the camera is**, so it blinks while flying.
	h.check(splat != null and splat.billboard_mode == BaseMaterial3D.BILLBOARD_DISABLED,
		"and the material does NOT billboard it, so the emulated transform is left alone")
	# Normalised, because the size lives on that same basis — the axis points where the eye is, the
	# magnitude is how big the quad is.
	h.check(luna.point.global_transform.basis.z.normalized().is_equal_approx(
			camera.global_transform.basis.z.normalized()),
		"the quad is turned to face the eye by its own basis instead, which is a billboard the "
			+ "double-precision emulation can see")
	var facing_scale := luna.point.global_transform.basis.get_scale()
	h.check(facing_scale.is_equal_approx(Vector3.ONE * expected_size),
		"and it carries its size on that same basis, so nothing has to be preserved by hand")

	# Over the threshold the other way round, and the body is still a body the overlay can find.
	_place_at_screen_radius(camera, luna, to_star_from_luna,
		SpacesimLod.POINT_TIER_SCREEN_RADIUS * 10.0, pixel)
	scene.update_lod(camera)
	scene.await_patch_builds()
	h.check(luna.mesh.visible, "over the threshold the mesh comes back")
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
	scene.await_patch_builds()
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
			SpacesimLod.POINT_TIER_SCREEN_RADIUS * 0.5, pixel)
		scene.update_lod(camera)
		scene.await_patch_builds()
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
		# **Its whole flux into one pixel, once the disc is under a pixel.** Below the floor the value falls
		# as the disc's share of the pixel's solid angle — `pi * r_px^2` — so a body that recedes gets
		# *fainter* rather than staying a full-brightness dot. Measured by walking the distance out and
		# comparing the splat's own value at two radii, because the missing term is what makes a distant
		# planet too bright and nothing else about it is observable in a still.
		# **Both radii BELOW the floor, because that is the only place the law applies.** At 2 px the cap is
		# already holding the value at the radiance, so going from 2 px to 0.2 px only moves the *fade* from
		# 1 to `pi * 0.2^2` — a factor of 8, not the 1/d^2 of 100. The floor sits at `r_px = 1/sqrt(pi)`,
		# about 0.56 px, and under it the value falls as the disc's area.
		var to_star_dir := (star_node.node.global_position - mars.node.global_position).normalized()
		_place_at_screen_radius(camera, mars, to_star_dir, 0.5, pixel)
		scene.update_lod(camera)
		scene.await_patch_builds()
		var at_half := (mars.point.material_override as StandardMaterial3D).albedo_color.srgb_to_linear()
		_place_at_screen_radius(camera, mars, to_star_dir, 0.25, pixel)
		scene.update_lod(camera)
		scene.await_patch_builds()
		var at_quarter := (mars.point.material_override as StandardMaterial3D).albedo_color.srgb_to_linear()
		h.check(at_half.get_luminance() > 0.0 and at_quarter.get_luminance() > 0.0,
			"a body is lit at half a pixel and at a quarter (%.6f against %.6f)"
				% [at_half.get_luminance(), at_quarter.get_luminance()])
		h.check_near(at_quarter.get_luminance(), at_half.get_luminance() * 0.25,
			"and twice as far is a QUARTER as bright, which is the whole flux of a shrinking disc",
			at_half.get_luminance() * 0.02)
		h.check_near(decoded.r / maxf(decoded.g, 1.0e-6), mars.color.r / maxf(mars.color.g, 1.0e-6),
			"while its HUE is the body's own, so a planet is a coloured point and not a white one",
			1.0e-6)
		# And the round trip itself, which is what makes the line above meaningful rather than a
		# coincidence of two curves that happen to meet.
		var probe := Color(0.37, 0.37, 0.37, 1.0)
		h.check_near(probe.linear_to_srgb().srgb_to_linear().r, probe.r,
			"and the encode is the exact inverse of what Godot decodes, so the two cancel", 1.0e-6)

	_test_the_eye_inside_a_body(h, scene, camera, pixel)
	_test_a_frame_change_pays_for_its_geometry(h, scene, camera, earth, pixel)
	_leak(h, scene, camera, earth, pixel)

	# --- the point of light is in the FRAME's exposure, not the camera's ----------------------------
	# **This check used to assert the opposite**, and the reversal is the point. Godot bakes the exposure
	# into the sky and the light energy and *not* into an `unshaded` material, so a splat had to apply
	# `exposure_multiplier` by hand — and found by flight test, flying toward Venus with Sol entering and
	# leaving the frame stepped the whole sky up and down while the splat stayed put (Evert, 2026-10-15).
	#
	# Since `SpacesimExposurePass` scales the **finished frame**, every path is scaled once, by construction,
	# and **no material may apply the camera's exposure itself** — that would be a second application. So the
	# property worth pinning now is the independence: the splat does not move when `exposure_multiplier`
	# does, because the pass moves it with everything else.
	#
	# **Both bodies, and for the same reason.** The star's point used to be the documented exception; it is
	# not one any more, because its disc is in the frame too.
	var venus := scene.body_by_id("planet:venus")
	var venus_point := venus.point
	if venus_point != null:
		var venus_material := venus_point.material_override as StandardMaterial3D
		var attributes := CameraAttributesPractical.new()
		camera.attributes = attributes
		attributes.exposure_multiplier = 1.0
		_place_at_screen_radius(camera, venus, to_star_from_luna,
			SpacesimLod.POINT_TIER_SCREEN_RADIUS * 0.5, pixel)
		scene.update_lod(camera)
		scene.await_patch_builds()
		# Decoded, because the stored value is sRGB-encoded — see `point_colour`.
		var at_one := venus_material.albedo_color.srgb_to_linear()
		attributes.exposure_multiplier = 8.0
		scene.update_lod(camera)
		scene.await_patch_builds()
		var at_eight := venus_material.albedo_color.srgb_to_linear()
		h.check_near(at_eight.get_luminance(), at_one.get_luminance(),
			"a body's point of light does NOT apply the camera's exposure — the pass applies it once",
			maxf(at_one.get_luminance() * 0.001, 1.0e-9))
		h.check(at_one.get_luminance() > 0.0,
			"and it was not zero to begin with, so the comparison means something (%.6f)"
				% at_one.get_luminance())

		# The star's point is in the same position now, which is what its own unshaded disc needs.
		attributes.exposure_multiplier = 1.0
		_place_at_screen_radius(camera, star_node, Vector3(0.0, 1.0, 0.0), 2.0, pixel)
		scene.update_lod(camera)
		scene.await_patch_builds()
		var sun_one := (star_node.point.material_override as StandardMaterial3D).albedo_color
		attributes.exposure_multiplier = 8.0
		scene.update_lod(camera)
		scene.await_patch_builds()
		var sun_eight := (star_node.point.material_override as StandardMaterial3D).albedo_color
		h.check_near(sun_eight.get_luminance(), sun_one.get_luminance(),
			"and a star's point is the same either way, matching its own unshaded disc", 1.0e-6)
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


## **The finest triangle under the eye**, in radians, from a selection: the smallest largest-edge among
## patches whose centre is within about 18 degrees of the direction to the camera.
##
## **Not the leaf count**, which is what the first version of this checked and which *falls* on approach:
## the horizon tightens, the visible cap shrinks, and six big patches can cover it where twenty-eight
## small ones covered a third of the sphere. What "more triangles where you look" means in practice is
## that the triangles there get smaller, so that is the quantity.
static func _finest_under_eye(distance: float, radius: float, to_eye: Vector3, pixel: float, epsilon: float) -> float:
	var finest := 1.0
	for leaf in SpacesimPatches.triangles_of(SpacesimPatches.select(distance, to_eye, radius, pixel, epsilon)):
		var centre: Vector3 = (leaf[0] + leaf[1] + leaf[2]).normalized()
		if centre.dot(to_eye) > 0.95:
			finest = minf(finest, maxf(
				(leaf[0] as Vector3).angle_to(leaf[1]),
				maxf((leaf[1] as Vector3).angle_to(leaf[2]), (leaf[2] as Vector3).angle_to(leaf[0]))
			))
	return finest


## **A rebuild must not leak.** Evert, 2026-10-19: a four and a half minute flight ended in thousands of
## `Element limit reached` errors as the RenderingDevice's RID allocator filled up. The patch path was
## innocent — this is the check that says so, and it stays because the failure mode (a leak per rebuild) is
## invisible until it is catastrophic.
##
## A descent that rebuilds on every frame, which is what flying does, with a census of the engine's own
## object counts: a leaked RID is a leaked Object or Resource before it is anything else.
func _leak(h, scene: SpacesimSystemScene, camera: Camera3D, earth: SpacesimSceneBody, pixel: float) -> void:
	var start_resources := Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	var start_objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var samples := []
	for step in 1200:
		var altitude: float = 2.0e6 * pow(10.0, -3.0 * float(step) / 1200.0)
		camera.global_position = earth.node.global_position \
			+ Vector3(1.0, 0.0, 0.0).rotated(Vector3.UP, float(step) * 0.0005) * (earth.radius + altitude)
		scene.update_lod(camera)
		if step % 300 == 0:
			samples.append(int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)))
	var end_resources := Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	var end_objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	h.check(end_resources - start_resources <= 8 and end_objects - start_objects <= 8,
		"1200 rebuild frames leak nothing (resources %+d, objects %+d)"
			% [end_resources - start_resources, end_objects - start_objects])


## **A frame change is a synchronous rebuild.** Evert, 2026-10-19: *"can't we load the next frame before we
## switch to it?"* — yes, and this is where. The mesh belongs to a viewpoint, so crossing into a new frame
## has to leave a mesh that belongs to the new one, not the previous regime's. What is observable headlessly
## is that the transition pays for the build: no task is left in flight when `update_lod` returns.
func _test_a_frame_change_pays_for_its_geometry(
	h, scene: SpacesimSystemScene, camera: Camera3D, earth: SpacesimSceneBody, pixel: float
) -> void:
	var surface := earth.surface
	if surface == null:
		return
	var atmosphere := earth.atmosphere
	# Into the atmosphere first, from far enough out that the selection is a coarse one.
	if atmosphere != null:
		scene.frame_tree.enter_frame(atmosphere)
	camera.global_position = earth.node.global_position + Vector3(0.0, earth.radius + 1.0e5, 0.0)
	scene.update_lod(camera)
	# Then the landing, **without awaiting between**: the transition itself must join the work.
	scene.frame_tree.enter_frame(surface)
	camera.global_position = earth.node.global_position + Vector3(0.0, earth.radius + 1.5e3, 0.0)
	scene.update_lod(camera)
	h.check(earth.patch_task == -1,
		"crossing into the surface frame leaves no rebuild in flight — the transition paid for it")
	h.check(earth.mesh.mesh is ArrayMesh and earth.patch_triangles > 0,
		"and the mesh it draws is the landing's own (%d triangles)" % earth.patch_triangles)
	# The count is the selection's, not the previous frame's: re-walking the same viewpoint changes nothing.
	var at_landing := earth.patch_triangles
	scene.update_lod(camera)
	h.check(earth.patch_triangles == at_landing,
		"and it is stable — a second frame at the same viewpoint draws the same mesh")


## **An eye inside a body is a real answer, not a failure.** `SpacesimPatches.select` refuses a sphere it
## cannot see round, so the selection is empty — and an empty *mesh* is an error from the rendering server
## (`array_len == 0`, logged every frame it is asked). The body has to draw nothing instead, and it has to
## stop asking: a body whose answer is "nothing" must not re-walk every frame.
func _test_the_eye_inside_a_body(h, scene: SpacesimSystemScene, camera: Camera3D, pixel: float) -> void:
	var earth := scene.body_by_id("planet:earth")
	if earth == null:
		return
	var saved := camera.global_position
	# Half a radius below the surface, which is inside by any measure.
	camera.global_position = earth.node.global_position + Vector3.UP * (earth.radius * 0.5)
	scene.update_lod(camera)
	scene.await_patch_builds()
	# **The mesh that is already there stays.** An empty selection is an error to hand to
	# `add_surface_from_arrays` — the rendering server logs `array_len == 0` every frame it is asked — and
	# clearing the mesh instead would take the ground out of the frame, which is what swings the exposure.
	# A stale equator is worth more than no ground at all.
	h.check(earth.patch_chunks.is_empty(), "the walk has no answer for a sphere it cannot see round")
	h.check(earth.mesh.mesh is ArrayMesh, "so the last mesh stands rather than being thrown away")
	# **And it stops asking.** The walk gate says nothing has moved, so a body whose answer is "nothing"
	# does not re-walk — and re-request — on every frame.
	var chunks_before := earth.patch_chunks.size()
	scene.update_lod(camera)
	scene.await_patch_builds()
	h.check(earth.patch_chunks.size() == chunks_before, "and it does not ask again while nothing has moved")
	# Back outside: the surface returns, which is what makes the clear above a state rather than a loss.
	camera.global_position = earth.node.global_position + Vector3.UP * (earth.radius * 1.05)
	scene.update_lod(camera)
	scene.await_patch_builds()
	h.check(earth.mesh.mesh is ArrayMesh and earth.patch_triangles > 0,
		"and stepping outside brings the surface back (%d triangles)" % earth.patch_triangles)
	camera.global_position = saved


## Triangles in the mesh the body is drawn with. Kept for the report, not for the law.
static func _triangles_under_eye(body: SpacesimSceneBody, to_eye: Vector3) -> int:
	var arrays: Array = (body.mesh.mesh as ArrayMesh).surface_get_arrays(0)
	# **Non-indexed**: every triangle carries its own three vertices, so the soup is read three at a time
	# and there is no index array to walk.
	var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	# **The vertices are metres from the node's own origin**, not points on a unit sphere, so a direction is measured
	# from the body's centre — which means adding the origin back before normalising. See `SpacesimPatches.rebase`.
	var origin := body.mesh.position
	var count := 0
	for i in range(0, points.size() - 2, 3):
		var centre := (
			(points[i] + points[i + 1] + points[i + 2]) / 3.0 + origin
		).normalized()
		if centre.dot(to_eye) > 0.95:
			count += 1
	return count
