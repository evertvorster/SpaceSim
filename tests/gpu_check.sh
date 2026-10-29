#!/usr/bin/env bash
# Run the GPU bake comparison for real, which needs a rendering device.
#
#   tests/gpu_check.sh
#
# **Headless Godot neither compiles shaders nor draws**, and `RenderingServer.create_local_rendering_device()`
# returns null under `--headless` — so `tests/run.sh` cannot run this comparison, and a suite that silently
# skipped would be a suite nobody notices is not running. This wraps the project's own runner in
# `xvfb-run` with only the GPU suite selected, so the assertion is the same assertion and the report is the
# same report.
#
# GODOT, GPU_TIMEOUT and SPACESIM_TESTS override the engine, the deadline and the suite filter.
set -uo pipefail

GODOT="${GODOT:-godot-double-mono}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# **The GPU suite only, by default.** This script exists to exercise the path that needs a rendering
# device; the rest of the suite asserts a worker-pool handoff that a GPU present makes synchronous, and
# belongs in the headless run where it is true. `SPACESIM_TESTS=` (empty) runs everything.
export SPACESIM_TESTS="${SPACESIM_TESTS-cloud_gpu,surface_gpu}"

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

# No `xvfb-run -a` deadline games: a shader compile failure reports itself, and a hung run is caught.
timeout "${GPU_TIMEOUT:-240}" xvfb-run -a "$GODOT" --path "$REPO_ROOT" \
	res://tests/run_tests.tscn 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}

if [ "$status" -ne 0 ]; then
	echo "FAILED: the renderer run exited $status"
	exit 1
fi

if grep -qiE "SHADER ERROR|Shader compilation failed|SCRIPT ERROR" "$LOG"; then
	echo "FAILED: the run reported an error"
	grep -iE -A2 "SHADER ERROR|Shader compilation failed|SCRIPT ERROR" "$LOG" | head -30
	exit 1
fi

if grep -qE "^ERROR:" "$LOG"; then
	echo "FAILED: the run reported errors (which may hide a shader failure)"
	grep -E "^ERROR:" "$LOG" | head -10
	exit 1
fi

# **A skipped comparison is a failed check here.** The whole reason this script exists is the run where a
# rendering device is available; if the suite reported the device missing, the wrapper has been fooled.
if grep -q "skipped the comparison" "$LOG"; then
	echo "FAILED: the GPU suite did not get a rendering device, so nothing was compared"
	exit 1
fi

# And the suite must actually have run: a filter that matches nothing reports `0 checks, 0 failed`, which
# is the success message of a run that tested nothing at all.
if ! grep -q "texels differ" "$LOG"; then
	echo "FAILED: the comparison did not run (was the suite selected? SPACESIM_TESTS=\"$SPACESIM_TESTS\") — the log is below"
	cat "$LOG"
	exit 1
fi

if grep -qE "  FAIL  " "$LOG"; then
	echo "FAILED: a check failed"
	grep -E "  FAIL  " "$LOG"
	exit 1
fi

echo "gpu bake: ok"
