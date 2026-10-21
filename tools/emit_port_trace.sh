#!/usr/bin/env bash
# Writes the Godot port's trace for the run of a reference trace (design section 9.2): the same seed, character, difficulty, mode and
# view, with the reference's input of every step replayed through the sim. The result is a swarm-trace/1 file that
# tools/compare_trace.mjs can compare with the reference.
#
#   tools/emit_port_trace.sh <reference.jsonl.gz> <out.jsonl[.gz]> [until-step] [--oracle]
#   node tools/compare_trace.mjs <reference.jsonl.gz> <out.jsonl.gz> --fields player,camera --until 585
#
# --oracle follows the reference past the effects of later steps (the TEST-ONLY replay oracle, godot/tests/trace/replay_oracle.gd: dry
# draws for the placeholder slots, the reference's kills, the reference's projectile list), so that the comparison shows the first
# divergence of what step S5 has ported instead of the first effect it has not. The oracle lives under godot/tests, which the export
# excludes; the simulation cannot enable it.
#
# A non-standard reference (the long run, header "variant": "long_run") is replayed with the overrides of its header
# (player.xpNext / hp / maxHp), and the port trace carries the same "variant" and "overrides".
# Example: tools/emit_port_trace.sh godot/tests/reference/dirs8_424242.jsonl.gz /tmp/port_dirs8_424242.jsonl.gz
# The project is imported first (incremental, about 7 s) so that the class_name scripts are known; SWARM_SKIP_IMPORT=1 skips it.
# Paths may be relative to the current directory. Exit code 0 on success.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PROJECT_DIR="$REPO_ROOT/godot"

die() { printf '[emit_port_trace] ERROR: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  -h | --help)
    awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac
ORACLE=()
POSITIONAL=()
for argument in "$@"; do
  if [[ "$argument" == "--oracle" ]]; then ORACLE=(--oracle); else POSITIONAL+=("$argument"); fi
done
set -- "${POSITIONAL[@]}"
(($# >= 2 && $# <= 3)) || die "usage: tools/emit_port_trace.sh <reference.jsonl.gz> <out.jsonl[.gz]> [until-step] [--oracle]"
[[ -f "$1" ]] || die "no such reference trace: $1"
REFERENCE="$(readlink -f -- "$1")"
mkdir -p -- "$(dirname -- "$2")"
OUT="$(readlink -m -- "$2")"
UNTIL="${3:-0}"

# shellcheck source=lib/toolchain.sh
source "$SCRIPT_DIR/lib/toolchain.sh" || exit 1

if [[ "${SWARM_SKIP_IMPORT:-0}" != "1" ]]; then
  import_log="$(mktemp)"
  trap 'rm -f "$import_log"' EXIT
  timeout --kill-after=15 "${SWARM_IMPORT_TIMEOUT:-600}" bash -c 'swarm_godot "$@"' swarm_godot --headless --path "$PROJECT_DIR" --import >"$import_log" 2>&1 \
    || { sed 's/^/    /' "$import_log" >&2; die "Godot import failed"; }
fi

log="$(mktemp)"
trap 'rm -f "${import_log:-}" "$log"' EXIT
rc=0
timeout --kill-after=15 "${SWARM_TEST_TIMEOUT:-300}" bash -c 'swarm_godot "$@"' swarm_godot \
  --headless --path "$PROJECT_DIR" -s res://tests/trace/emit_port_trace.gd -- "$REFERENCE" "$OUT" "$UNTIL" ${ORACLE[@]+"${ORACLE[@]}"} >"$log" 2>&1 || rc=$?
sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E '^emit_port_trace' || true
errors="$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E '^(SCRIPT ERROR|ERROR|USER ERROR|Parse Error)' | grep -Ev 'resources? still in use at exit|ObjectDB instances leaked|RIDs? of type .* leaked' || true)"
if ((rc != 0)) || [[ -n "$errors" ]]; then
  sed 's/\x1b\[[0-9;]*m//g; s/^/    /' "$log" >&2
  die "the Godot script failed (exit code $rc)"
fi
[[ -s "$OUT" ]] || die "no output was written to $OUT"
