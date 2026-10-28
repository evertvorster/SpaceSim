extends Node
## **What a frame costs on the main thread while the eye moves** — the measurement for a hitch felt only while flying.
##
## The camera is placed relative to EARTH's node, not the world origin: the first version of this probe aimed at
## `direction * (radius + altitude)`, which is a point in world space far from the body, so the walk answered empty and
## the probe reported 0.4 ms frames with no ground in them.
##
##   xvfb-run -a godot-double-mono --path . --quit-after 900 res://tests/probe_move_hitch.tscn

const SOL_PATH := "res://systems/sol.tres"
const ALTITUDE := 10.0
const FRAMES := 600
const REPORT_EVERY := 100
const STEP := 1.0   ## metres of ground a frame


func _ready() -> void:
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	var scene := SpacesimSystemScene.from_content(sol)
	scene.build(self)
	var earth := scene.body_by_id("planet:earth")

	var camera := Camera3D.new()
	camera.fov = 70.0
	add_child(camera)
	var up := Vector3.UP
	camera.basis = Basis.looking_at(-up, Vector3.RIGHT)

	print("PROBE: %.0f m above Earth, %d frames" % [ALTITUDE, FRAMES])
	var total := 0.0
	var worst := 0.0
	var worst_frame := 0
	# **How often a mesh actually lands**, counted by the object changing — the upload is the expensive main-thread
	# step, so the count is the thing a publish policy moves.
	var publishes := 0
	var last_mesh: Object = null
	for frame in FRAMES:
		# **Along the ground**, which is the case that drops: patches cross the apparent-size threshold continuously.
		var ground := earth.node.global_position + up * earth.radius
		var along := ground + Vector3.RIGHT * STEP * frame
		camera.global_position = along.normalized() * 0.0 + earth.node.global_position \
			+ (along - earth.node.global_position).normalized() * (earth.radius + ALTITUDE)
		var started := Time.get_ticks_usec()
		scene.update_lod(camera)
		var update_us := Time.get_ticks_usec() - started
		if earth.mesh.mesh != last_mesh:
			publishes += 1
			last_mesh = earth.mesh.mesh
		total += update_us
		if update_us > worst:
			worst = update_us
			worst_frame = frame
		if frame % REPORT_EVERY == 0 and frame > 0:
			print("PROBE: frame %4d  mean update_lod %6.2f ms  worst %6.2f ms (frame %d)  %d publishes  %d tri" % [
				frame, total / REPORT_EVERY / 1000.0, worst / 1000.0, worst_frame,
				publishes, scene.triangles()
			])
			total = 0.0
			worst = 0.0
			worst_frame = 0
		await get_tree().process_frame
	print("PROBE: done")
	get_tree().quit(0)
