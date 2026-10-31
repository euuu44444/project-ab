#!/usr/bin/env bash
# Installs the pinned C++ (GDExtension) toolchain for the Godot port into the cache dir (never into
# the repo). It needs the Godot toolchain from tools/setup_godot.sh first.
#   - Android NDK r28b (28.1.13356709), the version the Godot 4.7 docs name, in the SDK's ndk/ layout
#     (2.2 GB; only the Android build needs it, so --host-only skips it)
#   - godot-cpp at a pinned master commit (v10 line, supports api_version=4.7), as a clean git checkout
#   - SCons in a Python venv, installed from a hash-pinned wheel (pip --require-hashes --no-compile, no
#     network for pip); every installed file, the entry script bin/scons included, is checked against the
#     wheel's RECORD and no compiled .pyc file may exist
#   - Godot 4.7.2's own extension API (--dump-extension-api), compared with godot-cpp's api_version file
#   - qemu-user (qemu-aarch64-static, qemu-arm-static) from a pinned Ubuntu package, to run the statically
#     linked arm64 / armv7 test programs on this host (skipped by --host-only, like the NDK)
# Idempotent: a re-run verifies every installed file against a stamp (and the godot-cpp checkout against
# its commit) and downloads nothing when everything is in place. Every download is checked against a
# pinned size and hash before it is extracted or installed.
# Cache dir: $SWARM_CACHE_DIR (default ~/.cache/elemental-swarm-engine); it may not be inside the repo.
#
# Usage: tools/setup_cpp.sh [--host-only] [--report]
#   --host-only  install only what the Linux host build and the headless tests (tools/run_godot_tests.sh)
#                need: no Android NDK, no qemu. tools/build_android.sh still needs the full setup (run without it).
#   --report     change nothing; print the pins and what is installed (used for the C1 evidence)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SWARM_CPP_TOOLCHAIN_SKIP_CHECK=1
# shellcheck source=lib/cpp_toolchain.sh
source "$SCRIPT_DIR/lib/cpp_toolchain.sh" || exit 1
SETUP_LOG_TAG="setup-cpp"
# shellcheck source=lib/setup_common.sh
source "$SCRIPT_DIR/lib/setup_common.sh"

# ---- Pinned downloads ---------------------------------------------------------------------------
# Android NDK r28b, linux. Size and SHA-1 are the ones Google publishes for package
# "ndk;28.1.13356709" in https://dl.google.com/android/repository/repository2-3.xml; the SHA-256 was
# computed from the download after the SHA-1 matched, then pinned here.
NDK_URL="https://dl.google.com/android/repository/android-ndk-${SWARM_NDK_RELEASE}-linux.zip"
NDK_ZIP="android-ndk-${SWARM_NDK_RELEASE}-linux.zip"
NDK_ZIP_SIZE=722264879
NDK_ZIP_SHA1="f574d3165405bd59ffc5edaadac02689075a729f"
NDK_ZIP_SHA256="e9f2759862cecfd48c20bbb7d8cfedbb020f4d91b5f78d9a2fc106f7db3c27ed"
NDK_TOP_DIR="android-ndk-${SWARM_NDK_RELEASE}"

# SCons: the pure-Python wheel from PyPI (content-addressed URL: the path holds the blake2b digest).
SCONS_WHEEL="scons-${SWARM_SCONS_VERSION}-py3-none-any.whl"
SCONS_WHEEL_URL="https://files.pythonhosted.org/packages/ce/bf/931fb9fbb87234c32b8b1b1c15fba23472a10777c12043336675633809a7/$SCONS_WHEEL"
SCONS_WHEEL_SIZE=4136069
SCONS_WHEEL_SHA256="bd9d1c52f908d874eba92a8c0c0a8dcf2ed9f3b88ab956d0fce1da479c4e7126"

# qemu-user-static 1:8.2.2+ds-0ubuntu1.18, amd64 (Ubuntu 24.04 noble-updates, universe). Size, SHA-256 and
# SHA-512 are the ones in dists/noble-updates/universe/binary-amd64/Packages.gz, whose hash is listed in
# dists/noble-updates/InRelease, signed by "Ubuntu Archive Automatic Signing Key (2018)" (checked with gpgv
# and /usr/share/keyrings/ubuntu-archive-keyring.gpg on 2026-10-25). The URL is Launchpad's librarian, which
# keeps every published file; archive.ubuntu.com drops a -updates package from its pool once it is superseded.
QEMU_DEB="qemu-user-static_${SWARM_QEMU_VERSION}_amd64.deb"
QEMU_DEB_URL="https://launchpadlibrarian.net/868126304/$QEMU_DEB"
QEMU_DEB_SIZE=14709858
QEMU_DEB_SHA256="5bb397f66063efa349f6fd5cb3b68cd96f29edd0994e4ba5115cf0859a716bf0"
QEMU_DEB_SHA512="c18a17c7651d344933deb327237576ba7d585d46201daa68586d6bb6dfbed662c203b278cf7d62e6e9cfcf5f2042a21fc37c9f473b914f97477dfb590fce82c6"
# The only members taken out of the package (regular files); the binfmt links and everything else stay in it.
QEMU_MEMBERS=(./usr/bin/qemu-aarch64-static ./usr/bin/qemu-arm-static ./usr/share/doc/qemu-user-static/copyright)

usage() { awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }
HOST_ONLY=0

# ---- Steps --------------------------------------------------------------------------------------
preflight() {
  [[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] || die "Linux x86_64 only (got $(uname -s) $(uname -m))"
  local c
  for c in curl unzip sha1sum sha256sum awk find xargs sort mktemp stat readlink flock git python3 clang clang++ readelf; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
  if ((HOST_ONLY)); then # the NDK's llvm-objdump is not there, so the host's checks the x86-64 objects
    [[ -n "$(swarm_find_host_objdump)" ]] || die "llvm-objdump not found (Debian/Ubuntu: apt install llvm)"
  else
    for c in dpkg-deb tar; do
      command -v "$c" >/dev/null 2>&1 || die "required command not found: $c (it unpacks the pinned qemu package)"
    done
  fi
  python3 -c 'import sys, venv, ensurepip; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null \
    || die "python3 (3.8+) with the venv and ensurepip modules is required (Debian/Ubuntu: apt install python3-venv)"
  mkdir -p "$SWARM_CACHE_DIR" "$SWARM_DOWNLOAD_DIR"
  take_setup_lock
}

install_ndk() {
  local dest="$ANDROID_NDK_ROOT" stamp=.swarm-installed.sha256
  if [[ -x "$SWARM_NDK_BIN/clang" ]] && stamp_ok "$dest" "$stamp" all; then
    log "OK (NDK unchanged): $dest"
    return 0
  fi
  fetch_verified "$NDK_ZIP" "$NDK_URL" "$NDK_ZIP_SIZE" "sha256:$NDK_ZIP_SHA256" "sha1:$NDK_ZIP_SHA1"
  local zip="$SWARM_DOWNLOAD_DIR/$NDK_ZIP"
  log "checking the NDK archive entries, then extracting (about 2 GB) -> $dest"
  assert_safe_zip_with_links "$zip" "$NDK_TOP_DIR"
  make_staging
  unzip -q -o "$zip" -d "$STAGING"
  [[ -d "$STAGING/$NDK_TOP_DIR" ]] || die "$NDK_TOP_DIR/ not found in $NDK_ZIP"
  grep -qx "Pkg.Revision *= *$SWARM_NDK_VERSION" "$STAGING/$NDK_TOP_DIR/source.properties" \
    || die "the NDK revision is not $SWARM_NDK_VERSION"
  [[ -x "$STAGING/$NDK_TOP_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]] || die "NDK clang missing after extraction"
  if [[ -e "$dest" ]]; then remove_cache_tree "$dest"; fi
  mkdir -p "$(dirname "$dest")"
  mv -- "$STAGING/$NDK_TOP_DIR" "$dest"
  stamp_write "$dest" "$stamp"
  log "OK (NDK installed): $dest"
}

install_qemu() {
  local dest="$SWARM_QEMU_DIR" stamp=.swarm-installed.sha256 deb member listing out emu
  if [[ -x "$SWARM_QEMU_AARCH64" && -x "$SWARM_QEMU_ARM" ]] && stamp_ok "$dest" "$stamp" all; then
    log "OK (qemu unchanged): $dest"
    return 0
  fi
  fetch_verified "$QEMU_DEB" "$QEMU_DEB_URL" "$QEMU_DEB_SIZE" "sha256:$QEMU_DEB_SHA256" "sha512:$QEMU_DEB_SHA512"
  deb="$SWARM_DOWNLOAD_DIR/$QEMU_DEB"
  # Each wanted member must be a regular file in the package's data archive (tar -tv: type letter "-").
  listing="$(dpkg-deb --fsys-tarfile "$deb" | tar -tv)" || die "cannot list the members of $QEMU_DEB"
  for member in "${QEMU_MEMBERS[@]}"; do
    awk -v m="$member" '$NF == m && substr($1, 1, 1) == "-" { found = 1 } END { exit !found }' <<<"$listing" \
      || die "$member is not a regular file in $QEMU_DEB"
  done
  log "extracting qemu-aarch64-static, qemu-arm-static and the copyright file -> $dest"
  make_staging
  dpkg-deb --fsys-tarfile "$deb" | tar -x -C "$STAGING" --no-same-owner -f - "${QEMU_MEMBERS[@]}" \
    || die "could not extract qemu from $QEMU_DEB"
  mkdir -p "$STAGING/qemu"
  for member in "${QEMU_MEMBERS[@]}"; do
    mv -- "$STAGING/$member" "$STAGING/qemu/"
  done
  for emu in qemu-aarch64-static qemu-arm-static; do
    out="$("$STAGING/qemu/$emu" --version 2>&1 | head -n 1)" || die "$emu does not run: $out"
    grep -qF "version 8.2.2 (Debian 1:$SWARM_QEMU_VERSION)" <<<"$out" || die "$emu reports '$out', expected 1:$SWARM_QEMU_VERSION"
  done
  if [[ -e "$dest" ]]; then remove_cache_tree "$dest"; fi
  mkdir -p "$(dirname "$dest")"
  mv -- "$STAGING/qemu" "$dest"
  stamp_write "$dest" "$stamp"
  log "OK (qemu installed): $dest"
}

# verify_scons_install: every installed scons file is the one in the wheel's RECORD (sha256 each, the entry
# script bin/scons included; pip records the hash of the script it wrote, shebang rewrite and all), and
# there is no compiled .pyc file in the SCons package (RECORD cannot vouch for those; pip install
# --no-compile does not make them). Sets SCONS_VERIFY_DETAIL to the reason when it fails.
verify_scons_install() {
  SCONS_VERIFY_DETAIL=""
  [[ -x "$SCONS" && -x "$SWARM_CPP_VENV/bin/python" ]] || { SCONS_VERIFY_DETAIL="scons or the venv python is missing"; return 1; }
  SCONS_VERIFY_DETAIL="$("$SWARM_CPP_VENV/bin/python" -I - "$SWARM_SCONS_VERSION" <<'PY' 2>&1
import base64, csv, glob, hashlib, os, sys

version = sys.argv[1]
prefix = os.path.realpath(sys.prefix)
site = glob.glob(os.path.join(prefix, "lib", "python3*", "site-packages"))
if len(site) != 1:
    sys.exit("no single site-packages directory")
site = site[0]
record = os.path.join(site, f"scons-{version}.dist-info", "RECORD")
with open(record, newline="") as f:
    rows = list(csv.reader(f))
checked = set()
for path, digest, _size in rows:
    full = os.path.realpath(os.path.join(site, path))   # ../../../bin/scons resolves to <venv>/bin/scons
    if not full.startswith(prefix + os.sep):
        sys.exit(f"RECORD entry outside the venv: {path}")
    if not digest:
        if os.path.basename(path) != "RECORD":
            sys.exit(f"RECORD entry without a hash: {path}")
        continue
    algo, _, expected = digest.partition("=")
    with open(full, "rb") as g:
        got = base64.urlsafe_b64encode(hashlib.new(algo, g.read()).digest()).rstrip(b"=").decode()
    if got != expected:
        sys.exit(f"hash mismatch: {path}")
    checked.add(os.path.relpath(full, prefix))
for needed in ("bin/scons",):
    if needed not in checked:
        sys.exit(f"{needed} is not covered by RECORD")
if len(checked) < 100:
    sys.exit(f"only {len(checked)} files in RECORD")
pyc = [os.path.join(d, n) for d, _, names in os.walk(os.path.join(site, "SCons")) for n in names if n.endswith((".pyc", ".pyo"))]
if pyc:
    sys.exit(f"{len(pyc)} compiled file(s) in SCons/ (installed without --no-compile?), e.g. {pyc[0]}")
print(f"{len(checked)} files verified")
PY
)" || return 1
}

install_scons() {
  if verify_scons_install; then
    log "OK (scons $SWARM_SCONS_VERSION unchanged, $SCONS_VERIFY_DETAIL): $SWARM_CPP_VENV"
    return 0
  fi
  [[ ! -e "$SWARM_CPP_VENV" ]] || log "scons in $SWARM_CPP_VENV is not as pinned ($SCONS_VERIFY_DETAIL); reinstalling"
  fetch_verified "$SCONS_WHEEL" "$SCONS_WHEEL_URL" "$SCONS_WHEEL_SIZE" "sha256:$SCONS_WHEEL_SHA256"
  log "creating the venv and installing scons $SWARM_SCONS_VERSION from the pinned wheel"
  make_staging
  printf 'scons==%s \\\n    --hash=sha256:%s\n' "$SWARM_SCONS_VERSION" "$SCONS_WHEEL_SHA256" >"$STAGING/requirements.txt"
  if [[ -e "$SWARM_CPP_VENV" ]]; then remove_cache_tree "$SWARM_CPP_VENV"; fi
  python3 -m venv "$SWARM_CPP_VENV" || { remove_cache_tree "$SWARM_CPP_VENV"; die "could not create the venv"; }
  # --no-index: pip never talks to a server; --require-hashes: it refuses anything without a matching hash.
  # --no-compile: no .pyc files, which RECORD would list without a hash (nothing vouches for them).
  "$SWARM_CPP_VENV/bin/python" -I -m pip install --disable-pip-version-check --no-cache-dir --no-index --no-compile \
    --find-links "$SWARM_DOWNLOAD_DIR" --require-hashes --no-deps --only-binary=:all: -r "$STAGING/requirements.txt" >/dev/null \
    || { remove_cache_tree "$SWARM_CPP_VENV"; die "pip could not install the pinned scons wheel"; }
  verify_scons_install || { local why="$SCONS_VERIFY_DETAIL"; remove_cache_tree "$SWARM_CPP_VENV"; die "the installed scons does not match its RECORD: $why"; }
  log "OK (scons installed): $SWARM_CPP_VENV"
}

install_godot_cpp() {
  local dir="$GODOT_CPP_DIR" head
  if swarm_godot_cpp_clean "$dir"; then
    log "OK (godot-cpp unchanged): $dir"
    return 0
  fi
  log "fetching godot-cpp $SWARM_GODOT_CPP_COMMIT"
  make_staging
  local stage="$STAGING/godot-cpp"
  mkdir -p "$stage"
  export GIT_TERMINAL_PROMPT=0
  git -C "$stage" init -q
  git -C "$stage" remote add origin "$SWARM_GODOT_CPP_REPO"
  git -C "$stage" fetch -q --depth 1 --no-tags origin "$SWARM_GODOT_CPP_COMMIT" \
    || die "could not fetch commit $SWARM_GODOT_CPP_COMMIT from $SWARM_GODOT_CPP_REPO"
  git -C "$stage" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
  head="$(git -C "$stage" rev-parse HEAD)"
  [[ "$head" == "$SWARM_GODOT_CPP_COMMIT" ]] || die "fetched commit is $head, expected $SWARM_GODOT_CPP_COMMIT"
  swarm_godot_cpp_clean "$stage" || die "the fresh godot-cpp checkout is not clean"
  if [[ -e "$dir" ]]; then remove_cache_tree "$dir"; fi
  mkdir -p "$(dirname "$dir")"
  mv -- "$stage" "$dir"
  swarm_godot_cpp_clean "$dir" || die "godot-cpp checkout failed verification after the move: $dir"
  log "OK (godot-cpp installed, HEAD == pin): $dir"
}

# dump_godot_api: the pinned Godot's own extension API, cached next to a stamp of the binary it came from.
dump_godot_api() {
  local out="$SWARM_GODOT_API_DIR" stamp godot_sha api_sha
  stamp="$out/.dump.sha256"
  godot_sha="$(sha256sum -- "$GODOT_BIN" | cut -d' ' -f1)"
  if [[ -s "$out/extension_api.json" && -s "$stamp" ]]; then
    api_sha="$(sha256sum -- "$out/extension_api.json" | cut -d' ' -f1)"
    if [[ "$(cat "$stamp")" == "$godot_sha $api_sha" ]]; then
      log "OK (Godot API dump unchanged): $out/extension_api.json"
      return 0
    fi
  fi
  log "dumping the extension API of $(swarm_godot --version | head -n 1)"
  make_staging
  (cd -- "$STAGING" && swarm_godot --headless --dump-extension-api >/dev/null 2>&1 &&
    swarm_godot --headless --dump-gdextension-interface >/dev/null 2>&1) || die "Godot could not dump its extension API"
  [[ -s "$STAGING/extension_api.json" && -s "$STAGING/gdextension_interface.h" ]] || die "the API dump is empty"
  mkdir -p "$out"
  mv -f -- "$STAGING/extension_api.json" "$STAGING/gdextension_interface.h" "$out/"
  api_sha="$(sha256sum -- "$out/extension_api.json" | cut -d' ' -f1)"
  printf '%s %s\n' "$godot_sha" "$api_sha" >"$stamp"
}

# check_api_version: godot-cpp builds its bindings from extension_api-<api_version>.json. That file must
# equal what the pinned Godot reports (header patch version aside); then api_version is the right choice
# and custom_api_file is not needed.
check_api_version() {
  local bundled="$GODOT_CPP_DIR/gdextension/extension_api-${SWARM_GODOT_API_VERSION//./-}.json" report="$SWARM_GODOT_API_DIR/api-compare.txt" rc=0
  [[ -f "$bundled" ]] || die "godot-cpp has no api_version=$SWARM_GODOT_API_VERSION file: $bundled"
  python3 -I "$SCRIPT_DIR/lib/compare_extension_api.py" "$SWARM_GODOT_API_JSON" "$bundled" >"$report" || rc=$?
  sed 's/^/    /' "$report"
  ((rc == 0)) || die "godot-cpp's api_version=$SWARM_GODOT_API_VERSION differs from the pinned Godot's API (see $report); build with custom_api_file instead"
  log "OK: api_version=$SWARM_GODOT_API_VERSION equals the API of $(swarm_godot --version | head -n 1)"
}

record_toolchain() {
  {
    printf 'GODOT_CPP_COMMIT=%s\n' "$SWARM_GODOT_CPP_COMMIT"
    printf 'GODOT_CPP_COMMIT_DATE=%s\n' "$(git -C "$GODOT_CPP_DIR" show -s --format=%cI HEAD)"
    printf 'GODOT_CPP_API_VERSION=%s\n' "$SWARM_GODOT_API_VERSION"
    if ((HOST_ONLY)); then printf 'NDK_VERSION=not installed (setup_cpp.sh --host-only)\n'; else printf 'NDK_VERSION=%s\n' "$SWARM_NDK_VERSION"; fi
    if ((HOST_ONLY)); then printf 'QEMU_VERSION=not installed (setup_cpp.sh --host-only)\n'; else printf 'QEMU_VERSION=%s\n' "$SWARM_QEMU_VERSION"; fi
    printf 'SCONS_VERSION=%s\n' "$SWARM_SCONS_VERSION"
    printf 'HOST_CLANG=%s\n' "$(clang --version | head -n 1)"
    printf 'API_CHECK=identical\n'
  } >"$SWARM_CPP_TOOLCHAIN_ENV"
}

smoke_test() {
  local out
  if ((HOST_ONLY)); then log "smoke test: scons, host clang"; else log "smoke test: scons, NDK clang, host clang"; fi
  out="$(swarm_scons --version 2>&1)" || die "scons does not run: $out"
  grep -q "SCons: v$SWARM_SCONS_VERSION\." <<<"$out" || die "scons does not report version $SWARM_SCONS_VERSION: $out"
  log "  scons $SWARM_SCONS_VERSION runs"
  log "  host: $(clang --version | head -n 1)"
  log "  host objdump: $(swarm_find_host_objdump || true)"
  ((HOST_ONLY)) && return 0
  log "  NDK: $("$SWARM_NDK_BIN/clang" --version | head -n 1)"
  # A one-line shared library for each Android ABI: compiler, sysroot and linker work together.
  make_staging
  printf 'int swarm_smoke(int a) { return a + 1; }\n' >"$STAGING/smoke.c"
  local target
  for target in aarch64-linux-android24 armv7a-linux-androideabi24; do
    "$SWARM_NDK_BIN/clang" --target="$target" -shared -fPIC -O2 -o "$STAGING/smoke-$target.so" "$STAGING/smoke.c" \
      || die "the NDK cannot build a shared library for $target"
  done
  log "  NDK builds shared libraries for arm64 and armv7"
  # A static executable for each ABI, run under qemu: the way the C++ test programs run on this host.
  # 6 * 7 = 42 is printed as "42 <sizeof(long)>": 8 on arm64, 4 on armv7.
  printf '#include <stdio.h>\nint main(void) { volatile int a = 6; printf("%%d %%zu\\n", a * 7, sizeof(long)); return 0; }\n' >"$STAGING/smoke_main.c"
  local emu expect
  for target in aarch64-linux-android24 armv7a-linux-androideabi24; do
    case "$target" in
      aarch64-*) emu="$SWARM_QEMU_AARCH64" expect="42 8" ;;
      *) emu="$SWARM_QEMU_ARM" expect="42 4" ;;
    esac
    "$SWARM_NDK_BIN/clang" --target="$target" -static -O2 -o "$STAGING/smoke-$target" "$STAGING/smoke_main.c" \
      || die "the NDK cannot build a static executable for $target"
    out="$("$emu" "$STAGING/smoke-$target" 2>&1)" || die "qemu cannot run the $target executable: $out"
    [[ "$out" == "$expect" ]] || die "the $target executable under qemu printed '$out', expected '$expect'"
  done
  log "  qemu $SWARM_QEMU_VERSION runs static arm64 and armv7 executables"
}

report() {
  local line
  printf 'cache dir        : %s\n' "$SWARM_CACHE_DIR"
  printf 'Godot            : %s\n' "$(swarm_godot --version | head -n 1)"
  if [[ -x "$SWARM_NDK_BIN/clang" ]]; then
    printf 'NDK              : %s (%s)  %s\n' "$SWARM_NDK_RELEASE" "$SWARM_NDK_VERSION" "$ANDROID_NDK_ROOT"
  else
    printf 'NDK              : %s (%s)  NOT INSTALLED (host-only setup; tools/build_android.sh needs the full tools/setup_cpp.sh)\n' "$SWARM_NDK_RELEASE" "$SWARM_NDK_VERSION"
  fi
  printf '  zip            : %s  %s bytes\n' "$NDK_ZIP" "$NDK_ZIP_SIZE"
  printf '  zip sha1       : %s  (published in repository2-3.xml)\n' "$NDK_ZIP_SHA1"
  printf '  zip sha256     : %s  (computed, pinned)\n' "$NDK_ZIP_SHA256"
  if [[ -x "$SWARM_NDK_BIN/clang" ]]; then
    printf '  clang          : %s\n' "$("$SWARM_NDK_BIN/clang" --version 2>/dev/null | head -n 1)"
  else
    printf '  clang          : (NDK not installed; host-only setup)\n'
  fi
  if [[ -x "$SWARM_QEMU_AARCH64" ]]; then
    printf 'qemu-user        : %s  %s\n' "$SWARM_QEMU_VERSION" "$SWARM_QEMU_DIR"
  else
    printf 'qemu-user        : %s  NOT INSTALLED (host-only setup)\n' "$SWARM_QEMU_VERSION"
  fi
  printf '  deb            : %s  %s bytes\n' "$QEMU_DEB" "$QEMU_DEB_SIZE"
  printf '  deb sha256     : %s  (published in noble-updates Packages, signed InRelease)\n' "$QEMU_DEB_SHA256"
  printf 'SCons            : %s  %s\n' "$SWARM_SCONS_VERSION" "$SCONS"
  printf '  wheel          : %s  %s bytes\n' "$SCONS_WHEEL" "$SCONS_WHEEL_SIZE"
  printf '  wheel sha256   : %s\n' "$SCONS_WHEEL_SHA256"
  printf '  python (venv)  : %s\n' "$("$SWARM_CPP_VENV/bin/python" -I -c 'import sys; print(sys.version.split()[0])' 2>/dev/null)"
  printf '  scons --version: %s\n' "$(swarm_scons --version 2>/dev/null | sed -n 's/^[[:space:]]*SCons: //p' | head -n 1)"
  printf 'godot-cpp        : %s\n' "$SWARM_GODOT_CPP_REPO"
  printf '  commit (pin)   : %s\n' "$SWARM_GODOT_CPP_COMMIT"
  printf '  git HEAD       : %s\n' "$(git -C "$GODOT_CPP_DIR" rev-parse HEAD 2>/dev/null)"
  printf '  commit date    : %s\n' "$(git -C "$GODOT_CPP_DIR" show -s --format=%cI HEAD 2>/dev/null)"
  printf '  commit subject : %s\n' "$(git -C "$GODOT_CPP_DIR" show -s --format=%s HEAD 2>/dev/null)"
  printf '  work tree      : %s\n' "$(swarm_godot_cpp_clean "$GODOT_CPP_DIR" && echo 'clean (no modified, untracked or ignored files)' || echo 'NOT CLEAN')"
  printf '  api_version    : %s\n' "$SWARM_GODOT_API_VERSION"
  printf 'host compiler    : %s\n' "$(clang --version | head -n 1)"
  printf 'host objdump     : %s\n' "$(swarm_find_host_objdump)"
  printf 'host gcc         : %s\n' "$(gcc --version 2>/dev/null | head -n 1)"
  printf 'python3          : %s\n' "$(python3 --version)"
  printf 'cmake / ninja    : %s / %s (not used by the C1 build)\n' "$(cmake --version 2>/dev/null | head -n 1)" "$(ninja --version 2>/dev/null)"
  printf '\nGodot API check (%s):\n' "$SWARM_GODOT_API_DIR/api-compare.txt"
  if [[ -f "$SWARM_GODOT_API_DIR/api-compare.txt" ]]; then
    while IFS= read -r line; do printf '  %s\n' "$line"; done <"$SWARM_GODOT_API_DIR/api-compare.txt"
  fi
  printf '\nrecorded facts (%s):\n' "$SWARM_CPP_TOOLCHAIN_ENV"
  if [[ -f "$SWARM_CPP_TOOLCHAIN_ENV" ]]; then
    while IFS= read -r line; do printf '  %s\n' "$line"; done <"$SWARM_CPP_TOOLCHAIN_ENV"
  fi
}

main() {
  local report=0 arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help) usage; exit 0 ;;
      --host-only) HOST_ONLY=1 ;;
      --report) report=1 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  if ((report)); then
    # The full toolchain check applies (host-only: its reduced form): a report of a half-installed toolchain would mislead.
    SWARM_CPP_TOOLCHAIN_SKIP_CHECK=0
    SWARM_CPP_HOST_ONLY=$HOST_ONLY
    # shellcheck source=lib/cpp_toolchain.sh
    source "$SCRIPT_DIR/lib/cpp_toolchain.sh" || exit 1
    report
    exit 0
  fi
  preflight
  rm -f -- "$SWARM_CPP_TOOLCHAIN_ENV"   # a failed run must not leave the "set up" marker of an earlier one
  if ((HOST_ONLY)); then log "--host-only: the Android NDK and qemu are neither installed nor checked"; else install_ndk; install_qemu; fi
  install_scons
  install_godot_cpp
  dump_godot_api
  check_api_version
  record_toolchain
  smoke_test
  if ((HOST_ONLY)); then
    log "done (host-only). In scripts: SWARM_CPP_HOST_ONLY=1; source tools/lib/cpp_toolchain.sh"
  else
    log "done. In scripts: source tools/lib/cpp_toolchain.sh  (ANDROID_NDK_ROOT=$ANDROID_NDK_ROOT)"
  fi
}

main "$@"
