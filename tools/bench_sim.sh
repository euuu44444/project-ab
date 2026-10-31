#!/usr/bin/env bash
# Benchmark of Sim.step for the decision of design section 5.5 (the cost of the bit-exact math, step S9 data): deterministic stress states
# (100 swarm enemies bunched around the player; 100 mixed swarm/assassin at spawn distance; 30 enemies of a typical early wave), the median
# and p95 of Sim.step over at least 600 steps each, the time of the heaviest slots, the cost of one JsMath call, and how many JsMath
# transcendental calls (sin, cos, atan, atan2, exp, log, hypot, pow) a step makes, by function and by slot.
#
#   tools/bench_sim.sh [--steps N] [--only a,b,c] [--no-profile]
#
#   --steps N      steps measured per scenario (default 600)
#   --only LIST    scenarios to run (a, b, c; default all)
#   --no-profile   skip the two profiling builds below (no JsMath call counts, no builtin-math experiment)
#
# The script (godot/tests/bench/bench_sim.gd, excluded from the export like every file under godot/tests) is run three times with the same Godot:
#   1. in a PROFILING copy of the sim (a temporary project that holds godot/sim with a js_compat.gd that counts the calls of the functions
#      above, see tools/lib/make_jsmath_profile.mjs). The production code has no counter and is not touched;
#   2. in a BUILTIN-MATH copy (the same, but sin, cos, atan, atan2, exp, log, pow forward to the engine's builtins and hypot to
#      sqrt(x*x + y*y), not bit-exact): the experiment that shows what the bit-exact math costs;
#   3. in the real project, which times the steps, so that no instrumentation is part of a measured number. It reads the results of 1 and 2.
# Runs 1 and 3 build the same game from the same seed, so the counted steps are the timed steps (the report prints the state fingerprints).
# The numbers are of the machine that runs it (the CPU model is printed), of the headless editor binary, not of a phone.
# Environment: SWARM_SKIP_IMPORT=1 (skip the incremental import), SWARM_BENCH_TIMEOUT=<seconds> (default 900 per Godot run).
# Exit code 0 only if every run finishes and prints no engine or script errors (and the counted game is the timed game).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PROJECT_DIR="$REPO_ROOT/godot"

die() { printf '[bench] ERROR: %s\n' "$*" >&2; exit 1; }

STEPS=600
ONLY=""
PROFILE=1
while (($#)); do
  case "$1" in
    --steps)
      (($# >= 2)) || die "--steps needs a number"
      STEPS="$2"
      shift 2
      ;;
    --only)
      (($# >= 2)) || die "--only needs a list such as a,b,c"
      ONLY="$2"
      shift 2
      ;;
    --no-profile)
      PROFILE=0
      shift
      ;;
    -h | --help)
      awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
[[ "$STEPS" =~ ^[0-9]+$ ]] && ((STEPS >= 1)) || die "--steps must be a positive integer"
[[ -z "$ONLY" || "$ONLY" =~ ^[a-c](,[a-c])*$ ]] || die "--only must be a comma separated list of a, b, c"

# shellcheck source=lib/toolchain.sh
source "$SCRIPT_DIR/lib/toolchain.sh" || exit 1
[[ -f "$PROJECT_DIR/project.godot" ]] || die "missing $PROJECT_DIR/project.godot"
if ((PROFILE)); then command -v node >/dev/null 2>&1 || die "node is needed for the profiling builds (or use --no-profile)"; fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
SHUTDOWN_NOISE='resources? still in use at exit|ObjectDB instances leaked|RIDs? of type .* leaked'
TIMEOUT="${SWARM_BENCH_TIMEOUT:-900}"

# run_godot <log-file> <godot args...>: returns Godot's exit code (124 on timeout); the output only goes to the log.
run_godot() {
  local log_file=$1 rc=0
  shift
  timeout --kill-after=15 "$TIMEOUT" bash -c 'swarm_godot "$@"' swarm_godot "$@" >"$log_file" 2>&1 || rc=$?
  return "$rc"
}

# check_run <name> <rc> <log-file>: dies when Godot failed or the output holds engine/script errors.
check_run() {
  local errors
  errors="$(sed 's/\x1b\[[0-9;]*m//g' "$3" | grep -E '^(SCRIPT ERROR|ERROR|USER ERROR|Parse Error)' | grep -Ev "$SHUTDOWN_NOISE" || true)"
  if (($2 != 0)) || [[ -n "$errors" ]]; then
    sed 's/\x1b\[[0-9;]*m//g; s/^/    /' "$3" >&2
    die "$1 failed (exit code $2${errors:+, engine or script errors in the output}); output above"
  fi
}

cpu_model="$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | head -n 1)"
cpu_threads="$(grep -c '^processor' /proc/cpuinfo || true)"
printf 'bench_sim.sh: Sim.step benchmark for design 5.5\n'
printf 'machine:   %s, %s logical cores, Linux %s\n' "${cpu_model:-unknown CPU}" "${cpu_threads:-?}" "$(uname -r)"
printf 'godot:     %s\n' "$(swarm_godot --version 2>/dev/null | head -n 1 || echo unknown)"
printf 'command:   tools/bench_sim.sh --steps %s%s%s\n' "$STEPS" "${ONLY:+ --only $ONLY}" "$( ((PROFILE)) || echo ' --no-profile')"
printf '\n'

script_args=(--steps="$STEPS")
[[ -z "$ONLY" ]] || script_args+=(--only="$ONLY")

# 1. the real project must be imported (the class_name cache knows the sim classes)
if [[ "${SWARM_SKIP_IMPORT:-0}" != "1" ]]; then
  rc=0
  run_godot "$WORK_DIR/import.log" --headless --path "$PROJECT_DIR" --import || rc=$?
  check_run "the import of the project" "$rc" "$WORK_DIR/import.log"
fi

# 2. the profiling copy (counts the JsMath calls) and the builtin-math copy (what the math costs): two throw-away projects that hold the sim,
# the benchmark script and a rewritten js_compat.gd
make_copy() { # make_copy <dir> [--builtin]
  local dir=$1
  shift
  mkdir -p "$dir/tests"
  sed '/^run\/main_scene=/d' "$PROJECT_DIR/project.godot" >"$dir/project.godot" # the copy has no scenes
  cp -a -- "$PROJECT_DIR/sim" "$dir/sim"
  cp -a -- "$PROJECT_DIR/tests/bench" "$dir/tests/bench"
  node "$SCRIPT_DIR/lib/make_jsmath_profile.mjs" "$@" "$PROJECT_DIR/sim/js_compat.gd" "$dir/sim/js_compat.gd" || die "the copy of js_compat.gd for $dir could not be made"
  rc=0
  run_godot "$dir/import.log" --headless --path "$dir" --import || rc=$?
  check_run "the import of $dir" "$rc" "$dir/import.log"
}
if ((PROFILE)); then
  PROFILE_DIR="$WORK_DIR/profile_project"
  make_copy "$PROFILE_DIR" >"$WORK_DIR/profile_build.log"
  rc=0
  run_godot "$WORK_DIR/count.log" --headless --path "$PROFILE_DIR" -s res://tests/bench/bench_sim.gd -- --mode=count "${script_args[@]}" \
    --out="$WORK_DIR/counts.json" || rc=$?
  check_run "the counting run (profiling build)" "$rc" "$WORK_DIR/count.log"
  [[ -s "$WORK_DIR/counts.json" ]] || die "the counting run wrote no counts"
  BUILTIN_DIR="$WORK_DIR/builtin_project"
  make_copy "$BUILTIN_DIR" --builtin >"$WORK_DIR/builtin_build.log"
  rc=0
  run_godot "$WORK_DIR/builtin.log" --headless --path "$BUILTIN_DIR" -s res://tests/bench/bench_sim.gd -- --mode=steps "${script_args[@]}" \
    --out="$WORK_DIR/builtin.json" || rc=$?
  check_run "the builtin-math run" "$rc" "$WORK_DIR/builtin.log"
  [[ -s "$WORK_DIR/builtin.json" ]] || die "the builtin-math run wrote no statistics"
  script_args+=(--counts="$WORK_DIR/counts.json" --builtin="$WORK_DIR/builtin.json")
fi

# 3. the timing run in the real project; its report is the output of this script
rc=0
run_godot "$WORK_DIR/time.log" --headless --path "$PROJECT_DIR" -s res://tests/bench/bench_sim.gd -- --mode=time "${script_args[@]}" || rc=$?
check_run "the timing run" "$rc" "$WORK_DIR/time.log"
sed 's/\x1b\[[0-9;]*m//g' "$WORK_DIR/time.log" | grep -Ev '^Godot Engine v' | sed '/./,$!d' || true
if sed 's/\x1b\[[0-9;]*m//g' "$WORK_DIR/time.log" | grep -q 'WARNING:'; then
  die "the report contains a WARNING line (the counted game is not the timed game); see above"
fi
if ((PROFILE)); then
  printf '\n%s\n%s\n' "profiling build:    $(cat "$WORK_DIR/profile_build.log")" "builtin-math build: $(cat "$WORK_DIR/builtin_build.log")"
  sed 's/\x1b\[[0-9;]*m//g' "$WORK_DIR/count.log" | grep -E '^bench_sim count:' | sed 's/^/count run:  /'
  sed 's/\x1b\[[0-9;]*m//g' "$WORK_DIR/builtin.log" | grep -E '^bench_sim steps:' | sed 's/^/builtin run: /'
fi
