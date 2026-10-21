#!/usr/bin/env bash
# Exports the debug APK with the "Android" export preset (no Gradle, prebuilt template) and
# verifies it: signature, 16 KiB zip alignment, and the manifest facts (package, version,
# SDK levels, ABIs, permissions) against godot/export_presets.cfg.
# Signing uses the throwaway DEBUG keystore created by tools/setup_godot.sh.
#
# Usage: tools/build_android.sh [--apk PATH] [--evidence-dir DIR] [--skip-tests] [--skip-import]
#   --apk PATH           output APK (default: <repo>/export/ElementalSwarm_engine_s1_debug.apk;
#                        inside the repo only below <repo>/export/, which is gitignored)
#   --evidence-dir DIR   keep the Godot logs and the raw tool output there (also SWARM_EVIDENCE_DIR);
#                        files of an earlier run that this script writes are removed first
#   --skip-tests         do not run tools/run_godot_tests.sh before exporting (by default a failing
#                        test, or a main scene that does not compile, stops the build)
#   --skip-import        do not run the headless import before exporting (the tests import anyway)
# Environment: SWARM_IMPORT_TIMEOUT / SWARM_EXPORT_TIMEOUT / SWARM_TEST_TIMEOUT (seconds, default
#   600 / 900 / 600), SWARM_ALLOW_ENGINE_ERRORS=1 (report "ERROR:" lines in the Godot output as
#   warnings only), SWARM_ADB_PORT (private adb server port, default 5199).
# Exit code 0 only if every check passes (WARN lines do not fail the build).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" # physical path, like `readlink -m` below
PROJECT_DIR="$REPO_ROOT/godot"
PRESETS_FILE="$PROJECT_DIR/export_presets.cfg"
PRESET_NAME="Android"

log() { printf '[build] %s\n' "$*"; }
die() { printf '[build] ERROR: %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

APK="$REPO_ROOT/export/ElementalSwarm_engine_s1_debug.apk"
EVIDENCE_DIR="${SWARM_EVIDENCE_DIR:-}"
SKIP_IMPORT=0
SKIP_TESTS=0
while (($#)); do
  case "$1" in
    --apk)
      (($# >= 2)) || die "--apk needs a path"
      APK="$2"
      shift 2
      ;;
    --evidence-dir)
      (($# >= 2)) || die "--evidence-dir needs a directory"
      EVIDENCE_DIR="$2"
      shift 2
      ;;
    --skip-import)
      SKIP_IMPORT=1
      shift
      ;;
    --skip-tests)
      SKIP_TESTS=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

APK="$(readlink -m -- "$APK")"
case "$APK" in
  "$REPO_ROOT"/export/*) ;;
  "$REPO_ROOT"/*) die "refusing to write an APK inside the repo outside export/: $APK" ;;
esac
[[ "$APK" == *.apk ]] || die "output path must end in .apk: $APK"

# shellcheck source=lib/toolchain.sh
source "$SCRIPT_DIR/lib/toolchain.sh" || exit 1
[[ -f "$PROJECT_DIR/project.godot" ]] || die "missing $PROJECT_DIR/project.godot"
[[ -f "$PRESETS_FILE" ]] || die "missing $PRESETS_FILE"

BUILD_TOOLS_DIR="$(dirname -- "$SWARM_APKSIGNER")"
AAPT2="$BUILD_TOOLS_DIR/aapt2"
KEYTOOL="$JAVA_HOME/bin/keytool"
[[ -x "$AAPT2" ]] || die "aapt2 missing: $AAPT2 (run tools/setup_godot.sh)"
export PATH="$JAVA_HOME/bin:$PATH" # apksigner is a wrapper around `java -jar`

# Godot reads the debug signing data from these variables before it looks at the preset or the
# editor settings. The alias and password are Android's public debug-keystore convention.
# (Godot passes the keystore password to apksigner on the command line, where any local process can
# read it. Harmless for this public debug key. The release build in S9 must not do that: export it
# unsigned and sign it here with `apksigner sign --ks-pass env:...` instead.)
KEY_ALIAS="androiddebugkey"
KEY_PASS="android"
export GODOT_ANDROID_KEYSTORE_DEBUG_PATH="$SWARM_DEBUG_KEYSTORE"
export GODOT_ANDROID_KEYSTORE_DEBUG_USER="$KEY_ALIAS"
export GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD="$KEY_PASS"

# Output that is not a build problem: Godot reports leaked objects while shutting down.
SHUTDOWN_NOISE='resources? still in use at exit|ObjectDB instances leaked|RIDs? of type .* leaked'

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
if [[ -n "$EVIDENCE_DIR" ]]; then
  EVIDENCE_DIR="$(readlink -m -- "$EVIDENCE_DIR")"
  mkdir -p -- "$EVIDENCE_DIR"
  # A reused directory must not keep passing evidence of an earlier run next to this run's result.
  (cd -- "$EVIDENCE_DIR" && rm -f -- summary.txt apk.sha256 apksigner-verify.txt signer-cert.txt zipalign-check.txt \
    aapt2-badging.txt aapt2-badging.err aapt2-manifest.txt permissions.txt atlas-entries.txt sim-entries.txt godot-tests.log godot-import.log godot-export.log)
  OUT_DIR="$EVIDENCE_DIR"
else
  OUT_DIR="$WORK_DIR"
fi

# ---- Result bookkeeping -------------------------------------------------------------------------
CHECK_NAMES=()
CHECK_STATES=()
CHECK_DETAILS=()
FAILURES=0
record() { # record <PASS|FAIL|WARN|SKIP> <name> <detail>
  CHECK_STATES+=("$1")
  CHECK_NAMES+=("$2")
  CHECK_DETAILS+=("$3")
  [[ "$1" != FAIL ]] || FAILURES=$((FAILURES + 1))
  printf '[build] %-4s %s - %s\n' "$1" "$2" "$3"
}

# run_godot <timeout-seconds> <log-file> <godot args...>; output only goes to the log file.
run_godot() {
  local seconds=$1 log_file=$2 rc=0
  shift 2 # swarm_godot (exported by toolchain.sh) keeps HOME, TMPDIR and user:// inside the cache dir
  timeout --kill-after=15 "$seconds" bash -c 'swarm_godot "$@"' swarm_godot "$@" >"$log_file" 2>&1 || rc=$?
  return "$rc"
}

show_log() { sed 's/\x1b\[[0-9;]*m//g; s/^/    /' "$1" >&2; } # indented, without Godot's colour codes

engine_errors() { # engine_errors <log-file>: engine/script error lines, minus shutdown noise
  sed 's/\x1b\[[0-9;]*m//g' "$1" | grep -E '^(SCRIPT ERROR|ERROR|USER ERROR|Parse Error)' | grep -Ev "$SHUTDOWN_NOISE" || true
}

preset_option() { # preset_option <key>: value of a key in export_presets.cfg, quotes removed
  sed -n "s|^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$|\1|p" "$PRESETS_FILE" | head -n 1
}

finish() {
  local i total=${#CHECK_NAMES[@]}
  {
    printf 'Elemental Swarm Engine - Android debug build\n'
    printf 'apk: %s\n\n' "$APK"
    for ((i = 0; i < total; i++)); do
      printf '%-4s %s - %s\n' "${CHECK_STATES[i]}" "${CHECK_NAMES[i]}" "${CHECK_DETAILS[i]}"
    done
    if ((FAILURES == 0)); then printf '\nRESULT: PASS\n'; else printf '\nRESULT: FAIL (%d check(s) failed)\n' "$FAILURES"; fi
  } >"$OUT_DIR/summary.txt"
  echo
  echo "================ summary ================"
  cat "$OUT_DIR/summary.txt"
  [[ -z "$EVIDENCE_DIR" ]] || log "evidence written to $EVIDENCE_DIR"
  if ((FAILURES == 0)); then
    log "install on a device with:  \"$SWARM_ADB\" install -r \"$APK\""
    exit 0
  fi
  exit 1
}

describe_failure() { # describe_failure <what> <exit code> <seconds> <env var that raises the limit>
  case "$2" in
    124 | 137) printf '%s timed out after %ss (raise %s)' "$1" "$3" "$4" ;;
    *) printf '%s exited with code %s' "$1" "$2" ;;
  esac
}

# ---- 1. Tests, import and export ----------------------------------------------------------------
# The tests load the main scene, so an APK is never exported from a project whose main script does
# not compile. They also run the (incremental) import.
if ((SKIP_TESTS)); then
  log "skipping tests (--skip-tests)"
else
  log "running the headless tests ..."
  tests_rc=0
  "$SCRIPT_DIR/run_godot_tests.sh" >"$OUT_DIR/godot-tests.log" 2>&1 || tests_rc=$?
  if ((tests_rc != 0)); then
    show_log "$OUT_DIR/godot-tests.log"
    record FAIL "tests" "$(describe_failure "run_godot_tests.sh" "$tests_rc" "${SWARM_TEST_TIMEOUT:-600}" SWARM_TEST_TIMEOUT)"
    finish
  fi
  record PASS "tests" "$(grep -m1 '^Summary:' "$OUT_DIR/godot-tests.log" | sed 's/^Summary: //' || true)"
  SKIP_IMPORT=1 # the test run has just imported the project
fi
if ((SKIP_IMPORT)); then
  log "skipping the separate import"
else
  log "importing project (headless) ..."
  import_rc=0
  run_godot "${SWARM_IMPORT_TIMEOUT:-600}" "$OUT_DIR/godot-import.log" --headless --path "$PROJECT_DIR" --import || import_rc=$?
  if ((import_rc != 0)); then
    show_log "$OUT_DIR/godot-import.log"
    record FAIL "import" "$(describe_failure "godot --import" "$import_rc" "${SWARM_IMPORT_TIMEOUT:-600}" SWARM_IMPORT_TIMEOUT)"
    finish
  fi
fi

mkdir -p -- "$(dirname -- "$APK")"
rm -f -- "$APK" "$APK.idsig" # a stale APK must never pass the checks below
log "exporting preset \"$PRESET_NAME\" (debug) to $APK ..."
export_rc=0
run_godot "${SWARM_EXPORT_TIMEOUT:-900}" "$OUT_DIR/godot-export.log" \
  --headless --path "$PROJECT_DIR" --export-debug "$PRESET_NAME" "$APK" || export_rc=$?

if ((export_rc != 0)); then
  show_log "$OUT_DIR/godot-export.log"
  record FAIL "export" "$(describe_failure "godot --export-debug" "$export_rc" "${SWARM_EXPORT_TIMEOUT:-900}" SWARM_EXPORT_TIMEOUT)"
  finish
fi
if [[ ! -s "$APK" ]]; then
  show_log "$OUT_DIR/godot-export.log"
  record FAIL "export" "Godot reported success but $APK does not exist"
  finish
fi
errors="$(engine_errors "$OUT_DIR/godot-export.log")"
if [[ -n "$errors" ]]; then
  sed 's/^/    /' <<<"$errors" >&2
  if [[ "${SWARM_ALLOW_ENGINE_ERRORS:-0}" == "1" ]]; then
    record WARN "export" "engine errors in the Godot output (allowed by SWARM_ALLOW_ENGINE_ERRORS=1)"
  else
    record FAIL "export" "engine errors in the Godot output (see above)"
  fi
else
  record PASS "export" "$(stat -c %s -- "$APK") bytes"
fi
APK_SHA256="$(sha256sum -- "$APK" | cut -d' ' -f1)"
printf '%s  %s\n' "$APK_SHA256" "$(basename -- "$APK")" >"$OUT_DIR/apk.sha256"
log "apk sha256: $APK_SHA256"

# ---- 2. Signature -------------------------------------------------------------------------------
sig_rc=0
"$SWARM_APKSIGNER" verify --verbose --print-certs "$APK" >"$OUT_DIR/apksigner-verify.txt" 2>&1 || sig_rc=$?
grep -v '^Picked up JAVA_TOOL_OPTIONS' "$OUT_DIR/apksigner-verify.txt" | sed 's/^/    /' || true
if ((sig_rc != 0)); then
  record FAIL "apksigner verify" "exit code $sig_rc"
elif ! grep -Eq 'Verified using v[23] scheme .*: true' "$OUT_DIR/apksigner-verify.txt"; then
  record FAIL "apksigner verify" "exit 0 but neither the v2 nor the v3 scheme is reported as verified"
else
  record PASS "apksigner verify" "$(grep -Eo 'Verified using v[0-9] scheme[^:]*: true' "$OUT_DIR/apksigner-verify.txt" | sed 's/Verified using //; s/ scheme.*//' | paste -sd, -) verified"
fi

apk_cert="$(grep -Eo 'certificate SHA-256 digest: *[0-9a-fA-F:]+' "$OUT_DIR/apksigner-verify.txt" | head -n 1 | sed 's/^[^:]*: *//' | tr -d ':' | tr 'A-F' 'a-f' || true)"
key_cert="$("$KEYTOOL" -J-Duser.language=en -J-Duser.country=US -list -keystore "$SWARM_DEBUG_KEYSTORE" \
  -alias "$KEY_ALIAS" -storepass "$KEY_PASS" 2>/dev/null |
  grep -Eo 'SHA-?256\)?: *[0-9A-Fa-f:]+' | head -n 1 | sed 's/^[^:]*: *//' | tr -d ':' | tr 'A-F' 'a-f' || true)"
printf 'apk signer certificate sha256:      %s\nkeystore certificate sha256:        %s\n' "${apk_cert:-?}" "${key_cert:-?}" >"$OUT_DIR/signer-cert.txt"
if [[ -z "$apk_cert" || -z "$key_cert" ]]; then
  record SKIP "signed with the debug keystore" "could not read a certificate digest (see $OUT_DIR/signer-cert.txt)"
elif [[ "$apk_cert" == "$key_cert" ]]; then
  record PASS "signed with the debug keystore" "certificate sha256 ${apk_cert:0:16}..."
else
  record FAIL "signed with the debug keystore" "APK signer ${apk_cert:0:16}... differs from keystore ${key_cert:0:16}..."
fi

# ---- 3. Zip alignment (16 KiB pages) ------------------------------------------------------------
zip_rc=0
"$SWARM_ZIPALIGN" -c -P 16 -v 4 "$APK" >"$OUT_DIR/zipalign-check.txt" 2>&1 || zip_rc=$?
tail -n 5 "$OUT_DIR/zipalign-check.txt" | sed 's/^/    /'
if ((zip_rc == 0)); then
  record PASS "zipalign -c -P 16 -v 4" "stored entries are 16 KiB / 4-byte aligned"
else
  record FAIL "zipalign -c -P 16 -v 4" "exit code $zip_rc (see $OUT_DIR/zipalign-check.txt)"
fi

# ---- 4. Manifest facts --------------------------------------------------------------------------
badging_rc=0
"$AAPT2" dump badging "$APK" >"$OUT_DIR/aapt2-badging.txt" 2>"$OUT_DIR/aapt2-badging.err" || badging_rc=$?
if ((badging_rc != 0)); then
  record FAIL "aapt2 dump badging" "exit code $badging_rc ($(head -n 1 "$OUT_DIR/aapt2-badging.err"))"
  finish
fi
badging="$(<"$OUT_DIR/aapt2-badging.txt")"
package_line="$(grep -m1 '^package:' <<<"$badging" || true)"
attr() { sed -n "s/.* $1='\([^']*\)'.*/\1/p" <<<"$package_line"; }

want_package="$(preset_option package/unique_name)"
want_code="$(preset_option version/code)"
want_name="$(preset_option version/name)"
want_label="$(preset_option package/name)"
want_abis="$(sed -n 's|^architectures/\(.*\)=true$|\1|p' "$PRESETS_FILE" | sort | paste -sd' ' -)"
got_abis="$(sed -n "s/^native-code: *//p" <<<"$badging" | tr -d "'" | tr ' ' '\n' | sed '/^$/d' | sort | paste -sd' ' -)"
sdk_min="$(sed -n "s/^minSdkVersion:'\([0-9]*\)'.*/\1/p" <<<"$badging" | head -n 1)"
sdk_target="$(sed -n "s/^targetSdkVersion:'\([0-9]*\)'.*/\1/p" <<<"$badging" | head -n 1)"
label="$(sed -n "s/^application-label:'\(.*\)'$/\1/p" <<<"$badging" | head -n 1)"
# aapt2 does not list Godot's launcher activity-alias as launchable-activity, so read the manifest.
"$AAPT2" dump xmltree --file AndroidManifest.xml "$APK" >"$OUT_DIR/aapt2-manifest.txt" 2>/dev/null || true
manifest="$(<"$OUT_DIR/aapt2-manifest.txt")"
orientation="$(grep -m1 ':screenOrientation(' <<<"$manifest" | sed 's/.*)=//' || true)"

expect() { # expect <name> <got> <want>
  if [[ -n "$3" && "$2" == "$3" ]]; then record PASS "$1" "$2"; else record FAIL "$1" "got '$2', expected '$3'"; fi
}
expect "package name" "$(attr name)" "$want_package"
expect "versionCode" "$(attr versionCode)" "$want_code"
expect "versionName" "$(attr versionName)" "$want_name"
expect "application label" "$label" "$want_label"
expect "native-code ABIs" "$got_abis" "$want_abis"
if grep -q '"android.intent.action.MAIN"' <<<"$manifest" && grep -q '"android.intent.category.LAUNCHER"' <<<"$manifest"; then
  record PASS "launcher intent" "MAIN + LAUNCHER declared"
else
  record FAIL "launcher intent" "no MAIN/LAUNCHER intent filter in the manifest"
fi
# Design 6.1 / fg.4 use 10 (fullSensor). Godot 4.7.2's prebuilt-template exporter writes 13 (fullUser) for
# "Sensor": all four orientations, but the system rotation lock applies. The user ACCEPTED 13 on 2026-10-19
# (design 6.1), so it passes; 10 stays accepted (a Gradle build in S9 might emit it). Any other value fails.
case "$orientation" in
  10) record PASS "screenOrientation" "10 (fullSensor)" ;;
  13) record PASS "screenOrientation" "13 (fullUser), accepted by the user on 2026-10-19 (design 6.1): the system rotation lock applies; Godot 4.7.2's non-Gradle exporter cannot emit 10" ;;
  *) record FAIL "screenOrientation" "got '$orientation', expected 13 (fullUser, accepted) or 10 (fullSensor)" ;;
esac
if [[ -n "$sdk_min" && -n "$sdk_target" ]]; then
  record PASS "SDK levels" "minSdkVersion=$sdk_min targetSdkVersion=$sdk_target"
else
  record FAIL "SDK levels" "minSdkVersion='$sdk_min' targetSdkVersion='$sdk_target' not found in badging"
fi

# 64-bit native libraries must be linked for 16 KiB pages (Android 15+ devices with 16 KiB pages).
if command -v readelf >/dev/null 2>&1; then
  unzip -q -o -d "$WORK_DIR/apk" "$APK" 'lib/arm64-v8a/*.so' 'lib/x86_64/*.so' 2>/dev/null || true
  elf_bad=""
  elf_count=0
  while IFS= read -r so_file; do
    elf_count=$((elf_count + 1))
    while IFS= read -r align; do # one hex value (0x4000) per LOAD segment
      ((align >= 16384)) || elf_bad+=" $(basename -- "$so_file")=$align"
    done < <(readelf -lW "$so_file" 2>/dev/null | awk '$1 == "LOAD" { print $NF }')
  done < <(find "$WORK_DIR/apk" -name '*.so' 2>/dev/null | sort)
  if ((elf_count == 0)); then
    record SKIP "ELF 16 KiB alignment" "no 64-bit libraries found to inspect"
  elif [[ -z "$elf_bad" ]]; then
    record PASS "ELF 16 KiB alignment" "$elf_count 64-bit librar(ies), every LOAD segment aligned to >= 0x4000"
  else
    record FAIL "ELF 16 KiB alignment" "segment alignment below 16384:$elf_bad"
  fi
else
  record SKIP "ELF 16 KiB alignment" "readelf not installed"
fi

# No permissions at all: no <uses-permission*> and no app-declared <permission*> element in the manifest
# (aapt2 xmltree, the source of truth) and none in the badging output. An AndroidX-based build (Gradle,
# S9) adds "<package>.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"; that is only a WARN, so it is a
# visible decision for the user instead of slipping through. Everything else fails.
manifest_perms="$(awk '
  function flush() { if (pending != "") print pending " ?"; pending = "" }
  $1 == "E:" {
    flush(); elem = ""
    if ($2 ~ /^(uses-permission[a-z0-9-]*|permission|permission-tree|permission-group)$/) { elem = $2; pending = $2 }
    next
  }
  elem != "" && $1 == "A:" && match($0, /:name\(0x[0-9a-fA-F]+\)="[^"]*"/) {
    v = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", v); sub(/"$/, "", v)
    print elem " " v; pending = ""
  }
  END { flush() }
' <<<"$manifest")"
badging_perms="$(grep -Eo "^(uses-permission|permission)[a-z0-9-]*: name='[^']+'" <<<"$badging" | sed "s/: name='/ /; s/'\$//" || true)"
requested="$(printf '%s\n%s\n' "$manifest_perms" "$badging_perms" | sed '/^$/d' | sort -u)"
printf '%s\n' "$requested" >"$OUT_DIR/permissions.txt"
androidx_perm="$want_package.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
unexpected="$(grep -Fvx -e "uses-permission $androidx_perm" -e "permission $androidx_perm" <<<"$requested" | sed '/^$/d' || true)"
if [[ -z "$requested" ]]; then
  record PASS "permissions" "none requested or declared"
elif [[ -z "$unexpected" ]]; then
  record WARN "permissions" "only the app-internal AndroidX $androidx_perm (grants nothing outside the app); needs the user's OK"
else
  record FAIL "permissions" "unexpected: $(paste -sd';' - <<<"$unexpected")"
fi

# Godot 4.7.2's non-Gradle exporter rewrites the authorities of EVERY <provider> to
# "<package>.fileprovider" (export_plugin.cpp), so the AndroidX startup provider ends up sharing
# the FileProvider's authority. Only a warning: it cannot be fixed from this repo, and it has not
# been tested on a device (design 9.5).
dup_authorities="$(awk '/ E: / { in_provider = ($0 ~ /E: provider /) }
  in_provider && /:authorities\(/ { match($0, /="[^"]*"/); print substr($0, RSTART + 2, RLENGTH - 3) }' <<<"$manifest" | sort | uniq -d || true)"
if [[ -z "$dup_authorities" ]]; then
  record PASS "provider authorities" "unique"
else
  record WARN "provider authorities" "duplicate authority in the exported manifest: $(paste -sd' ' - <<<"$dup_authorities") (Godot 4.7.2 exporter behaviour; see tools/build_android.sh)"
fi

# ---- 5. Atlas assets (step S2) -------------------------------------------------------------------
# Every image of godot/assets/atlas/atlas_manifest.json must be in the APK as its imported texture
# (assets/.godot/imported/<file>.webp-<md5>.ctex; the exporter packs the .ctex, not the .webp), and the
# layout and manifest JSON files must be packed too (AtlasLayout reads atlas_layout.json at run time).
ATLAS_MANIFEST="$PROJECT_DIR/assets/atlas/atlas_manifest.json"
if [[ ! -f "$ATLAS_MANIFEST" ]]; then
  record SKIP "atlas assets" "no $ATLAS_MANIFEST"
else
  apk_entries="$(unzip -Z1 "$APK")"
  atlas_missing=""
  atlas_count=0
  : >"$OUT_DIR/atlas-entries.txt"
  while IFS= read -r atlas_file; do
    [[ -n "$atlas_file" ]] || continue
    atlas_count=$((atlas_count + 1))
    atlas_pattern="^assets/\\.godot/imported/${atlas_file//./\\.}-[0-9a-f]{32}\\.ctex\$"
    if ! grep -Eq "$atlas_pattern" <<<"$apk_entries"; then atlas_missing+=" $atlas_file"; fi
  done < <(sed -n 's/^ *"file": "\(.*\.webp\)",\{0,1\}$/\1/p' "$ATLAS_MANIFEST")
  for atlas_json in atlas_layout.json atlas_manifest.json; do
    grep -Fxq "assets/assets/atlas/$atlas_json" <<<"$apk_entries" || atlas_missing+=" $atlas_json"
  done
  # Evidence: every APK entry that comes from godot/assets/atlas or render/atlas_layout.gd (size, compressed size, name).
  unzip -v "$APK" | awk '$NF ~ /atlas|\.godot\/imported\/(art_|enemy_fx_|overhaul_|signature_fx|range_fx)/ { printf "%10d %10d  %s\n", $1, $3, $NF }' >"$OUT_DIR/atlas-entries.txt"
  atlas_bytes="$(awk '$3 ~ /\.ctex$/ { total += $1 } END { print total + 0 }' "$OUT_DIR/atlas-entries.txt")"
  if ((atlas_count == 0)); then
    record FAIL "atlas assets" "no .webp files listed in $ATLAS_MANIFEST"
  elif [[ -z "$atlas_missing" ]]; then
    record PASS "atlas assets" "$atlas_count textures (.ctex, $atlas_bytes bytes) + atlas_layout.json + atlas_manifest.json are in the APK"
  else
    record FAIL "atlas assets" "missing from the APK:$atlas_missing"
  fi
fi

# ---- 6. Sim definitions and scripts -------------------------------------------------------------
# Derived from the repo, not from a fixed list: every godot/sim/defs/**/*.json is packed as-is
# (assets/sim/defs/..., the preset's include_filter sim/defs/*.json); every godot/sim/**/*.gd is packed
# as its binary-token export assets/sim/**/<name>.gdc (script_export_mode=2; the .gd.remap next to it
# is not checked); nothing under godot/tests/ is packed (the preset's exclude_filter tests/*).
apk_entries="$(unzip -Z1 "$APK")"
sim_missing=""
sim_defs_count=0
sim_scripts_count=0
while IFS= read -r sim_file; do
  [[ -n "$sim_file" ]] || continue
  sim_defs_count=$((sim_defs_count + 1))
  sim_rel="${sim_file#"$PROJECT_DIR"/}"
  grep -Fxq -- "assets/$sim_rel" <<<"$apk_entries" || sim_missing+=" $sim_rel"
done < <(find "$PROJECT_DIR/sim/defs" -type f -name '*.json' 2>/dev/null | sort || true)
while IFS= read -r sim_file; do
  [[ -n "$sim_file" ]] || continue
  sim_scripts_count=$((sim_scripts_count + 1))
  sim_rel="${sim_file#"$PROJECT_DIR"/}"
  grep -Fxq -- "assets/${sim_rel%.gd}.gdc" <<<"$apk_entries" || sim_missing+=" $sim_rel"
done < <(find "$PROJECT_DIR/sim" -type f -name '*.gd' 2>/dev/null | sort || true)
tests_entries="$(grep '^assets/tests/' <<<"$apk_entries" || true)"
tests_count="$(sed '/^$/d' <<<"$tests_entries" | wc -l)"
# Evidence: every APK entry under assets/sim/ or assets/tests/ (size, compressed size, name).
unzip -v "$APK" | awk '$NF ~ "^assets/(sim|tests)/" { printf "%10d %10d  %s\n", $1, $3, $NF }' >"$OUT_DIR/sim-entries.txt"
if ((sim_defs_count == 0 || sim_scripts_count == 0)); then
  record FAIL "sim definitions" "repo has $sim_defs_count godot/sim/defs/*.json and $sim_scripts_count godot/sim/**/*.gd; both must be above 0"
elif [[ -n "$sim_missing" ]] || ((tests_count > 0)); then
  detail=""
  [[ -z "$sim_missing" ]] || detail+="missing from the APK:$sim_missing"
  if ((tests_count > 0)); then
    [[ -z "$detail" ]] || detail+="; "
    detail+="$tests_count godot/tests/ entr(ies) in the APK, must be 0: $(paste -sd' ' - <<<"$tests_entries" | cut -c1-200)"
  fi
  record FAIL "sim definitions" "$detail"
else
  record PASS "sim definitions" "$sim_defs_count defs JSON + $sim_scripts_count sim scripts (.gdc) in the APK, $tests_count godot/tests/ entries"
fi

finish
