extends Node
## Headless test runner.
##
##     timeout 60 godot-double-mono --headless --path . res://tests/run_tests.tscn
##
## Exits 0 when every check passes, 1 otherwise. Tests are synchronous: they build a scene tree,
## drive the code under test directly, and assert. Nothing waits on frames.
##
## Run it under `timeout`: a suite that fails to compile stops the run before it can quit, and a
## hung test process is worse than a failed one.

const Harness := preload("res://tests/harness.gd")

var suites: Array = [
	preload("res://tests/test_frame_transition.gd"),
	preload("res://tests/test_world.gd"),
	preload("res://tests/test_travel_scale.gd"),
	preload("res://tests/test_markers.gd"),
	preload("res://tests/test_settings.gd"),
	preload("res://tests/test_settings_ui.gd"),
	preload("res://tests/test_player.gd"),
	preload("res://tests/test_save.gd"),
	preload("res://tests/test_space_to_surface.gd"),
]


func _ready() -> void:
	print("SpaceSim tests  (", Engine.get_version_info()["string"], ")")
	var harness := Harness.new()
	for suite in suites:
		# A suite that failed to compile must not take the run down with it: report and carry on,
		# so the runner always reaches quit() instead of hanging.
		if not (suite is GDScript) or not suite.can_instantiate():
			print("  FAIL  suite did not compile: ", suite.resource_path if suite is Resource else suite)
			harness.failures += 1
			continue
		suite.new().run(harness, self)
	print("")
	print("%d checks, %d failed" % [harness.checks, harness.failures])
	get_tree().quit(1 if harness.failures > 0 else 0)
