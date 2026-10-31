#!/usr/bin/env bash
# Installs the pinned toolchain for the Godot port into the cache dir (never into the repo):
#   - Godot 4.7.2 editor, in self-contained mode (editor data lives next to the binary)
#   - the Android export templates only
#   - Android SDK pieces needed by the non-Gradle APK export: build-tools (apksigner, zipalign)
#     and platform-tools (adb; Godot's export validation refuses to run without it)
#   - a throwaway DEBUG keystore, and the editor settings that tie everything together
# Idempotent: every run re-verifies the downloads and the installed files against pinned hashes.
# Cache dir: $SWARM_CACHE_DIR (default ~/.cache/elemental-swarm-engine); it may not be inside the repo.
# Godot and adb are run with HOME, TMPDIR and XDG_DATA_HOME inside the cache dir (swarm_confined in
# lib/toolchain.sh), so nothing is written elsewhere, not even ~/.android or /tmp/adb.<uid>.log.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
USER_JAVA_HOME="${JAVA_HOME:-}"   # taken before toolchain.sh replaces it with the recorded value
SWARM_TOOLCHAIN_SKIP_CHECK=1
# shellcheck source=lib/toolchain.sh
source "$SCRIPT_DIR/lib/toolchain.sh" || exit 1
SETUP_LOG_TAG="setup"   # assigned, not defaulted: a SETUP_LOG_TAG in the user's environment must not leak into the log
# shellcheck source=lib/setup_common.sh
source "$SCRIPT_DIR/lib/setup_common.sh" || exit 1   # log, die, take_setup_lock, fetch_verified, stamps, staging

# ---- Pinned downloads ---------------------------------------------------------------------------
# Godot: the two SHA-512 values are the ones in the release's official SHA512-SUMS.txt.
GODOT_RELEASE_URL="https://github.com/godotengine/godot/releases/download/4.7.2-stable"
GODOT_ZIP="Godot_v4.7.2-stable_linux.x86_64.zip"
GODOT_ZIP_SIZE=77860424
GODOT_ZIP_SHA512="9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65"
TEMPLATES_TPZ="Godot_v4.7.2-stable_export_templates.tpz"
TEMPLATES_TPZ_SIZE=1281349702
TEMPLATES_TPZ_SHA512="ca4d71c4d7b81dfc15d1a98baa07534aa95b03fdda78a0075b06672e1648d2e5f40980c9adc28d23e1b92e732ee7bf3461997aa804af74ec2fcd7a93ccb84079"

# Android SDK (dl.google.com). SHA-1 values are the ones published in repository2-3.xml;
# build-tools SHA-256 is the one fg.4's build_apk.py already pins; platform-tools SHA-256 was
# computed from the download after the SHA-1 matched, then pinned here.
SDK_URL_BASE="https://dl.google.com/android/repository"
BUILD_TOOLS_ZIP="build-tools_r36_linux.zip"       # revision 36.0.0, unpacks to android-16/
BUILD_TOOLS_ZIP_SIZE=63737259
BUILD_TOOLS_ZIP_SHA1="b0b6376977657e8ad9b969bacf4093601da2c6fb"
BUILD_TOOLS_ZIP_SHA256="5d9ac77fb6ff43d9da518a337b4fcf8f9097113df531d99ccefe80ef7ce8250b"
PLATFORM_TOOLS_ZIP="platform-tools_r37.0.1-linux.zip"
PLATFORM_TOOLS_ZIP_SIZE=9054187
PLATFORM_TOOLS_ZIP_SHA1="477254aa5f903c15cf51001717bdf347fb6b53e0"
PLATFORM_TOOLS_ZIP_SHA256="d230f13842f60f782a8645f9c813f8f845bf36089ea7289f28c48f17979313f1"
# Not downloaded: platform-36_r02 (SHA-256 37607369a28c5b640b3a7998868d45898ebcb777565a0e85f9acf36f29631d2e).
# Godot 4.7.2's non-Gradle export never looks in platforms/, so it is not needed here.

# Template files kept from the .tpz (everything else in it targets other platforms).
ANDROID_TEMPLATE_FILES=(android_debug.apk android_release.apk android_source.zip version.txt)

DEBUG_KEY_ALIAS="androiddebugkey"
DEBUG_KEY_PASS="android"   # Android's public debug-keystore convention; not a secret

# ---- Usage --------------------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: tools/setup_godot.sh

Downloads and installs the pinned Godot ${SWARM_GODOT_VERSION} toolchain under:
  ${SWARM_CACHE_DIR}
Override the location with SWARM_CACHE_DIR. Safe to re-run; it re-verifies every file.
Scripts then use:  source tools/lib/toolchain.sh   (exports GODOT_BIN, ANDROID_SDK_ROOT, ...)
EOF
}

# ---- Steps --------------------------------------------------------------------------------------
preflight() {
  [[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] || die "Linux x86_64 only (got $(uname -s) $(uname -m))"
  local c
  for c in curl unzip sha1sum sha256sum sha512sum awk find xargs sort mktemp stat readlink flock; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
  mkdir -p "$SWARM_CACHE_DIR" "$SWARM_DOWNLOAD_DIR"
  take_setup_lock
}

resolve_java() {
  local home="$USER_JAVA_HOME" j spec major
  if [[ -z "$home" ]]; then
    j="$(command -v java || true)"
    [[ -n "$j" ]] || die "java not found; install a JDK 17+ or export JAVA_HOME"
    home="$(dirname "$(dirname "$(readlink -f -- "$j")")")"
  fi
  [[ -x "$home/bin/java" && -x "$home/bin/keytool" ]] || die "JDK needs bin/java and bin/keytool: $home"
  spec="$("$home/bin/java" -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java\.specification\.version = //p' | head -n 1)"
  major="${spec#1.}"
  major="${major%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] && ((major >= 17)) || die "JDK 17+ required (found '${spec:-unknown}' in $home)"
  JAVA_HOME="$home"
  log "JDK: $JAVA_HOME (Java $spec)"
}

download_all() {
  fetch_verified "$GODOT_ZIP" "$GODOT_RELEASE_URL/$GODOT_ZIP" "$GODOT_ZIP_SIZE" "sha512:$GODOT_ZIP_SHA512"
  fetch_verified "$TEMPLATES_TPZ" "$GODOT_RELEASE_URL/$TEMPLATES_TPZ" "$TEMPLATES_TPZ_SIZE" "sha512:$TEMPLATES_TPZ_SHA512"
  fetch_verified "$BUILD_TOOLS_ZIP" "$SDK_URL_BASE/$BUILD_TOOLS_ZIP" "$BUILD_TOOLS_ZIP_SIZE" \
    "sha256:$BUILD_TOOLS_ZIP_SHA256" "sha1:$BUILD_TOOLS_ZIP_SHA1"
  fetch_verified "$PLATFORM_TOOLS_ZIP" "$SDK_URL_BASE/$PLATFORM_TOOLS_ZIP" "$PLATFORM_TOOLS_ZIP_SIZE" \
    "sha256:$PLATFORM_TOOLS_ZIP_SHA256" "sha1:$PLATFORM_TOOLS_ZIP_SHA1"
}

install_editor() {
  local zip="$SWARM_DOWNLOAD_DIR/$GODOT_ZIP"
  mkdir -p "$SWARM_GODOT_DIR"
  if [[ -x "$GODOT_BIN" ]] && stamp_ok "$SWARM_GODOT_DIR" .editor.sha256; then
    log "OK (editor binary unchanged): $GODOT_BIN"
  else
    log "extracting the editor binary"
    make_staging
    assert_safe_zip "$zip"
    unzip -q -o "$zip" -d "$STAGING"
    [[ -f "$STAGING/$SWARM_GODOT_BIN_NAME" ]] || die "$SWARM_GODOT_BIN_NAME not found in $GODOT_ZIP"
    chmod 0755 "$STAGING/$SWARM_GODOT_BIN_NAME"
    mv -f -- "$STAGING/$SWARM_GODOT_BIN_NAME" "$GODOT_BIN"
    stamp_write "$SWARM_GODOT_DIR" .editor.sha256 "$SWARM_GODOT_BIN_NAME"
  fi
  # Self-contained mode: this marker next to the binary moves editor data to ./editor_data/.
  [[ -f "$SWARM_GODOT_DIR/_sc_" ]] || : >"$SWARM_GODOT_DIR/_sc_"
}

install_templates() {
  local tpz="$SWARM_DOWNLOAD_DIR/$TEMPLATES_TPZ" f
  mkdir -p "$SWARM_TEMPLATES_DIR"
  if stamp_ok "$SWARM_TEMPLATES_DIR" .templates.sha256 all; then
    log "OK (Android export templates unchanged): $SWARM_TEMPLATES_DIR"
    return 0
  fi
  log "extracting the Android export templates only"
  make_staging
  assert_safe_zip "$tpz"
  local entries=()
  for f in "${ANDROID_TEMPLATE_FILES[@]}"; do entries+=("templates/$f"); done
  unzip -q -o -j "$tpz" "${entries[@]}" -d "$STAGING"
  for f in "${ANDROID_TEMPLATE_FILES[@]}"; do
    [[ -s "$STAGING/$f" ]] || die "missing from $TEMPLATES_TPZ: templates/$f"
  done
  [[ "$(tr -d '\r\n' <"$STAGING/version.txt")" == "$SWARM_GODOT_TEMPLATE_VERSION" ]] \
    || die "template version.txt is not $SWARM_GODOT_TEMPLATE_VERSION"
  remove_cache_tree "$SWARM_TEMPLATES_DIR" # drops anything else that was in the directory
  mkdir -p "$SWARM_TEMPLATES_DIR"
  for f in "${ANDROID_TEMPLATE_FILES[@]}"; do mv -f -- "$STAGING/$f" "$SWARM_TEMPLATES_DIR/$f"; done
  stamp_write "$SWARM_TEMPLATES_DIR" .templates.sha256 "${ANDROID_TEMPLATE_FILES[@]}"
}

# install_sdk_tree ZIP TOPDIR DEST SENTINEL: unpack ZIP's TOPDIR to DEST, skip if unchanged
install_sdk_tree() {
  local zip="$SWARM_DOWNLOAD_DIR/$1" top=$2 dest=$3 sentinel=$4 stamp=.swarm-installed.sha256
  if [[ -x "$dest/$sentinel" ]] && stamp_ok "$dest" "$stamp" all; then
    log "OK (unchanged): $dest"
    return 0
  fi
  log "extracting $1 -> $dest"
  make_staging
  assert_safe_zip "$zip"
  unzip -q -o "$zip" -d "$STAGING"
  [[ -d "$STAGING/$top" ]] || die "$top/ not found in $1"
  if [[ "$top" == android-16 ]]; then   # build-tools: confirm the revision before naming the dir
    grep -qx "Pkg.Revision=$SWARM_BUILD_TOOLS_VERSION" "$STAGING/$top/source.properties" \
      || die "build-tools revision is not $SWARM_BUILD_TOOLS_VERSION"
  fi
  if [[ -e "$dest" ]]; then remove_cache_tree "$dest"; fi
  mkdir -p "$(dirname "$dest")"
  mv -- "$STAGING/$top" "$dest"
  chmod +x "$dest/$sentinel"
  stamp_write "$dest" "$stamp"
}

# Godot picks the apksigner from the build-tools directory it finds, so no other version may be there.
prune_unknown_build_tools() {
  local root="$ANDROID_SDK_ROOT/build-tools" entry
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' entry; do
    log "removing unexpected entry in build-tools: $entry"
    remove_cache_tree "$entry"
  done < <(find "$root" -mindepth 1 -maxdepth 1 ! -name "$SWARM_BUILD_TOOLS_VERSION" -print0)
}

install_sdk() {
  prune_unknown_build_tools
  install_sdk_tree "$BUILD_TOOLS_ZIP" android-16 "$ANDROID_SDK_ROOT/build-tools/$SWARM_BUILD_TOOLS_VERSION" apksigner
  chmod +x "$SWARM_ZIPALIGN"
  install_sdk_tree "$PLATFORM_TOOLS_ZIP" platform-tools "$ANDROID_SDK_ROOT/platform-tools" adb
}

ensure_debug_keystore() {
  local ks="$SWARM_DEBUG_KEYSTORE" keytool="$JAVA_HOME/bin/keytool"
  mkdir -p "$(dirname "$ks")"
  chmod 0700 "$(dirname "$ks")"
  if [[ ! -f "$ks" ]]; then
    log "generating the throwaway debug keystore: $ks"
    "$keytool" -genkeypair -keystore "$ks" -storetype PKCS12 -storepass "$DEBUG_KEY_PASS" \
      -alias "$DEBUG_KEY_ALIAS" -keypass "$DEBUG_KEY_PASS" -keyalg RSA -keysize 2048 -validity 10000 \
      -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1 || die "keytool could not create $ks"
    chmod 0600 "$ks"
  fi
  "$keytool" -list -keystore "$ks" -storepass "$DEBUG_KEY_PASS" -alias "$DEBUG_KEY_ALIAS" >/dev/null 2>&1 \
    || die "debug keystore is unreadable or lacks alias $DEBUG_KEY_ALIAS; delete $ks and re-run"
  log "OK (debug keystore): $ks"
}

# Start the editor headless and quit again (creates/refreshes its settings file); 3 minutes at most.
godot_headless_quit() {
  (cd -- "$SWARM_CACHE_DIR" && export SWARM_CACHE_DIR GODOT_BIN && export -f swarm_confined swarm_godot &&
    timeout 180 bash -c 'swarm_godot --headless --quit' >/dev/null 2>&1)
}

tres_string() { # quote a value as a .tres string literal
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# set_editor_setting KEY TRES_LITERAL: replace the line if present, else append (still in [resource])
set_editor_setting() {
  local tmp
  tmp="$(mktemp "$SWARM_EDITOR_SETTINGS.XXXXXX")"
  KEY="$1" VAL="$2" awk '
    BEGIN { prefix = ENVIRON["KEY"] " = "; val = ENVIRON["VAL"] }
    index($0, prefix) == 1 { print prefix val; found = 1; next }
    { print }
    END { if (!found) print prefix val }
  ' "$SWARM_EDITOR_SETTINGS" >"$tmp"
  mv -f -- "$tmp" "$SWARM_EDITOR_SETTINGS"
}

configure_editor() {
  if [[ ! -f "$SWARM_EDITOR_SETTINGS" ]]; then
    log "starting the editor headless once so it creates its own settings file"
    godot_headless_quit || die "the editor did not start headless"
    [[ -f "$SWARM_EDITOR_SETTINGS" ]] \
      || die "expected $SWARM_EDITOR_SETTINGS; found: $(ls "$SWARM_EDITOR_DATA" 2>/dev/null | tr '\n' ' ')"
  fi
  set_editor_setting export/android/java_sdk_path "$(tres_string "$JAVA_HOME")"
  set_editor_setting export/android/android_sdk_path "$(tres_string "$ANDROID_SDK_ROOT")"
  set_editor_setting export/android/debug_keystore "$(tres_string "$SWARM_DEBUG_KEYSTORE")"
  set_editor_setting export/android/debug_keystore_user "$(tres_string "$DEBUG_KEY_ALIAS")"
  set_editor_setting export/android/debug_keystore_pass "$(tres_string "$DEBUG_KEY_PASS")"
  set_editor_setting network/connection/check_for_updates 0   # 0 = Disable Update Checks
  log "OK (editor settings): $SWARM_EDITOR_SETTINGS"
}

record_toolchain() {
  printf 'JAVA_HOME=%s\n' "$JAVA_HOME" >"$SWARM_TOOLCHAIN_ENV"
}

smoke_test() {
  local out k rc
  log "smoke test: Godot version"
  out="$(swarm_godot --version 2>&1)" || die "Godot does not run: $out"
  log "  $out"
  log "smoke test: headless start"
  godot_headless_quit || die "'$GODOT_BIN --headless --quit' failed"
  for k in export/android/java_sdk_path export/android/android_sdk_path export/android/debug_keystore; do
    grep -q "^$k = " "$SWARM_EDITOR_SETTINGS" || die "editor setting lost after a headless run: $k"
  done
  log "smoke test: apksigner / adb / zipalign"
  out="$(JAVA_HOME="$JAVA_HOME" "$SWARM_APKSIGNER" --version 2>/dev/null)" || die "apksigner does not run with $JAVA_HOME"
  log "  apksigner $out"
  out="$(swarm_confined "$SWARM_ADB" version 2>/dev/null | head -n 1)" || die "adb does not run"
  log "  $out"
  rc=0
  "$SWARM_ZIPALIGN" >/dev/null 2>&1 || rc=$?   # no arguments: prints usage and exits non-zero
  ((rc != 126 && rc != 127)) || die "zipalign cannot be executed (exit $rc)"
}

main() {
  case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 2 ;;
  esac
  preflight
  resolve_java
  download_all
  install_editor
  install_templates
  install_sdk
  ensure_debug_keystore
  record_toolchain
  configure_editor
  smoke_test
  log "done. In scripts: source tools/lib/toolchain.sh  (GODOT_BIN=$GODOT_BIN)"
}

main "$@"
