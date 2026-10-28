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
# **The suite owns its settings file.** It used to read the player's, so a value trimmed in flight decided whether a test
# passed — and the smoke load runs the GAME, which writes that file on exit, so a suite run could change the player's own
# config. A platform test sets `render.mode`, which is exactly the kind of value that must not leak either way.
SCRATCH_CONFIG="$(mktemp -d)"
export XDG_CONFIG_HOME="$SCRATCH_CONFIG"
trap 'rm -rf "$SCRATCH_CONFIG"; rm -f "$LOG"' EXIT

# The suite is **streamed as well as logged**: with the output only redirected, a run that stalls looks
# like a frozen terminal for as long as the timeout, which is exactly how a broken suite used to read.
# The runner now reports a suite that will not load instead of stalling on it (`run_tests.gd`), and this
# is the belt to that braces.
#
# Run it under `timeout`, and **never into a `grep`**: a killed run loses whatever is in the pipe, and
# the error is in the part a filter throws away.
timeout "${TEST_TIMEOUT:-300}" "$GODOT" --headless --path "$REPO_ROOT" \
	res://tests/run_tests.tscn 2>&1 | tee "$LOG"
status=$?
check "the test suite" "$LOG" "$status"

timeout "${SMOKE_TIMEOUT:-60}" "$GODOT" --headless --path "$REPO_ROOT" --quit-after 120 \
	2>&1 | tee "$LOG"
status=$?
check "the demo scene" "$LOG" "$status"

exit "$FAILED"
