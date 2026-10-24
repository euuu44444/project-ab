#!/usr/bin/env bash
# Builds the GDExtension library swarm_native (native/) with the pinned toolchain from
# tools/setup_cpp.sh (godot-cpp at its pinned commit, NDK r28b, scons from the venv) and writes
#   godot/bin/libswarm_native.<platform>.<target>.<arch>.so      (godot/bin/ is gitignored)
# for linux x86_64 and android arm64 / arm32, each as template_debug and template_release.
# Object files and generated bindings live in the cache dir (SWARM_CACHE_DIR), never in the repo.
# godot-cpp is built with the build profile native/build_profile.json (bindings only for the engine classes
# the extension uses: about 60 godot-cpp files instead of 1,093 per configuration).
# The build is incremental: a second run without changes only runs scons' up-to-date check.
#
# native/SConstruct refuses to build unless the substituted compile and link commands consist of allowlisted
# flags only (no fast-math, -O3, LTO, -march=native, ... whatever variable it came through). After every
# configuration the library is checked, and any failed check fails the script:
#   - the ELF header (class and machine) is the one of the target, the entry symbol is exported
#   - android arm64: every LOAD segment is aligned to >= 0x4000 (16 KiB pages)
#   - android: no dependency on libc++_shared.so (the STL is linked statically)
#   - no path of this machine (cache dir, checkout, home directory, NDK) is embedded in the library
#   - floating point: the compiled body of the probe function (a * b + c) holds no fused multiply-add
#     instruction, and the same source compiled WITH -ffp-contract=fast does (so the check can fail);
#     and none of the objects of native/src (every .cpp at any depth) holds one
#
# Usage: tools/build_native.sh [--host-only | --android-only] [--debug-only | --release-only]
#                              [--jobs N] [--verbose] [--clean] [--evidence-dir DIR]
#   --host-only        linux x86_64 only (the headless editor, the tests, a desktop export). Needs the host
#                      toolchain only: tools/setup_cpp.sh --host-only is enough, no Android NDK.
#   --android-only     android arm64 and arm32 only
#   --debug-only       template_debug only (what the editor and the tests load; debug APK)
#   --release-only     template_release only
#   --jobs N           parallel compile jobs (default: number of CPU cores)
#   --verbose          show scons' output while it runs (default: log file, summary only)
#   --clean            remove the build directories and libraries of the selected configurations first
#   --evidence-dir DIR keep the scons logs, readelf output, the checked flag lists and the disassembly of the probe there
# Exit code 0 only if every selected configuration builds and passes its checks.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
NATIVE_DIR="$REPO_ROOT/native"
OUT_DIR="$REPO_ROOT/godot/bin"
LIB_PREFIX="libswarm_native"
ENTRY_SYMBOL="swarm_native_library_init"
PROBE_SYMBOL="swarm_fp_probe_mul_add"
LIB_OBJ_DIR="swarm_native" # below the config's build directory (native/SConstruct)

log() { printf '[native] %s\n' "$*"; }
die() { printf '[native] ERROR: %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

WANT_HOST=1
WANT_ANDROID=1
WANT_DEBUG=1
WANT_RELEASE=1
JOBS="$(nproc 2>/dev/null || echo 2)"
VERBOSE=0
CLEAN=0
EVIDENCE_DIR=""
while (($#)); do
  case "$1" in
    --host-only) WANT_ANDROID=0; shift ;;
    --android-only) WANT_HOST=0; shift ;;
    --debug-only) WANT_RELEASE=0; shift ;;
    --release-only) WANT_DEBUG=0; shift ;;
    --jobs)
      (($# >= 2)) || die "--jobs needs a number"
      JOBS="$2"
      shift 2
      ;;
    --verbose) VERBOSE=1; shift ;;
    --clean) CLEAN=1; shift ;;
    --evidence-dir)
      (($# >= 2)) || die "--evidence-dir needs a directory"
      EVIDENCE_DIR="$(readlink -m -- "$2")"
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
[[ "$JOBS" =~ ^[0-9]+$ ]] && ((JOBS >= 1)) || die "--jobs must be a positive integer"
((WANT_HOST || WANT_ANDROID)) || die "--host-only and --android-only exclude each other"
((WANT_DEBUG || WANT_RELEASE)) || die "--debug-only and --release-only exclude each other"

SWARM_CPP_HOST_ONLY=$((WANT_ANDROID == 0 ? 1 : 0)) # assigned, not inherited; without an Android build the NDK is not required
# shellcheck source=lib/cpp_toolchain.sh
source "$SCRIPT_DIR/lib/cpp_toolchain.sh" || exit 1
[[ -f "$NATIVE_DIR/SConstruct" ]] || die "missing $NATIVE_DIR/SConstruct"
[[ -f "$NATIVE_DIR/build_profile.json" ]] || die "missing $NATIVE_DIR/build_profile.json"
case "$OUT_DIR" in "$REPO_ROOT"/godot/bin) ;; *) die "unexpected output directory: $OUT_DIR" ;; esac

# The disassembler: the NDK's llvm-objdump for the Android ABIs; for the host's x86-64 code the host's
# llvm-objdump (so that a host-only setup works without the NDK), the NDK's only if the host has none.
NDK_OBJDUMP="$SWARM_NDK_BIN/llvm-objdump"
HOST_OBJDUMP="$(swarm_find_host_objdump)"
objdump_for() { # objdump_for <arch>
  case "$1" in
    x86_64) printf '%s' "${HOST_OBJDUMP:-$NDK_OBJDUMP}" ;;
    *) printf '%s' "$NDK_OBJDUMP" ;;
  esac
}
if ((WANT_ANDROID)); then [[ -x "$NDK_OBJDUMP" ]] || die "llvm-objdump missing in the NDK: $NDK_OBJDUMP"; fi
if ((WANT_HOST)); then [[ -x "$(objdump_for x86_64)" ]] || die "llvm-objdump not found (Debian/Ubuntu: apt install llvm)"; fi
OBJDUMP=""
command -v readelf >/dev/null 2>&1 || die "readelf (binutils) is required"

# One build at a time per cache: two scons runs on the same build directory would corrupt it.
mkdir -p "$SWARM_NATIVE_BUILD_DIR/logs" "$OUT_DIR"
exec 8>"$SWARM_NATIVE_BUILD_DIR/.build.lock"
flock -n 8 || { log "another build_native.sh is running; waiting for it ..."; flock 8; }

if [[ -n "$EVIDENCE_DIR" ]]; then mkdir -p -- "$EVIDENCE_DIR"; fi

# Configurations in build order: "platform target arch".
CONFIGS=()
add_config() { CONFIGS+=("$1 $2 $3"); }
for target in template_debug template_release; do
  [[ "$target" == template_debug && $WANT_DEBUG == 0 ]] && continue
  [[ "$target" == template_release && $WANT_RELEASE == 0 ]] && continue
  if ((WANT_HOST)); then add_config linux "$target" x86_64; fi
done
for arch in arm64 arm32; do
  for target in template_debug template_release; do
    [[ "$target" == template_debug && $WANT_DEBUG == 0 ]] && continue
    [[ "$target" == template_release && $WANT_RELEASE == 0 ]] && continue
    if ((WANT_ANDROID)); then add_config android "$target" "$arch"; fi
  done
done

FAILURES=0
RESULT_LINES=()
record() { # record <PASS|FAIL> <config> <detail>
  RESULT_LINES+=("$(printf '%-4s %-36s %s' "$1" "$2" "$3")")
  [[ "$1" != FAIL ]] || FAILURES=$((FAILURES + 1))
}

# ---- Checks ---------------------------------------------------------------------------------------
# Instructions that must NOT appear in the probe, and what the unfused probe must consist of (per ISA).
# arm64: fmadd fmsub fnmadd fnmsub (scalar), fmla fmls (vector); arm32: vfma vfms vfnma vfnms (VFPv4);
# x86-64: vfmadd* vfmsub* vfnmadd* vfnmsub* (FMA3) and the FMA4 forms.
# arm32 has two correct unfused spellings: vmul.f64 + vadd.f64, or vmla.f64. VMLA is the "chained"
# multiply-accumulate of VFPv2/v3 (ARM ARM: FPAdd(addend, FPMul(a, b))): it rounds the product before
# the addition, unlike the fused VFMA of VFPv4.
fused_regex() {
  case "$1" in
    arm64) echo '^(fmadd|fmsub|fnmadd|fnmsub|fmla|fmls)$' ;;
    arm32) echo '^(vfma|vfms|vfnma|vfnms)(\.|$)' ;;
    x86_64) echo '^vf(n?m(add|sub)|m(add|sub))' ;;
  esac
}
# has_plain_ops <arch> <mnemonics, space separated>: the body holds the separate multiply and add
has_plain_ops() {
  local arch=$1 m=" $2 "
  case "$arch" in
    arm64) [[ "$m" == *" fmul "* && "$m" == *" fadd "* ]] ;;
    arm32) [[ ( "$m" == *" vmul.f64 "* && "$m" == *" vadd.f64 "* ) || "$m" == *" vmla.f64 "* ]] ;;
    x86_64) [[ "$m" == *" mulsd "* && "$m" == *" addsd "* ]] ;;
  esac
}

# mnemonics_of <objdump output file>: one mnemonic per line (the first word after the address and tab)
mnemonics_of() {
  awk '$1 ~ /^[0-9a-f]+:$/ { print $2 }' "$1"
}

# disassemble_probe <object file> <output file>
disassemble_probe() {
  "$OBJDUMP" -d --no-show-raw-insn --disassemble-symbols="$PROBE_SYMBOL" "$1" >"$2" 2>&1 || return 1
  [[ -n "$(mnemonics_of "$2")" ]]
}

# compile_probe_control <arch> <output object>: the probe source with fusing allowed
compile_probe_control() {
  local arch=$1 out=$2 src="$NATIVE_DIR/src/fp_probe.cpp"
  local common=(-std=c++17 -O2 -fPIC -ffp-contract=fast -c "$src" -o "$out")
  case "$arch" in
    arm64) "$SWARM_NDK_BIN/clang++" --target=aarch64-linux-android24 -march=armv8-a "${common[@]}" ;;
    arm32) "$SWARM_NDK_BIN/clang++" --target=armv7a-linux-androideabi24 -march=armv7-a -mfpu=neon-vfpv4 "${common[@]}" ;;
    x86_64) clang++ -march=x86-64 -mfma "${common[@]}" ;;
  esac
}

# scan_own_objects <arch> <config build dir> <work dir>: no fused instruction anywhere in our own code (every
# object of native/src, at any depth, not only the probe); sets SCAN_DETAIL. This is what keeps the simulation
# code of steps C2/C3 honest: it only has to be added below native/src. The objects come from the list
# native/SConstruct writes (own-objects.txt, what is linked into the library); that list must equal the
# .cpp files found below native/src by a separate find, so a source can neither be missed nor be stale.
scan_own_objects() {
  local arch=$1 cfgdir=$2 work=$3 bad_re rel obj count=0 fused="" listing="$3/all.txt" manifest="$2/own-objects.txt" expected
  bad_re="$(fused_regex "$arch")"
  [[ -s "$manifest" ]] || { SCAN_DETAIL="no list of objects ($manifest)"; return 1; }
  expected="$(cd -- "$NATIVE_DIR/src" && find . -type f -name '*.cpp' | sed "s|^\./|$LIB_OBJ_DIR/|; s|\.cpp\$|.os|" | LC_ALL=C sort)"
  [[ "$(LC_ALL=C sort "$manifest")" == "$expected" ]] \
    || { SCAN_DETAIL="own-objects.txt does not list exactly the objects of native/src/**/*.cpp"; return 1; }
  : >"$work/scan-mnemonics.txt"
  while IFS= read -r rel; do
    obj="$cfgdir/$rel"
    [[ -f "$obj" ]] || { SCAN_DETAIL="object missing: $obj"; return 1; }
    count=$((count + 1))
    "$OBJDUMP" -d --no-show-raw-insn "$obj" >"$listing" 2>&1 || { SCAN_DETAIL="cannot disassemble $obj"; return 1; }
    mnemonics_of "$listing" >>"$work/scan-mnemonics.txt"
    if mnemonics_of "$listing" | grep -Eq "$bad_re"; then
      fused+=" $rel:$(mnemonics_of "$listing" | grep -E "$bad_re" | sort -u | paste -sd, -)"
    fi
  done <"$manifest"
  ((count > 0)) || { SCAN_DETAIL="no object files listed in $manifest"; return 1; }
  [[ -z "$fused" ]] || { SCAN_DETAIL="fused instruction(s) in our own code:$fused"; return 1; }
  SCAN_DETAIL="$count objects, $(wc -l <"$work/scan-mnemonics.txt") instructions, none fused"
}

# check_fma <config> <arch> <config build dir>: sets FMA_DETAIL; returns 1 on failure
check_fma() {
  local dir rc=0
  dir="$(mktemp -d "$SWARM_NATIVE_BUILD_DIR/.fma.XXXXXX")"
  check_fma_in "$dir" "$@" || rc=$?
  rm -rf -- "$dir"
  return "$rc"
}

check_fma_in() {
  local dir=$1 cfg=$2 arch=$3 cfgdir=$4 obj ctrl bad_re m
  FMA_DETAIL=""
  OBJDUMP="$(objdump_for "$arch")"
  obj="$cfgdir/$LIB_OBJ_DIR/fp_probe.os"
  [[ -f "$obj" ]] || { FMA_DETAIL="probe object not found: $obj"; return 1; }
  bad_re="$(fused_regex "$arch")"
  disassemble_probe "$obj" "$dir/probe.txt" || { FMA_DETAIL="cannot disassemble $PROBE_SYMBOL from $obj"; return 1; }
  m="$(mnemonics_of "$dir/probe.txt" | paste -sd' ' -)"
  if mnemonics_of "$dir/probe.txt" | grep -Eq "$bad_re"; then
    FMA_DETAIL="FUSED instruction in $PROBE_SYMBOL: $(mnemonics_of "$dir/probe.txt" | grep -E "$bad_re" | paste -sd' ' -)"
    save_evidence "fma-$cfg.txt" "$dir/probe.txt"
    return 1
  fi
  has_plain_ops "$arch" "$m" || { FMA_DETAIL="no separate multiply and add found in: $m"; return 1; }
  # Positive control: with fusing allowed the same source must produce a fused instruction.
  ctrl="$dir/control.o"
  if ! compile_probe_control "$arch" "$ctrl" 2>"$dir/control.err"; then
    FMA_DETAIL="could not compile the control: $(head -n 3 "$dir/control.err" | paste -sd' ' -)"
    return 1
  fi
  disassemble_probe "$ctrl" "$dir/control.txt" || { FMA_DETAIL="cannot disassemble the control object"; return 1; }
  if ! mnemonics_of "$dir/control.txt" | grep -Eq "$bad_re"; then
    FMA_DETAIL="control with -ffp-contract=fast shows no fused instruction ($(mnemonics_of "$dir/control.txt" | paste -sd' ' -)): the check proves nothing"
    return 1
  fi
  scan_own_objects "$arch" "$cfgdir" "$dir" || { FMA_DETAIL="$SCAN_DETAIL"; return 1; }
  FMA_DETAIL="probe body: $m; control (-ffp-contract=fast): $(mnemonics_of "$dir/control.txt" | paste -sd' ' -); own code: $SCAN_DETAIL"
  {
    printf '# %s: disassembly of %s from the build (object %s), by %s (%s)\n' "$cfg" "$PROBE_SYMBOL" "${obj#"$SWARM_CACHE_DIR"/}" \
      "$OBJDUMP" "$("$OBJDUMP" --version | sed -n 's/^ *\(.*LLVM version [0-9][0-9.]*\).*$/\1/p' | head -n 1)"
    cat "$dir/probe.txt"
    printf '\n# %s: the same source compiled with -ffp-contract=fast (control; must contain a fused instruction)\n' "$cfg"
    cat "$dir/control.txt"
    printf '\n# %s: all objects of native/src (any depth) scanned for fused instructions: %s\n' "$cfg" "$SCAN_DETAIL"
  } >"$dir/evidence.txt"
  save_evidence "fma-$cfg.txt" "$dir/evidence.txt"
}

save_evidence() { # save_evidence <name> <file>
  [[ -z "$EVIDENCE_DIR" ]] || cp -- "$2" "$EVIDENCE_DIR/$1"
}

# check_library <config> <platform> <arch> <library>: sets LIB_DETAIL; returns 1 on failure
check_library() {
  local cfg=$1 platform=$2 arch=$3 lib=$4 header elf_class machine want_class want_machine aligns align needed bad_needed leaks path
  LIB_DETAIL=""
  [[ -s "$lib" ]] || { LIB_DETAIL="library not produced: $lib"; return 1; }
  header="$(readelf -hW "$lib")"
  elf_class="$(sed -n 's/^ *Class: *//p' <<<"$header")"
  machine="$(sed -n 's/^ *Machine: *//p' <<<"$header")"
  case "$arch" in
    x86_64) want_class="ELF64"; want_machine="Advanced Micro Devices X86-64" ;;
    arm64) want_class="ELF64"; want_machine="AArch64" ;;
    arm32) want_class="ELF32"; want_machine="ARM" ;;
  esac
  [[ "$elf_class" == "$want_class" && "$machine" == "$want_machine" ]] \
    || { LIB_DETAIL="wrong ELF: $elf_class $machine, expected $want_class $want_machine"; return 1; }
  readelf --dyn-syms -W "$lib" | awk -v s="$ENTRY_SYMBOL" '$NF == s && $7 != "UND" { found = 1 } END { exit !found }' \
    || { LIB_DETAIL="entry symbol $ENTRY_SYMBOL is not exported"; return 1; }
  aligns="$(readelf -lW "$lib" | awk '$1 == "LOAD" { print $NF }' | sort -u | paste -sd, -)"
  if [[ "$platform" == android && "$arch" == arm64 ]]; then
    for align in ${aligns//,/ }; do # hex such as 0x4000; bash arithmetic reads it
      ((align >= 16384)) || { LIB_DETAIL="LOAD segment alignment $align is below 0x4000 (16 KiB pages)"; return 1; }
    done
  fi
  needed="$(readelf -dW "$lib" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort | paste -sd' ' -)"
  if [[ "$platform" == android ]]; then
    bad_needed="$(tr ' ' '\n' <<<"$needed" | grep -Ev '^(libc\.so|libm\.so|libdl\.so|liblog\.so)$' || true)"
    [[ -z "$bad_needed" ]] || { LIB_DETAIL="unexpected shared dependency: $(paste -sd' ' - <<<"$bad_needed")"; return 1; }
  fi
  # No path of this machine in the binary: assert/error messages carry __FILE__, and the objects carry the source
  # directory (native/SConstruct maps godot-cpp's checkout, the build directory and native/ to short names).
  leaks=""
  for path in "$SWARM_CACHE_DIR" "$SWARM_NATIVE_BUILD_DIR" "$GODOT_CPP_DIR" "$ANDROID_NDK_ROOT" "$REPO_ROOT" "$HOME"; do
    ((${#path} >= 5)) || continue
    if grep -aqF -- "$path" "$lib"; then leaks+=" $path"; fi
  done
  [[ -z "$leaks" ]] || { LIB_DETAIL="the library embeds path(s) of this machine:$leaks"; return 1; }
  LIB_DETAIL="$elf_class $machine, LOAD align $aligns, needs: ${needed:-nothing}, no build paths embedded"
  {
    printf '# %s: %s\n' "$cfg" "$(basename -- "$lib")"
    readelf -hW "$lib"
    readelf -lW "$lib" | awk '$1 == "LOAD" || $1 == "Type" { print }'
    readelf -dW "$lib" | grep -E '\((NEEDED|SONAME)\)' || true
  } >"$SWARM_NATIVE_BUILD_DIR/.readelf.tmp"
  save_evidence "readelf-$cfg.txt" "$SWARM_NATIVE_BUILD_DIR/.readelf.tmp"
  rm -f -- "$SWARM_NATIVE_BUILD_DIR/.readelf.tmp"
}

# ---- Build ----------------------------------------------------------------------------------------
build_config() {
  local platform=$1 target=$2 arch=$3 cfg lib scons_log started compiled rc=0 secs
  cfg="$platform.$target.$arch"
  lib="$OUT_DIR/$LIB_PREFIX.$cfg.so"
  scons_log="$SWARM_NATIVE_BUILD_DIR/logs/$cfg.log"
  if ((CLEAN)); then
    log "$cfg: cleaning"
    rm -rf -- "${SWARM_NATIVE_BUILD_DIR:?}/$cfg"
    rm -f -- "$lib"
  fi
  log "$cfg: scons (-j$JOBS) ..."
  started=$SECONDS
  local scons_args=(-C "$NATIVE_DIR" -j"$JOBS" "platform=$platform" "target=$target" "arch=$arch" "out_dir=$OUT_DIR")
  if ((VERBOSE)); then
    swarm_scons "${scons_args[@]}" 2>&1 | tee "$scons_log" || rc=${PIPESTATUS[0]}
  else
    swarm_scons "${scons_args[@]}" >"$scons_log" 2>&1 || rc=$?
  fi
  secs=$((SECONDS - started))
  if ((rc != 0)); then
    ((VERBOSE)) || tail -n 60 "$scons_log" | sed 's/^/    /' >&2
    record FAIL "$cfg" "scons exited with code $rc after ${secs}s (full log: $scons_log)"
    save_evidence "scons-$cfg.log" "$scons_log"
    return 0
  fi
  compiled="$(grep -c '^Compiling' "$scons_log" || true)"
  save_evidence "scons-$cfg.log" "$scons_log"
  log "$cfg: built in ${secs}s ($compiled file(s) compiled)"

  if ! check_library "$cfg" "$platform" "$arch" "$lib"; then
    record FAIL "$cfg" "$LIB_DETAIL"
    return 0
  fi
  local lib_detail="$LIB_DETAIL"
  save_evidence "flag-guard-$cfg.txt" "$SWARM_NATIVE_BUILD_DIR/$cfg/flag-guard.txt"
  if ! check_fma "$cfg" "$arch" "$SWARM_NATIVE_BUILD_DIR/$cfg"; then
    record FAIL "$cfg" "$FMA_DETAIL"
    return 0
  fi
  record PASS "$cfg" "$(stat -c %s -- "$lib") bytes; $lib_detail; no FMA in $PROBE_SYMBOL or the rest of native/src"
  if [[ -n "$EVIDENCE_DIR" ]]; then printf '%s\n' "$FMA_DETAIL" >"$EVIDENCE_DIR/fma-$cfg.summary.txt"; fi
}

for entry in "${CONFIGS[@]}"; do
  # shellcheck disable=SC2086 # three words by construction
  build_config $entry
done

echo
echo "================ native build summary ================"
{
  printf 'libswarm_native: godot-cpp %s, api_version %s, NDK %s, scons %s\n' \
    "${SWARM_GODOT_CPP_COMMIT:0:12}" "$SWARM_GODOT_API_VERSION" "$SWARM_NDK_VERSION" "$SWARM_SCONS_VERSION"
  printf '%s\n' "${RESULT_LINES[@]}"
  echo
  echo "libraries in $OUT_DIR:"
  (cd -- "$OUT_DIR" && ls -l --time-style=+ "$LIB_PREFIX".*.so 2>/dev/null | awk '{ printf "  %10d  %s\n", $5, $NF }') || true
  if ((FAILURES == 0)); then echo "RESULT: PASS"; else printf 'RESULT: FAIL (%d configuration(s) failed)\n' "$FAILURES"; fi
} >"$SWARM_NATIVE_BUILD_DIR/.summary.tmp"
cat "$SWARM_NATIVE_BUILD_DIR/.summary.tmp"
if [[ -n "$EVIDENCE_DIR" ]]; then cp -- "$SWARM_NATIVE_BUILD_DIR/.summary.tmp" "$EVIDENCE_DIR/summary.txt"; fi
rm -f -- "$SWARM_NATIVE_BUILD_DIR/.summary.tmp"
((FAILURES == 0))
