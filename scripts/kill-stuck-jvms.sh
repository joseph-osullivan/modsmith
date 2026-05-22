#!/bin/bash
# kill-stuck-jvms.sh — kill leftover NeoForge GameTest JVMs.
# Leaves the gradle daemon alone (it should remain warm for build cache reuse).
#
# Usage:
#   kill-stuck-jvms.sh           # actively kill
#   kill-stuck-jvms.sh --dry-run # report only

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# Match GameTest server JVMs (and only those — gradle daemon JVMs do NOT contain
# 'gametestserver' in their cmdline).
PIDS=$(pgrep -f "gametestserver" 2>/dev/null || true)

KILLED=()
for pid in $PIDS; do
  if [ $DRY -eq 1 ]; then
    KILLED+=("$pid")
  else
    kill -9 "$pid" 2>/dev/null && KILLED+=("$pid") || true
  fi
done

# Comma-join (guard against empty array under set -u).
ids=""
if [ ${#KILLED[@]} -gt 0 ]; then
  for p in "${KILLED[@]}"; do ids+="${p},"; done
  ids="${ids%,}"
fi

emit_json killed_count="${#KILLED[@]}" pids="$ids" dry_run="$DRY"
