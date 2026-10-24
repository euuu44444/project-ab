# shellcheck shell=bash
# Helpers for running the Godot editor on godot/ (the project). Source it; do not execute it.
#
#   source "$SCRIPT_DIR/lib/godot_project.sh"
#   swarm_seed_extension_list "$PROJECT_DIR"      # before the first `godot --import` of a checkout

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "tools/lib/godot_project.sh must be sourced, not executed." >&2
  exit 2
fi

# swarm_seed_extension_list PROJECT_DIR
#
# Workaround for a Godot 4.7.2 editor crash (found by the C1 review): on a fresh checkout (no
# PROJECT_DIR/.godot yet) the first headless `--import` loads the GDExtension class (SwarmNative) during
# its first filesystem scan and then crashes while shutting down (SIGSEGV, exit code 134; about one run
# in one to three). When PROJECT_DIR/.godot/extension_list.cfg already lists the extension, the editor
# loads it at startup instead, before any scan, and the crash does not happen.
#
# So: if .godot/extension_list.cfg does not exist, create it with one `res://<path>` line per
# *.gdextension file of the project (today: res://swarm_native.gdextension). An existing file is left
# alone: the editor maintains it itself from then on.
swarm_seed_extension_list() {
  local project=$1 list tmp ext
  local exts=()
  list="$project/.godot/extension_list.cfg"
  [[ -e "$list" ]] && return 0
  while IFS= read -r -d '' ext; do
    exts+=("res://${ext#"$project"/}")
  done < <(find "$project" -path "$project/.godot" -prune -o -type f -name '*.gdextension' -print0 | LC_ALL=C sort -z)
  ((${#exts[@]} > 0)) || return 0
  mkdir -p -- "$project/.godot"
  tmp="$(mktemp "$project/.godot/extension_list.cfg.XXXXXX")"
  printf '%s\n' "${exts[@]}" >"$tmp"
  chmod 0644 -- "$tmp"
  mv -f -- "$tmp" "$list"
}
