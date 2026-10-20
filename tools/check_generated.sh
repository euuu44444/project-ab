#!/usr/bin/env bash
# Checks that the committed generated data still equals what the original game yields (design step S3).
#
#   1. node tools/extract_defs.mjs --check
#        godot/sim/defs/*.json (the definition tables: CHARACTERS, WEAPONS, ENEMY_ARCHETYPES, ...) must be byte-identical to
#        a fresh extraction from webview-fg4/tests/fixtures/original.html. Writes nothing.
#   2. node tools/gen_golden.mjs --check
#        godot/tests/golden/*.json (the golden test vectors: numerics, random numbers, formulas ...) must be byte-identical
#        to a fresh generation from the original game, and no stray .json may be there. Writes nothing.
#   3. node tools/check_js_compat_consts.mjs
#        the constants and tables of godot/sim/js_compat.gd (JsMath) must equal the upstream literals of glibc and V8 that they
#        were transcribed from (the expression, the CONST_BITS entry and the literal agree bit for bit). Writes nothing.
#   4. node --test tools/test_gen_golden.mjs
#        the tests of the golden generator itself.
#   5. node --test tools/test_extract_defs.mjs
#        the tests of extract_defs.mjs and of the S3 golden modules (defs_*.mjs), including values measured in Chromium.
#
# After a deliberate change of a generator, run it without --check (node tools/extract_defs.mjs, node tools/gen_golden.mjs)
# and commit the result. tools/verify_golden_chromium.mjs (needs Playwright, not run here) compares the math vectors with a
# real Chromium.
#
# Usage: tools/check_generated.sh [--no-tool-tests]
#   --no-tool-tests   skip steps 4 and 5 (about 25 s)
# tools/run_godot_tests.sh runs this script after check_assets.sh; SWARM_SKIP_GENERATED_CHECK=1 there skips it.
# Needs Node 22 or newer (standard library only, no npm packages). Exit code 0 only if everything passes. All checks are
# run even if one fails, so that one run reports every drifted file.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

log() { printf '[generated] %s\n' "$*"; }
die() { printf '[generated] ERROR: %s\n' "$*" >&2; exit 1; }

RUN_TOOL_TESTS=1
for arg in "$@"; do
  case "$arg" in
    --no-tool-tests) RUN_TOOL_TESTS=0 ;;
    -h | --help)
      awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) die "unknown option: $arg (see --help)" ;;
  esac
done

command -v node >/dev/null 2>&1 || die "node not found (Node 22 or newer is required)"
node_major="$(node -p 'process.versions.node.split(".")[0]')"
((node_major >= 22)) || die "Node 22 or newer is required (found $(node --version))"

LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/check_generated.XXXXXX")"
trap 'rm -f "$LOG_FILE"' EXIT
failures=0

# run_check <label> <command...>: runs the command, shows the last lines of its output (all of it on failure).
run_check() {
  local label=$1 rc=0
  shift
  "$@" >"$LOG_FILE" 2>&1 || rc=$?
  if ((rc == 0)); then
    grep -E '^(check OK|# (tests|pass|fail))' "$LOG_FILE" | paste -sd' ' - | sed 's/^/    /'
  else
    sed 's/^/    /' "$LOG_FILE" >&2
    log "FAILED: $label (exit code $rc)"
    failures=$((failures + 1))
  fi
}

log "1/5 extract_defs.mjs --check"
run_check "tools/extract_defs.mjs --check (re-run: node tools/extract_defs.mjs)" node "$SCRIPT_DIR/extract_defs.mjs" --check

log "2/5 gen_golden.mjs --check"
run_check "tools/gen_golden.mjs --check (re-run: node tools/gen_golden.mjs)" node "$SCRIPT_DIR/gen_golden.mjs" --check

log "3/5 check_js_compat_consts.mjs"
run_check "tools/check_js_compat_consts.mjs (a constant of godot/sim/js_compat.gd differs from its upstream literal)" node "$SCRIPT_DIR/check_js_compat_consts.mjs"

if ((RUN_TOOL_TESTS)); then
  log "4/5 node --test tools/test_gen_golden.mjs"
  run_check "tools/test_gen_golden.mjs" node --test "$SCRIPT_DIR/test_gen_golden.mjs"
  log "5/5 node --test tools/test_extract_defs.mjs"
  run_check "tools/test_extract_defs.mjs" node --test "$SCRIPT_DIR/test_extract_defs.mjs"
else
  log "4/5 and 5/5 skipped (--no-tool-tests)"
fi

if ((failures > 0)); then
  die "$failures check(s) failed: the committed generated data differs from the original game, or a generator is broken"
fi
log "PASS"
