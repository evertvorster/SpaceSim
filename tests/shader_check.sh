#!/usr/bin/env bash
# Compile the project's shaders for real, and fail if one does not.
#
#   tests/shader_check.sh
#
# **Headless Godot does not compile shaders.** `load()` returns a valid Shader with a syntax error
# sitting inside it, and `--import` reports nothing — verified 2026-10-13 by deliberately breaking a
# shader and watching both say it was fine. The shader compiler needs a real (or software) GPU, so
# this wraps the run in `xvfb-run` rather than being part of run.sh, which is headless and fast.
#
# GODOT, SHADER_TIMEOUT and QUIT_AFTER override the engine, the deadline and the frame count.
set -uo pipefail

GODOT="${GODOT:-godot-double-mono}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

timeout "${SHADER_TIMEOUT:-240}" xvfb-run -a "$GODOT" --path "$REPO_ROOT" \
	--quit-after "${QUIT_AFTER:-90}" >"$LOG" 2>&1
status=$?

if [ "$status" -ne 0 ]; then
	echo "FAILED: the run exited $status; the log is below"
	cat "$LOG"
	exit 1
fi

if grep -qiE "SHADER ERROR|Shader compilation failed" "$LOG"; then
	echo "FAILED: a shader did not compile"
	grep -iE -A2 "SHADER ERROR|Shader compilation failed" "$LOG" | head -30
	exit 1
fi

if grep -qE "^ERROR:" "$LOG"; then
	echo "FAILED: the run reported errors (which may hide a shader failure)"
	grep -E "^ERROR:" "$LOG" | head -10
	exit 1
fi

echo "every shader compiled"
