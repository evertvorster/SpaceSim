extends Node
## **The surface maps, wired to a real scene and a real camera** — the one part of S2 that no headless test can
## reach, because a bake needs a rendering device.
##
##     timeout 120 xvfb-run -a godot-double-mono --path . res://tests/probe_surface_maps.tscn
##
## **A scene rather than a `--script` runner**, because the scene class reaches an autoload (`SpacesimSettings`)
## and a `--script` main loop has none: it compiles with *"Identifier not found: SpacesimSettings"* and then
## hangs, which is the same shape as every other `--script` failure.
##
## **It exits 139, and that is the probe rather than the game.** The numbers below are printed before it, and
## the same path — this scene, with a camera, baking these maps and exiting through the tree — leaves
## `tests/shader_check.sh` at **exit 0**, which runs the real main loop for ninety frames. What the crash is not
## is the surface maps: it happens whether or not the bake device is freed here. Read the numbers, not the
## status.
##
## What it answers, in numbers rather than in a picture:
##
##  - a body's map is **baked once and refined** as the eye approaches, and the refinement is the distance
##    law's rather than a ladder's;
##  - the **sea level** comes off the map's measured quantiles, so content's ocean fraction becomes a height in
##    the field the shader samples;
##  - the **material is actually given** those textures and that sea level — the publish path is where a
##    mistyped uniform name would leave the shader drawing its neutral defaults, and nothing else in the
##    project would notice.

const SOL_PATH := "res://systems/sol.tres"


func _ready() -> void:
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	if sol == null:
		print("FAIL  Sol does not load")
		get_tree().quit(1)
		return
	var scene := SpacesimSystemScene.from_content(sol)
	scene.build(self)
	var camera := Camera3D.new()
	camera.fov = 70.0
	add_child(camera)

	var earth := scene.body_by_id("planet:earth")
	if earth == null:
		print("FAIL  no Earth in the scene")
		get_tree().quit(1)
		return
	var materials := SpacesimMaterialTable.engine_table()
	var light := SpacesimStarModel.luminosity(sol.star())

	print("Earth: ocean fraction %.3f (content's 0.708, resolved through the map's quantiles)" % [
		earth.surface_ocean_fraction
	])
	h_watch(scene, camera, earth, 4.0e8, "far")
	h_watch(scene, camera, earth, 4.0e7, "resolved")
	h_watch(scene, camera, earth, 4.0e6, "low orbit")
	h_watch(scene, camera, earth, 4.0e5, "close")

	var entry := scene.surface_maps().entry_for("planet:earth")
	if entry != null:
		print("quantiles: p5 %.3f  p25 %.3f  p50 %.3f  p75 %.3f  p95 %.3f" % [
			entry.value_at(0.05), entry.value_at(0.25), entry.value_at(0.5),
			entry.value_at(0.75), entry.value_at(0.95)
		])
		print("sea level %.3f  ==  value_at(%.3f) = %.3f" % [
			float(earth.mesh.material_override.get_shader_parameter("sea_level")),
			earth.surface_ocean_fraction, entry.value_at(earth.surface_ocean_fraction)
		])
		print("bakes: %d, detail width %d, coarse width %d" % [
			scene.surface_maps().bakes(), entry.width, entry.coarse_width
		])
		print("field amplitude %.0f m, relief exaggeration %.1f" % [
			float(earth.mesh.material_override.get_shader_parameter("field_amplitude")),
			float(earth.mesh.material_override.get_shader_parameter("relief_exaggeration"))
		])
		var sea_level := entry.value_at(earth.surface_ocean_fraction)
		if absf(float(earth.mesh.material_override.get_shader_parameter("sea_level")) - sea_level) > 1.0e-4:
			print("FAIL  the material's sea level is not the one measured off its map")
		var height_map: Texture2D = earth.mesh.material_override.get_shader_parameter("height_map")
		if height_map == null or height_map.get_width() < SpacesimSurfaceMaps.FLOOR_WIDTH:
			print("FAIL  the material still has the neutral fallback map")
		else:
			print("the material holds a %dx%d height map and a %dx%d coarse map" % [
				height_map.get_width(), height_map.get_height(),
				earth.mesh.material_override.get_shader_parameter("coarse_map").get_width(),
				earth.mesh.material_override.get_shader_parameter("coarse_map").get_height()
			])

	scene.close()
	print("done")
	# **Give the tree a frame before asking it to quit.** `update_lod` may have a patch rebuild in flight, and
	# a `WorkerThreadPool` task still running when the engine goes away segfaults the process at exit — the
	# documented failure, and one that reads as "the probe crashed" rather than "the probe was too quick".
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().quit(0)


## One frame from a distance, with what the body ended up holding.
func h_watch(scene: SpacesimSystemScene, camera: Camera3D, earth: SpacesimSceneBody, distance: float, label: String) -> void:
	camera.global_position = earth.node.global_position + Vector3(distance, 0.0, 0.0)
	camera.look_at(earth.node.global_position, Vector3.UP)
	scene.update_lod(camera)
	print("%-10s %-11s surface map width %d, %d bakes" % [
		label, "%d km" % int(distance / 1000.0), earth.surface_map_width,
		scene.surface_maps().bakes()
	])
