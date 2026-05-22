#!/bin/bash
# Shared helpers for mc-mod-develop scripts. Source via:
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
# Detects by reading gradle.properties for a minecraft_version key.
is_mc_mod_repo() {
  [ -f gradle.properties ] && grep -q '^minecraft_version=' gradle.properties
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
