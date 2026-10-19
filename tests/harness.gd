extends RefCounted
## Minimal assertion helper for the headless test runner. No test framework dependency.
##
## Tolerances are explicit per check rather than relative: the coordinate tests work with
## positions around 1e9 m, where Godot's built-in `is_equal_approx` (relative, ~1e-5) would accept
## errors of kilometres.

var checks: int = 0
var failures: int = 0


func check(condition: bool, what: String) -> void:
	checks += 1
	if condition:
		print("    ok    ", what)
	else:
		failures += 1
		print("    FAIL  ", what)


func check_near(actual: float, expected: float, what: String, epsilon: float) -> void:
	checks += 1
	if absf(actual - expected) <= epsilon:
		print("    ok    ", what)
	else:
		failures += 1
		print("    FAIL  %s (expected %.9f, got %.9f)" % [what, expected, actual])


func check_vector_near(actual: Vector3, expected: Vector3, what: String, epsilon: float) -> void:
	checks += 1
	var error := actual.distance_to(expected)
	if error <= epsilon:
		print("    ok    ", what)
	else:
		failures += 1
		print("    FAIL  %s (off by %.9f m)" % [what, error])


func check_vector2_near(actual: Vector2, expected: Vector2, what: String, epsilon: float) -> void:
	checks += 1
	var error := actual.distance_to(expected)
	if error <= epsilon:
		print("    ok    ", what)
	else:
		failures += 1
		print("    FAIL  %s (off by %.6f)" % [what, error])
