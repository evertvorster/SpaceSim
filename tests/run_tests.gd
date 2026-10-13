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

## Every suite, in the order they run. The playground flight test drives ~120000 steps, so the whole
## run takes minutes — `SPACESIM_TESTS=save,session tests/run.sh` runs only the suites whose path
## contains one of those words, which is what makes iterating on one module quick.
var suites: Array = [
	preload("res://tests/test_frame_transition.gd"),
	preload("res://tests/test_solar_system.gd"),
	preload("res://tests/test_sol.gd"),
	preload("res://tests/test_travel_scale.gd"),
	preload("res://tests/test_markers.gd"),
	preload("res://tests/test_settings.gd"),
	preload("res://tests/test_settings_ui.gd"),
	preload("res://tests/test_player.gd"),
	preload("res://tests/test_save.gd"),
	preload("res://tests/test_session.gd"),
	preload("res://tests/test_space_to_surface.gd"),
]


func _ready() -> void:
	print("SpaceSim tests  (", Engine.get_version_info()["string"], ")")
	var harness := Harness.new()
	var wanted := _wanted_suites()
	for suite in suites:
		var path: String = suite.resource_path if suite is Resource else ""
		if not wanted.is_empty() and not _matches(path, wanted):
			continue
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


## The suites asked for on the command line, or nothing for all of them.
func _wanted_suites() -> Array:
	var asked := OS.get_environment("SPACESIM_TESTS")
	if asked.strip_edges().is_empty():
		return []
	return Array(asked.split(",", false))


func _matches(path: String, wanted: Array) -> bool:
	for word in wanted:
		if path.contains(String(word).strip_edges()):
			return true
	return false
