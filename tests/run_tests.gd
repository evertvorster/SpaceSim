extends Node
## Headless test runner.
##
##     timeout 300 godot-double-mono --headless --path . res://tests/run_tests.tscn
##
## The playground flight test drives ~120,000 steps, so the whole run takes minutes — that is what
## `run.sh` uses a 300 s deadline for, and why a 60 s example here would kill the run midway.
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
## **The suite paths, and deliberately not `preload`ed.** `preload` is resolved when *this* file is
## parsed, so a suite containing a syntax error took the runner down with it: the scene would not
## load, `_ready` never ran, `quit()` was never reached, and `run.sh` sat there until its timeout —
## which reads as the suite being slow, and is not. `--check-only` on the suite by hand was the only
## way to see the error, and the guard below — whose whole purpose is to survive this — could never
## fire. Loaded at run time, a broken suite comes back null and is reported by name.
##
## A path here is also checked: a missing file is the same failure and deserves the same report.
var suite_paths: Array = [
	"res://tests/test_frame_transition.gd",
	"res://tests/test_solar_system.gd",
	"res://tests/test_sol.gd",
	"res://tests/test_surface.gd",
	"res://tests/test_render.gd",
	"res://tests/test_lighting.gd",
	"res://tests/test_travel_scale.gd",
	"res://tests/test_markers.gd",
	"res://tests/test_settings.gd",
	"res://tests/test_settings_ui.gd",
	"res://tests/test_display.gd",
	"res://tests/test_player.gd",
	"res://tests/test_save.gd",
	"res://tests/test_session.gd",
	"res://tests/test_space_to_surface.gd",
	"res://tests/test_lod.gd",
	"res://tests/test_icosphere.gd",
	"res://tests/test_meter.gd",
	"res://tests/test_clouds.gd",
	"res://tests/test_cloud_field.gd",
	"res://tests/test_cloud_maps.gd",
]


func _ready() -> void:
	print("SpaceSim tests  (", Engine.get_version_info()["string"], ")")
	var harness := Harness.new()
	var wanted := _wanted_suites()
	for path in suite_paths:
		if not wanted.is_empty() and not _matches(String(path), wanted):
			continue
		# A suite that failed to compile must not take the run down with it: report and carry on,
		# so the runner always reaches quit() instead of hanging. This is the guard that could not
		# fire while the list was `preload`ed — see the comment on `suite_paths`.
		var suite: Variant = load(String(path))
		if not (suite is GDScript) or not suite.can_instantiate():
			print("  FAIL  suite did not compile: ", path)
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
