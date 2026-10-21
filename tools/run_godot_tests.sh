#!/usr/bin/env bash
# Runs the headless GDScript tests of the Godot project (design section 9.1):
#   godot --headless --path godot -s res://tests/run_tests.gd
# Exit code 0 only if the runner reports RESULT: PASS, Godot exits with 0 and the output
# contains no engine/script errors. The project is imported first on every run (incremental: only
# new or changed assets are re-imported, about 7 s), so tests never see stale or missing imports.
#
# Before Godot starts, tools/check_assets.sh verifies that the committed atlas assets (godot/assets/atlas)
# still equal a fresh extraction from the original game and that the extraction tool's own tests pass
# (Node 22). A drifted asset therefore fails this script, not only the test it affects. In the same way
# tools/check_generated.sh verifies that the committed definition tables (godot/sim/defs) and golden test vectors
# (godot/tests/golden) still equal a fresh generation from the original game.
#
# Usage: tools/run_godot_tests.sh [test-file-name-filter]
# Environment:
#   SWARM_SKIP_ASSET_CHECK=1         skip tools/check_assets.sh (for a machine without Node)
#   SWARM_SKIP_GENERATED_CHECK=1     skip tools/check_generated.sh (for a machine without Node)
#   SWARM_SKIP_IMPORT=1              skip the import (only for a quick re-run when no asset changed)
#   SWARM_IMPORT_TIMEOUT=<seconds>   limit for the import (default 600)
#   SWARM_TEST_TIMEOUT=<seconds>     limit for the test run (default 600; the run takes about 2.5 minutes since step S5 replays every reference trace twice)
#   SWARM_ALLOW_ENGINE_ERRORS=1      report "ERROR:" lines as a warning instead of a failure
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PROJECT_DIR="$REPO_ROOT/godot"

log() { printf '[tests] %s\n' "$*"; }
die() { printf '[tests] ERROR: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  -h | --help)
    awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac
TEST_FILTER="${1:-}"

# shellcheck source=lib/toolchain.sh
source "$SCRIPT_DIR/lib/toolchain.sh" || exit 1
[[ -f "$PROJECT_DIR/project.godot" ]] || die "missing $PROJECT_DIR/project.godot"

# Output that is not a test problem: Godot reports leaked objects while shutting down.
SHUTDOWN_NOISE='resources? still in use at exit|ObjectDB instances leaked|RIDs? of type .* leaked'

# run_godot <timeout-seconds> <log-file> <echo 0|1> <godot args...>
# (swarm_godot, exported by toolchain.sh, keeps HOME, TMPDIR and user:// inside the cache dir.)
# Output is saved to the log file (and shown live when echo is 1). Returns Godot's exit code
# (124 on timeout).
run_godot() {
  local seconds=$1 log_file=$2 echo_output=$3 rc
  shift 3
  set +e
  if ((echo_output)); then
    timeout --kill-after=15 "$seconds" bash -c 'swarm_godot "$@"' swarm_godot "$@" 2>&1 | tee "$log_file"
    rc=${PIPESTATUS[0]}
  else
    timeout --kill-after=15 "$seconds" bash -c 'swarm_godot "$@"' swarm_godot "$@" >"$log_file" 2>&1
    rc=$?
  fi
  set -e
  return "$rc"
}

# engine_errors <log-file>: prints engine/script error lines, minus shutdown noise.
engine_errors() {
  sed 's/\x1b\[[0-9;]*m//g' "$1" | grep -E '^(SCRIPT ERROR|ERROR|USER ERROR|Parse Error)' | grep -Ev "$SHUTDOWN_NOISE" || true
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# 0. The committed assets must equal what the original game yields (Node only, no Godot).
if [[ "${SWARM_SKIP_ASSET_CHECK:-0}" == "1" ]]; then
  log "skipping the asset check (SWARM_SKIP_ASSET_CHECK=1)"
else
  log "checking the atlas assets against the original game ..."
  "$SCRIPT_DIR/check_assets.sh" || die "tools/check_assets.sh failed (the atlas assets drifted from the original game)"
fi

# 0b. The committed definition tables and golden vectors must equal what the original game yields (Node only).
if [[ "${SWARM_SKIP_GENERATED_CHECK:-0}" == "1" ]]; then
  log "skipping the generated-data check (SWARM_SKIP_GENERATED_CHECK=1)"
else
  log "checking the generated definition tables and golden vectors against the original game ..."
  "$SCRIPT_DIR/check_generated.sh" || die "tools/check_generated.sh failed (generated data drifted from the original game)"
fi

# 1. Import the project (creates godot/.godot, which is gitignored). Godot only redoes what changed,
# so new assets and class_name scripts are picked up and edited assets are not read from stale data.
if [[ "${SWARM_SKIP_IMPORT:-0}" == "1" ]]; then
  log "skipping the import (SWARM_SKIP_IMPORT=1)"
else
  log "importing project (headless, incremental) ..."
  import_rc=0
  run_godot "${SWARM_IMPORT_TIMEOUT:-600}" "$WORK_DIR/import.log" 0 --headless --path "$PROJECT_DIR" --import || import_rc=$?
  if ((import_rc != 0)); then
    sed 's/\x1b\[[0-9;]*m//g; s/^/    /' "$WORK_DIR/import.log" >&2
    if ((import_rc == 124 || import_rc == 137)); then die "Godot import timed out (raise SWARM_IMPORT_TIMEOUT)"; fi
    die "Godot import failed (exit code $import_rc)"
  fi
fi

# 2. Run the test runner. Output is shown as it is produced and also kept for the error scan.
log "running tests with $(swarm_godot --version 2>/dev/null | head -n 1 || echo 'Godot')"
TEST_LOG="$WORK_DIR/tests.log"
runner_args=(--headless --path "$PROJECT_DIR" -s res://tests/run_tests.gd)
[[ -z "$TEST_FILTER" ]] || runner_args+=(-- "$TEST_FILTER")
godot_rc=0
run_godot "${SWARM_TEST_TIMEOUT:-600}" "$TEST_LOG" 1 "${runner_args[@]}" || godot_rc=$?

# 3. Judge the run.
status=0
if ((godot_rc == 124 || godot_rc == 137)); then
  log "FAIL: test run timed out"
  status=1
elif ((godot_rc != 0)); then
  log "FAIL: Godot exited with code $godot_rc"
  status=1
fi
if ! grep -q '^RESULT: PASS$' "$TEST_LOG"; then
  log "FAIL: runner did not report RESULT: PASS (script failed to start, or tests failed)"
  status=1
fi
errors="$(engine_errors "$TEST_LOG")"
if [[ -n "$errors" ]]; then
  if [[ "${SWARM_ALLOW_ENGINE_ERRORS:-0}" == "1" ]]; then
    log "WARNING: engine/script errors in the output (allowed by SWARM_ALLOW_ENGINE_ERRORS=1):"
  else
    log "FAIL: engine/script errors in the output:"
    status=1
  fi
  sed 's/^/    /' <<<"$errors" >&2
fi

if ((status == 0)); then
  log "PASS"
else
  log "FAIL (see output above)"
fi
exit "$status"
