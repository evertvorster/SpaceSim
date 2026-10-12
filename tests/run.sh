#!/usr/bin/env bash
# Run the SpaceSim test suite, and smoke-load the demo scene.
#
# Two holes this closes that a plain `godot ... res://tests/run_tests.tscn` does not:
#
#  1. A GDScript error aborts the function it happens in without failing the run, so a broken
#     check can silently skip while the suite still reports success.
#  2. The test scene never loads the game scene, so a parse error in a game/ script would go
#     unnoticed until somebody launched the game.
#
#   tests/run.sh
#
# GODOT, TEST_TIMEOUT and SMOKE_TIMEOUT override the engine binary and the deadlines.
set -uo pipefail

GODOT="${GODOT:-godot-double-mono}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

check() {
	local label="$1" log="$2" status="$3"
	if [ "$status" -ne 0 ]; then
		echo "FAILED: $label exited $status"
		FAILED=1
	elif grep -qE "SCRIPT ERROR|^ERROR:" "$log"; then
		echo "FAILED: $label reported errors (an error can abort checks without failing the run)"
		FAILED=1
	fi
}

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path "$REPO_ROOT" \
	res://tests/run_tests.tscn >"$LOG" 2>&1
status=$?
cat "$LOG"
check "the test suite" "$LOG" "$status"

timeout "${SMOKE_TIMEOUT:-60}" "$GODOT" --headless --path "$REPO_ROOT" --quit-after 120 \
	>"$LOG" 2>&1
status=$?
cat "$LOG"
check "the demo scene" "$LOG" "$status"

exit "$FAILED"
