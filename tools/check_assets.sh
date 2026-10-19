#!/usr/bin/env bash
# Checks that the committed Godot atlas assets still equal what the original game yields (design step S2).
#
#   1. node tools/extract_assets.mjs --check --compare-fg4
#        godot/assets/atlas/*.webp, atlas_manifest.json and atlas_layout.json must be byte-identical to a
#        fresh extraction from webview-fg4/tests/fixtures/original.html, and each of the 14 data URIs must
#        occur exactly once, byte for byte, in the shipped fg.4 index.html. Writes nothing.
#   2. node --test tools/test_extract_assets.mjs
#        the tests of the extraction tool itself (geometry against the game's own function, failure modes).
#   3. every atlas .webp has its committed Godot import file (godot/assets/atlas/<name>.webp.import).
#        The import settings themselves are checked by godot/tests/test_atlas_assets.gd.
#
# Usage: tools/check_assets.sh [--no-tool-tests]
#   --no-tool-tests   skip step 2 (about 9 s)
# tools/run_godot_tests.sh runs this script first; SWARM_SKIP_ASSET_CHECK=1 there skips it.
# Needs Node 22 or newer (standard library only, no npm packages). Exit code 0 only if everything passes.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ATLAS_DIR="$REPO_ROOT/godot/assets/atlas"

log() { printf '[assets] %s\n' "$*"; }
die() { printf '[assets] ERROR: %s\n' "$*" >&2; exit 1; }

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

command -v node >/dev/null 2>&1 || die "node not found (Node 22 or newer is required for tools/extract_assets.mjs)"
node_major="$(node -p 'process.versions.node.split(".")[0]')"
((node_major >= 22)) || die "Node 22 or newer is required (found $(node --version))"

log "1/3 extract_assets.mjs --check --compare-fg4"
check_rc=0
node "$SCRIPT_DIR/extract_assets.mjs" --check --compare-fg4 >"${TMPDIR:-/tmp}/check_assets.$$.log" 2>&1 || check_rc=$?
if ((check_rc != 0)); then
  sed 's/^/    /' "${TMPDIR:-/tmp}/check_assets.$$.log" >&2
  rm -f "${TMPDIR:-/tmp}/check_assets.$$.log"
  die "the committed atlas assets differ from the original game (exit code $check_rc). Re-run: node tools/extract_assets.mjs"
fi
grep -E '^(check OK|compare-fg4 OK)' "${TMPDIR:-/tmp}/check_assets.$$.log" | sed 's/^/    /'
rm -f "${TMPDIR:-/tmp}/check_assets.$$.log"

if ((RUN_TOOL_TESTS)); then
  log "2/3 node --test tools/test_extract_assets.mjs"
  tests_rc=0
  tests_out="$(node --test "$SCRIPT_DIR/test_extract_assets.mjs" 2>&1)" || tests_rc=$?
  if ((tests_rc != 0)); then
    printf '%s\n' "$tests_out" | sed 's/^/    /' >&2
    die "tests of tools/extract_assets.mjs failed (exit code $tests_rc)"
  fi
  printf '%s\n' "$tests_out" | grep -E '^# (tests|pass|fail)' | paste -sd' ' - | sed 's/^/    /'
else
  log "2/3 skipped (--no-tool-tests)"
fi

log "3/3 import files"
missing=0
count=0
for webp in "$ATLAS_DIR"/*.webp; do
  count=$((count + 1))
  if [[ ! -f "$webp.import" ]]; then
    printf '    missing: %s\n' "${webp#"$REPO_ROOT"/}.import" >&2
    missing=$((missing + 1))
  fi
done
((count > 0)) || die "no .webp files in $ATLAS_DIR"
((missing == 0)) || die "$missing atlas image(s) have no .import file: run tools/run_godot_tests.sh (it imports the project), set the pixel-art import parameters (see godot/tests/test_atlas_assets.gd) and keep the .import files"
printf '    %d .webp files, each with a .import file\n' "$count"
log "PASS"
