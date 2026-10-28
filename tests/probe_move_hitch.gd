extends Node
## **What a frame costs on the main thread while the eye moves** — the one measurement that explains a hitch felt only
## while flying, and the one a headless suite cannot make: `update_lod`'s expensive half is a `RenderingServer` call,
## and headless there is no rendering device.
##
## Run it as a scene (not `--script`, which loads no autoloads), with a real device:
##
##   xvfb-run -a godot-double-mono --path . --quit-after 900 res://tests/probe_move_hitch.tscn
##
## Prints the per-frame breakdown once every `REPORT_EVERY` frames: how much of the frame `update_lod` took, how many
## builds landed, and the worst frame. A hitch is a frame whose `update_lod` time dwarfs the rest.

const SOL_PATH := "res://systems/sol.tres"
const ALTITUDE := 10.0   ## metres above the ground, where the selections are biggest
const FRAMES := 700
const REPORT_EVERY := 100


func _ready() -> void:
	var sol: SpacesimSolarSystem = load(SOL_PATH)
	var scene := SpacesimSystemScene.from_content(sol)
	scene.build(self)
	var earth := scene.body_by_id("planet:earth")

	# **The camera IS the observer** — there is no ship hull any more, and the camera flies. But a frame has to be
	# active before any rule fires: `evaluate()` returns while `active_frame` is null, so an observer with no entered
	# frame walks nothing and the ground never becomes geometry (the first two runs of this instrument measured a
	# 0.4 ms frame with 0 chunks in it, which is what that looks like).
	var camera := Camera3D.new()
	camera.fov = 70.0
	add_child(camera)
	scene.frame_tree.observer = camera
	scene.frame_tree.enter_frame(scene.system_frame)
	var to_eye := Vector3.UP
	var eye := to_eye * (earth.radius + ALTITUDE)
	camera.global_position = eye
	camera.basis = Basis.looking_at(-to_eye, Vector3.RIGHT)

	print("PROBE: %.0f m above Earth, %d frames, reporting every %d" % [
		ALTITUDE, FRAMES, REPORT_EVERY
	])
	var worst := 0.0
	var worst_frame := 0
	var total := 0.0
	for frame in FRAMES:
		# **Move the eye every frame**, which is what makes a walk due and a rebuild land — the state the hitch is
		# reported in. A metre a frame at 60 Hz is a slow flight, well inside the walk gate's sensitivity.
		eye += Vector3.RIGHT * 1.0
		camera.global_position = eye
		# **Step the frame tree**, or the observer stays in deep space: `air_top` is zero there, so the surface never
		# becomes geometry and the probe measures a frame with no ground in it. This is the call `main.gd` makes after
		# the ship steps.
		scene.frame_tree.evaluate()
		var started := Time.get_ticks_usec()
		scene.update_lod(camera, eye)
		var update_us := Time.get_ticks_usec() - started
		total += update_us
		if update_us > worst:
			worst = update_us
			worst_frame = frame
		if frame % REPORT_EVERY == 0 and frame > 0:
			print("PROBE: frame %4d  %-22s mean update_lod %6.2f ms  worst %6.2f ms (frame %d)  %d chunks  %d tri" % [
				frame, scene.frame_tree.active_frame.frame_id, total / REPORT_EVERY / 1000.0,
				worst / 1000.0, worst_frame, scene.chunks(), scene.triangles()
			])
			worst = 0.0
			worst_frame = 0
			total = 0.0
		await get_tree().process_frame
	print("PROBE: done")
	get_tree().quit(0)
