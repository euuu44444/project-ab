# shellcheck shell=bash
# Helpers shared by tools/setup_godot.sh and tools/setup_cpp.sh: verified downloads, safe archive
# extraction, install stamps and staging directories inside the cache dir. Source it; do not execute it.
#
# Needs from the caller (both come from lib/toolchain.sh): SWARM_CACHE_DIR and SWARM_DOWNLOAD_DIR.
# The caller MUST assign SETUP_LOG_TAG before sourcing (setup_godot.sh: "setup", setup_cpp.sh: "setup-cpp");
# it prefixes log() and die(). There is deliberately no default: a default of "${SETUP_LOG_TAG:-setup}"
# would take a value the user happens to have in the environment.
#
# Every download is checked against a pinned size and hash BEFORE anything is extracted or run.
# Installed trees get a stamp (sha256 of every installed file); a re-run re-hashes the tree and only
# extracts again when something changed.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "tools/lib/setup_common.sh must be sourced, not executed." >&2
  exit 2
fi

if [[ -z "${SETUP_LOG_TAG:-}" ]]; then
  echo "tools/lib/setup_common.sh: the caller must set SETUP_LOG_TAG before sourcing it." >&2
  return 1
fi
log() { printf '[%s] %s\n' "$SETUP_LOG_TAG" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$SETUP_LOG_TAG" "$*" >&2; exit 1; }

# take_setup_lock: one setup script at a time per cache dir. setup_godot.sh and setup_cpp.sh share the lock
# (descriptor 9 stays open for the rest of the script).
take_setup_lock() {
  exec 9>"$SWARM_CACHE_DIR/.setup.lock"
  flock -n 9 || die "another setup script (setup_godot.sh or setup_cpp.sh) is already running for $SWARM_CACHE_DIR"
}

STAGING=""
STAGING_DIRS=()
cleanup() {
  local d
  for d in ${STAGING_DIRS[@]+"${STAGING_DIRS[@]}"}; do
    [[ "$d" == "$SWARM_CACHE_DIR"/.staging.* ]] && rm -rf -- "$d"
  done
  return 0
}
trap cleanup EXIT

make_staging() {
  STAGING="$(mktemp -d "$SWARM_CACHE_DIR/.staging.XXXXXX")"
  STAGING_DIRS+=("$STAGING")
}

remove_cache_tree() {
  [[ "$1" == "$SWARM_CACHE_DIR"/?* ]] || die "refusing to delete outside the cache dir: $1"
  rm -rf -- "$1"
}

hash_of() { # algo file
  case "$1" in
    sha1) sha1sum -- "$2" ;;
    sha256) sha256sum -- "$2" ;;
    sha512) sha512sum -- "$2" ;;
    *) die "unknown hash algorithm: $1" ;;
  esac | cut -d' ' -f1
}

# check_file FILE SIZE ALGO:HASH...  -> 0 only if the size and every hash match
check_file() {
  local file=$1 size=$2 pair got
  shift 2
  [[ -f "$file" ]] || return 1
  [[ "$(stat -c %s -- "$file")" == "$size" ]] || return 1
  for pair in "$@"; do
    got="$(hash_of "${pair%%:*}" "$file")"
    [[ "$got" == "${pair#*:}" ]] || return 1
  done
}

# fetch_verified NAME URL SIZE ALGO:HASH...  -> $SWARM_DOWNLOAD_DIR/NAME, verified
fetch_verified() {
  local name=$1 url=$2 size=$3 rc
  shift 3
  local dest="$SWARM_DOWNLOAD_DIR/$name" part="$SWARM_DOWNLOAD_DIR/$name.part"
  local progress=(-sS)
  [[ -t 2 ]] && progress=(--progress-bar)

  if check_file "$dest" "$size" "$@"; then
    log "OK (verified, cached): $name"
    return 0
  fi
  if [[ -e "$dest" ]]; then
    log "cached file failed verification; discarding: $name"
    rm -f -- "$dest"
  fi
  # An interrupted run may have left a complete .part that only lacks the final rename.
  if ! check_file "$part" "$size" "$@"; then
    log "downloading $name ($size bytes)"
    rc=0
    curl -fL --retry 4 --retry-delay 3 --retry-connrefused -C - "${progress[@]}" -o "$part" "$url" || rc=$?
    if ((rc == 33)); then # 33 = the server rejects the range request: only then is the partial file useless
      log "cannot resume; restarting from scratch: $name"
      rm -f -- "$part"
      curl -fL --retry 4 --retry-delay 3 --retry-connrefused "${progress[@]}" -o "$part" "$url" || die "download failed: $url"
    elif ((rc != 0)); then
      die "download failed (curl exit $rc): $url (the partial file was kept; re-run to resume)"
    fi
  fi
  if ! check_file "$part" "$size" "$@"; then
    rm -f -- "$part"
    die "size/hash mismatch for $name; the file was discarded and nothing was extracted"
  fi
  mv -f -- "$part" "$dest"
  log "OK (downloaded, verified): $name"
}

# Reject archives with absolute paths, '..' components or symlinks before extracting.
assert_safe_zip() {
  local listing bad
  listing="$(unzip -Z1 -- "$1")" || die "cannot list the entries of $1"
  [[ -n "$listing" ]] || die "archive has no entries: $1"
  bad="$(grep -E '^/|(^|/)\.\.(/|$)' <<<"$listing" || true)"
  [[ -z "$bad" ]] || die "unsafe path in archive $1: $bad"
  listing="$(unzip -Z -- "$1")" || die "cannot list the entries of $1"
  bad="$(grep -E '^l' <<<"$listing" || true)"
  [[ -z "$bad" ]] || die "symlink entry in archive $1: $bad"
}

# stamp_write DIR STAMPNAME [RELFILE...]: record sha256 of the installed files (all files if none given)
stamp_write() {
  local dir=$1 stamp=$2
  shift 2
  (
    cd -- "$dir"
    if (($# > 0)); then
      printf '%s\0' "$@"
    else
      find . ! -type d ! -path "./$stamp" -print0 | LC_ALL=C sort -z
    fi | xargs -0 -r sha256sum -- >"$stamp"
  )
}
# stamp_ok DIR STAMPNAME [all]: the stamped files are unchanged; with "all" the directory must also
# hold nothing else (a file added to an installed tree counts as a change, so it is re-extracted).
stamp_ok() {
  local stamped present
  [[ -s "$1/$2" ]] || return 1
  (cd -- "$1" && sha256sum --quiet --strict -c -- "$2" >/dev/null 2>&1) || return 1
  [[ "${3:-}" == all ]] || return 0
  stamped="$(sed 's/^[0-9a-f]\{64\}  \(\.\/\)\{0,1\}//' "$1/$2" | LC_ALL=C sort)"
  present="$(cd -- "$1" && find . ! -type d ! -path "./$2" -print | sed 's|^\./||' | LC_ALL=C sort)"
  [[ "$stamped" == "$present" ]]
}

# assert_safe_zip_with_links ZIP TOPDIR: like assert_safe_zip, but symlink entries are allowed when they
# are harmless (the Android NDK ships 35 of them). Every entry must live below TOPDIR/ and have a plain
# name; only regular files, directories and symlinks are allowed; a symlink must be relative and its
# target must stay inside TOPDIR/, must not pass through another symlink on the way, and no entry may
# be located below a symlink (that would let a later entry be written through it).
assert_safe_zip_with_links() {
  python3 -I - "$1" "$2" <<'PY' || die "unsafe or unreadable archive: $1"
import posixpath, stat, sys, zipfile

path, top = sys.argv[1], sys.argv[2]
MAX_ENTRIES, MAX_BYTES = 100_000, 8 << 30


def fail(msg):
    print(f"  {msg}", file=sys.stderr)
    sys.exit(1)


def inside(p):
    return p == top or p.startswith(top + "/")


with zipfile.ZipFile(path) as zf:
    infos = zf.infolist()
    if not infos:
        fail("archive has no entries")
    if len(infos) > MAX_ENTRIES or sum(i.file_size for i in infos) > MAX_BYTES:
        fail("archive is implausibly large")
    names, links = set(), {}
    for i in infos:
        n = i.filename.rstrip("/")
        if i.filename.startswith("/") or "\\" in n or "\0" in n or any(c in ("", ".", "..") for c in n.split("/")):
            fail(f"unsafe path: {i.filename!r}")
        if not inside(n):
            fail(f"entry outside {top}/: {i.filename!r}")
        mode = stat.S_IFMT((i.external_attr >> 16) & 0xFFFF)
        if mode == stat.S_IFLNK:
            target = zf.read(i).decode("utf-8", "strict")
            if not target or target.startswith("/") or "\0" in target:
                fail(f"symlink with an absolute or empty target: {n} -> {target!r}")
            links[n] = posixpath.normpath(posixpath.join(posixpath.dirname(n), target))
        elif mode not in (0, stat.S_IFREG, stat.S_IFDIR):
            fail(f"special file type {oct(mode)}: {n}")
        names.add(n)
    for n, resolved in links.items():
        if not inside(resolved):
            fail(f"symlink escapes {top}/: {n} -> {resolved}")
        parts = resolved.split("/")
        for k in range(1, len(parts)):
            if "/".join(parts[:k]) in links:
                fail(f"symlink target passes through another symlink: {n} -> {resolved}")
    for n in names:
        parts = n.split("/")
        for k in range(1, len(parts)):
            if "/".join(parts[:k]) in links:
                fail(f"entry below a symlink: {n}")
PY
}
