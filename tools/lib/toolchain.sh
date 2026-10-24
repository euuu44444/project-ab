# shellcheck shell=bash
# Locates the toolchain installed by tools/setup_godot.sh. Source it; do not execute it:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/toolchain.sh" || exit 1
#
# Exports on success:
#   SWARM_CACHE_DIR      cache root (default ~/.cache/elemental-swarm-engine, override by env)
#   GODOT_BIN            Godot editor binary (self-contained mode, editor data under the cache)
#   ANDROID_SDK_ROOT     Android SDK root (ANDROID_HOME is the same path)
#   JAVA_HOME            JDK recorded by setup (the one the editor settings point to)
#   SWARM_DEBUG_KEYSTORE throwaway debug keystore (alias androiddebugkey / password android)
# Also exported: SWARM_APKSIGNER, SWARM_ZIPALIGN, SWARM_ADB, SWARM_EDITOR_DATA, SWARM_TEMPLATES_DIR.
# Defines swarm_confined / swarm_godot: they run a command (Godot) with HOME, TMPDIR and XDG_DATA_HOME
# inside the cache, so that user:// data, ~/.android (adb keys) and adb's /tmp log never land in the
# real home directory. adb is moved to a private server port (SWARM_ADB_PORT, default 5199): Godot
# kills the adb server it used when it exits, which must never be a developer's own server on 5037.
#
# This file does not change the caller's shell options (no set -e/-u). It returns 1 when setup is
# incomplete, so scripts under set -e stop at the source line.
# tools/setup_godot.sh sets SWARM_TOOLCHAIN_SKIP_CHECK=1 to reuse the path definitions only.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "tools/lib/toolchain.sh must be sourced, not executed." >&2
  exit 2
fi

# Version constants shared with setup_godot.sh (hash pins live in setup_godot.sh).
SWARM_GODOT_VERSION="4.7.2-stable"
SWARM_GODOT_TEMPLATE_VERSION="4.7.2.stable"     # export_templates/<this>/, templates/version.txt
SWARM_GODOT_SETTINGS_NAME="editor_settings-4.7.tres"
SWARM_BUILD_TOOLS_VERSION="36.0.0"

SWARM_CACHE_DIR="$(readlink -m -- "${SWARM_CACHE_DIR:-$HOME/.cache/elemental-swarm-engine}")"
# Downloads, Godot binaries and keystores must never end up in the repository (or be scanned by the
# Godot project), so the cache dir may not be inside the checkout this file belongs to.
_swarm_repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
case "$SWARM_CACHE_DIR/" in
  "$_swarm_repo_root"/*)
    echo "SWARM_CACHE_DIR must be outside the repository ($_swarm_repo_root): $SWARM_CACHE_DIR" >&2
    unset _swarm_repo_root
    return 1
    ;;
esac
unset _swarm_repo_root
SWARM_DOWNLOAD_DIR="$SWARM_CACHE_DIR/downloads"
SWARM_GODOT_DIR="$SWARM_CACHE_DIR/godot/$SWARM_GODOT_VERSION"
SWARM_GODOT_BIN_NAME="Godot_v${SWARM_GODOT_VERSION}_linux.x86_64"
SWARM_EDITOR_DATA="$SWARM_GODOT_DIR/editor_data"
SWARM_EDITOR_SETTINGS="$SWARM_EDITOR_DATA/$SWARM_GODOT_SETTINGS_NAME"
SWARM_TEMPLATES_DIR="$SWARM_EDITOR_DATA/export_templates/$SWARM_GODOT_TEMPLATE_VERSION"
SWARM_TOOLCHAIN_ENV="$SWARM_CACHE_DIR/toolchain.env"

GODOT_BIN="$SWARM_GODOT_DIR/$SWARM_GODOT_BIN_NAME"
ANDROID_SDK_ROOT="$SWARM_CACHE_DIR/android-sdk"
ANDROID_HOME="$ANDROID_SDK_ROOT"
SWARM_DEBUG_KEYSTORE="$SWARM_CACHE_DIR/keystore/debug.keystore"
SWARM_ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
SWARM_APKSIGNER="$ANDROID_SDK_ROOT/build-tools/$SWARM_BUILD_TOOLS_VERSION/apksigner"
SWARM_ZIPALIGN="$ANDROID_SDK_ROOT/build-tools/$SWARM_BUILD_TOOLS_VERSION/zipalign"

# JAVA_HOME is whatever setup recorded, so the editor settings and the scripts agree.
# Before setup has run, fall back to the caller's JAVA_HOME (empty is fine).
if [[ -f "$SWARM_TOOLCHAIN_ENV" ]]; then
  JAVA_HOME="$(sed -n 's/^JAVA_HOME=//p' "$SWARM_TOOLCHAIN_ENV" | head -n 1)"
fi
JAVA_HOME="${JAVA_HOME:-}"

# Run a command with HOME, TMPDIR and XDG_DATA_HOME confined to the cache and adb on a private port.
swarm_confined() {
  local home="$SWARM_CACHE_DIR/home"
  mkdir -p -- "$home/tmp"
  HOME="$home" TMPDIR="$home/tmp" XDG_DATA_HOME="$SWARM_CACHE_DIR/xdg-data" \
    ANDROID_ADB_SERVER_PORT="${SWARM_ADB_PORT:-5199}" "$@"
}

swarm_godot() {
  swarm_confined "$GODOT_BIN" "$@"
}

_swarm_toolchain_problems() {
  local problems=() key
  [[ -x "$GODOT_BIN" ]] || problems+=("Godot editor missing or not executable: $GODOT_BIN")
  [[ -f "$SWARM_GODOT_DIR/_sc_" ]] || problems+=("self-contained marker missing: $SWARM_GODOT_DIR/_sc_")
  local t
  for t in android_debug.apk android_release.apk android_source.zip version.txt; do
    [[ -f "$SWARM_TEMPLATES_DIR/$t" ]] || problems+=("export template missing: $SWARM_TEMPLATES_DIR/$t")
  done
  [[ -x "$SWARM_ADB" ]] || problems+=("adb missing: $SWARM_ADB")
  [[ -x "$SWARM_APKSIGNER" ]] || problems+=("apksigner missing: $SWARM_APKSIGNER")
  [[ -x "$SWARM_ZIPALIGN" ]] || problems+=("zipalign missing: $SWARM_ZIPALIGN")
  [[ -f "$SWARM_DEBUG_KEYSTORE" ]] || problems+=("debug keystore missing: $SWARM_DEBUG_KEYSTORE")
  if [[ -z "$JAVA_HOME" || ! -x "$JAVA_HOME/bin/java" || ! -x "$JAVA_HOME/bin/keytool" ]]; then
    problems+=("JDK not recorded or unusable (JAVA_HOME='${JAVA_HOME}'; see $SWARM_TOOLCHAIN_ENV)")
  fi
  if [[ -f "$SWARM_EDITOR_SETTINGS" ]]; then
    for key in export/android/android_sdk_path export/android/java_sdk_path export/android/debug_keystore; do
      grep -q "^$key = " "$SWARM_EDITOR_SETTINGS" || problems+=("editor setting not configured: $key")
    done
  else
    problems+=("editor settings missing: $SWARM_EDITOR_SETTINGS")
  fi
  ((${#problems[@]} == 0)) || printf '%s\n' "${problems[@]}"
}

if [[ "${SWARM_TOOLCHAIN_SKIP_CHECK:-0}" != "1" ]]; then
  _swarm_problems="$(_swarm_toolchain_problems)"
  if [[ -n "$_swarm_problems" ]]; then
    echo "The Godot toolchain is not set up (cache: $SWARM_CACHE_DIR):" >&2
    while IFS= read -r _swarm_line; do
      printf '  - %s\n' "$_swarm_line" >&2
    done <<<"$_swarm_problems"
    echo "Run tools/setup_godot.sh first (it is idempotent and re-verifies every download)." >&2
    unset _swarm_problems _swarm_line
    return 1
  fi
  unset _swarm_problems
  export SWARM_CACHE_DIR GODOT_BIN ANDROID_SDK_ROOT ANDROID_HOME JAVA_HOME SWARM_DEBUG_KEYSTORE
  export SWARM_ADB SWARM_APKSIGNER SWARM_ZIPALIGN SWARM_EDITOR_DATA SWARM_TEMPLATES_DIR
  export -f swarm_confined swarm_godot # so that `timeout bash -c 'swarm_godot ...'` finds them
fi
