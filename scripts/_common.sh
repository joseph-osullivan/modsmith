#!/bin/bash
# Shared helpers for modsmith scripts. Source via:
#   . "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
#
# All scripts are stdout=structured-data, stderr=diagnostics. Exit codes:
#   0 ok | 1 generic error | 2 invalid args | 3 environmental block (plan-mode etc)

set -euo pipefail

# Print a JSON line to stdout. Args: key=value pairs (values are strings).
emit_json() {
  local out="{"
  local first=1
  for kv in "$@"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    [ $first -eq 0 ] && out+=","
    out+="\"$k\":\"${v//\"/\\\"}\""
    first=0
  done
  out+="}"
  printf '%s\n' "$out"
}

# True if cwd looks like a Minecraft mod project (NeoForge / Forge / Fabric).
# Detects by reading gradle.properties for an MC version key. The canonical
# key is `minecraft_version`; older scaffolds wrote `mc_version`, and older
# multi-MC scaffolds only wrote per-MC suffixed keys (e.g. `mc_version_1_21_1`,
# digits and underscores). Accept all three shapes. The digit-led suffix rule
# keeps unrelated keys like `mc_version_range` from matching.
is_mc_mod_repo() {
  [ -f gradle.properties ] \
    && grep -qE '^[[:space:]]*(minecraft_version|mc_version(_[0-9][0-9_]*)?)[[:space:]]*=' gradle.properties
}

# Resolve the repo root from cwd (works inside worktrees).
repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

# Print to stderr.
warn() { printf '%s\n' "$*" >&2; }

# Find the active run dir under docs/workflow-runs/ — most recent by mtime.
# Used by hook scripts that don't get a run dir argument.
latest_run_dir() {
  local root; root=$(repo_root) || return 1
  ls -1dt "$root"/docs/workflow-runs/[0-9]*/ 2>/dev/null | head -1
}
