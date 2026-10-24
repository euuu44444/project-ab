# shellcheck shell=bash
# Locates the C++ (GDExtension) toolchain installed by tools/setup_cpp.sh, on top of the Godot
# toolchain from lib/toolchain.sh (which this file sources first). Source it; do not execute it:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/cpp_toolchain.sh" || exit 1
#
# Exports on success (in addition to everything lib/toolchain.sh exports):
#   ANDROID_NDK_ROOT       Android NDK r28b (28.1.13356709), in the standard side-by-side SDK layout
#                          ($ANDROID_SDK_ROOT/ndk/28.1.13356709), so godot-cpp finds it either way
#   SCONS                  scons from a Python venv in the cache (version and wheel hash pinned)
#   GODOT_CPP_DIR          godot-cpp checkout at the pinned commit (never built in; objects go elsewhere)
#   SWARM_GODOT_CPP_COMMIT the pinned godot-cpp commit
#   SWARM_GODOT_API_VERSION  godot-cpp api_version to build against ("4.7")
#   SWARM_GODOT_API_JSON   extension_api.json dumped from the pinned Godot (reference for api checks)
#   SWARM_NATIVE_BUILD_DIR object files and intermediate libraries (outside the repo)
#   SWARM_NDK_VERSION, SWARM_SCONS_VERSION, SWARM_NDK_BIN (the NDK's llvm bin dir)
# Defines swarm_scons: runs scons with a confined environment (no bytecode files next to the sources,
# no user site-packages, HOME and TMPDIR inside the cache, and none of the environment variables that
# change what scons builds: SCONSFLAGS, SCONS_CACHE, SCONS_LIB_DIR, PYTHONPATH, PYTHONHOME, PYTHONSTARTUP).
# Defines swarm_godot_cpp_clean DIR: HEAD is the pinned commit and the work tree has no modified,
# untracked or ignored file.
#
# Host-only mode: set SWARM_CPP_HOST_ONLY=1 BEFORE sourcing this file when only the Linux host build is
# needed (the headless tests). The Android NDK (2.2 GB) is then not required and not checked; scons, the
# pinned godot-cpp checkout, the API dump and a host clang/llvm-objdump still are. Without the variable
# everything is required (tools/build_android.sh).
#
# This file does not change the caller's shell options. It returns 1 when setup is incomplete, so
# scripts under set -e stop at the source line. tools/setup_cpp.sh sets SWARM_CPP_TOOLCHAIN_SKIP_CHECK=1
# to reuse the path definitions only (the Godot toolchain itself is still required).

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "tools/lib/cpp_toolchain.sh must be sourced, not executed." >&2
  exit 2
fi

_swarm_cpp_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=toolchain.sh
source "$_swarm_cpp_lib_dir/toolchain.sh" || return 1
unset _swarm_cpp_lib_dir

# Version constants shared with setup_cpp.sh (size and hash pins live in setup_cpp.sh).
SWARM_NDK_RELEASE="r28b"
SWARM_NDK_VERSION="28.1.13356709"                 # Pkg.Revision of r28b; the version the Godot 4.7 docs name
SWARM_GODOT_CPP_REPO="https://github.com/godotengine/godot-cpp"
SWARM_GODOT_CPP_COMMIT="8070599885b6df675fcad033dd032ce44be2b850"   # master, 2026-10-22 (godot-cpp v10 line)
SWARM_GODOT_API_VERSION="4.7"                     # godot-cpp api_version; checked against Godot 4.7.2's own dump
SWARM_SCONS_VERSION="4.10.1"

ANDROID_NDK_ROOT="$ANDROID_SDK_ROOT/ndk/$SWARM_NDK_VERSION"
SWARM_NDK_BIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"
SWARM_CPP_VENV="$SWARM_CACHE_DIR/venv-scons"
SCONS="$SWARM_CPP_VENV/bin/scons"
GODOT_CPP_DIR="$SWARM_CACHE_DIR/godot-cpp/$SWARM_GODOT_CPP_COMMIT"
SWARM_GODOT_API_DIR="$SWARM_CACHE_DIR/godot-api/$SWARM_GODOT_VERSION"
SWARM_GODOT_API_JSON="$SWARM_GODOT_API_DIR/extension_api.json"
SWARM_NATIVE_BUILD_DIR="$SWARM_CACHE_DIR/native-build"
SWARM_CPP_TOOLCHAIN_ENV="$SWARM_CACHE_DIR/cpp-toolchain.env"   # facts recorded by setup_cpp.sh

# Run scons from the venv. Nothing may be written next to the sources (godot-cpp checkout, repo):
# no .pyc files, no user site-packages; HOME and TMPDIR are inside the cache like for Godot. The variables
# in the -u list are removed from the environment: SCONSFLAGS (can carry build options such as lto=full)
# and SCONS_CACHE (godot-cpp turns it into a shared build cache) would change the build behind the back
# of native/SConstruct, SCONS_LIB_DIR and PYTHON{PATH,HOME,STARTUP} would change the code that runs.
swarm_scons() {
  local home="$SWARM_CACHE_DIR/home"
  mkdir -p -- "$home/tmp"
  env -u SCONSFLAGS -u SCONS_CACHE -u SCONS_LIB_DIR -u PYTHONPATH -u PYTHONHOME -u PYTHONSTARTUP \
    HOME="$home" TMPDIR="$home/tmp" PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 "$SCONS" "$@"
}

# godot-cpp's git status, as `git status --porcelain` lines (empty = clean): modified, untracked AND ignored
# files all count (an untracked custom.py would be executed by godot-cpp's SConstruct). --no-optional-locks:
# the check does not write to the checkout.
_swarm_godot_cpp_status() {
  git -C "$1" --no-optional-locks status --porcelain --untracked-files=all --ignored 2>&1
}

# swarm_godot_cpp_clean DIR: HEAD is the pinned commit and the work tree is clean.
swarm_godot_cpp_clean() {
  [[ -d "$1/.git" ]] || return 1
  [[ "$(git -C "$1" rev-parse HEAD 2>/dev/null)" == "$SWARM_GODOT_CPP_COMMIT" ]] || return 1
  [[ -z "$(_swarm_godot_cpp_status "$1")" ]]
}

# swarm_find_host_objdump: path of the host's llvm-objdump (unversioned name first, then the highest
# llvm-objdump-N); prints nothing when there is none.
swarm_find_host_objdump() {
  local found
  found="$(command -v llvm-objdump 2>/dev/null || true)"
  if [[ -z "$found" ]]; then
    found="$(compgen -c llvm-objdump- 2>/dev/null | grep -E '^llvm-objdump-[0-9]+$' | sort -t- -k3 -n | tail -n 1 || true)"
    [[ -z "$found" ]] || found="$(command -v "$found")"
  fi
  printf '%s' "$found"
}

_swarm_cpp_problems() {
  local problems=() rev dist dirty
  if [[ "${SWARM_CPP_HOST_ONLY:-0}" == "1" ]]; then
    # Host-only: the NDK is not needed, but the host must be able to disassemble its own objects.
    [[ -n "$(swarm_find_host_objdump)" ]] || problems+=("llvm-objdump missing (host-only mode checks the x86-64 objects with it; Debian/Ubuntu: apt install llvm)")
  elif [[ ! -x "$SWARM_NDK_BIN/clang" ]]; then
    problems+=("Android NDK missing: $ANDROID_NDK_ROOT")
  elif ! grep -qx "Pkg.Revision *= *$SWARM_NDK_VERSION" "$ANDROID_NDK_ROOT/source.properties" 2>/dev/null; then
    problems+=("Android NDK is not revision $SWARM_NDK_VERSION: $ANDROID_NDK_ROOT")
  fi
  if [[ ! -x "$SCONS" ]]; then
    problems+=("scons missing: $SCONS")
  else
    dist="$(compgen -G "$SWARM_CPP_VENV/lib/python3*/site-packages/scons-$SWARM_SCONS_VERSION.dist-info" || true)"
    [[ -n "$dist" ]] || problems+=("scons $SWARM_SCONS_VERSION is not installed in $SWARM_CPP_VENV")
  fi
  if [[ ! -d "$GODOT_CPP_DIR/.git" ]]; then
    problems+=("godot-cpp checkout missing: $GODOT_CPP_DIR")
  else
    rev="$(git -C "$GODOT_CPP_DIR" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$rev" != "$SWARM_GODOT_CPP_COMMIT" ]]; then
      problems+=("godot-cpp is at '${rev:-?}', pinned commit is $SWARM_GODOT_CPP_COMMIT ($GODOT_CPP_DIR)")
    else
      dirty="$(_swarm_godot_cpp_status "$GODOT_CPP_DIR" | head -n 3 | paste -sd';' - || true)"
      [[ -z "$dirty" ]] || problems+=("godot-cpp has local changes ($dirty ...): $GODOT_CPP_DIR")
    fi
  fi
  [[ -s "$SWARM_GODOT_API_JSON" ]] || problems+=("Godot API dump missing: $SWARM_GODOT_API_JSON")
  grep -qx 'API_CHECK=identical' "$SWARM_CPP_TOOLCHAIN_ENV" 2>/dev/null \
    || problems+=("setup has not recorded a passing api_version=$SWARM_GODOT_API_VERSION check ($SWARM_CPP_TOOLCHAIN_ENV)")
  command -v clang >/dev/null 2>&1 && command -v clang++ >/dev/null 2>&1 \
    || problems+=("host compiler missing: clang and clang++ are needed for the linux build")
  ((${#problems[@]} == 0)) || printf '%s\n' "${problems[@]}"
}

if [[ "${SWARM_CPP_TOOLCHAIN_SKIP_CHECK:-0}" != "1" ]]; then
  _swarm_problems="$(_swarm_cpp_problems)"
  if [[ -n "$_swarm_problems" ]]; then
    echo "The C++ toolchain is not set up (cache: $SWARM_CACHE_DIR):" >&2
    while IFS= read -r _swarm_line; do
      printf '  - %s\n' "$_swarm_line" >&2
    done <<<"$_swarm_problems"
    if [[ "${SWARM_CPP_HOST_ONLY:-0}" == "1" ]]; then
      echo "Run tools/setup_cpp.sh --host-only first (it is idempotent and re-verifies every download)." >&2
    else
      echo "Run tools/setup_cpp.sh first (it is idempotent and re-verifies every download)." >&2
    fi
    unset _swarm_problems _swarm_line
    return 1
  fi
  unset _swarm_problems
  export ANDROID_NDK_ROOT SCONS GODOT_CPP_DIR SWARM_GODOT_CPP_COMMIT SWARM_GODOT_API_VERSION SWARM_GODOT_API_JSON
  export SWARM_NATIVE_BUILD_DIR SWARM_NDK_VERSION SWARM_SCONS_VERSION SWARM_NDK_BIN
  export -f swarm_scons
fi
