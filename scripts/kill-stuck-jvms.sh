#!/bin/bash
# kill-stuck-jvms.sh — kill leftover NeoForge GameTest JVMs.
# Leaves the gradle daemon alone (it should remain warm for build cache reuse).
#
# Multi-session guard: only JVMs older than MIN_AGE_SECONDS (default 900)
# are considered stuck. A young gametestserver is very likely a LIVE run —
# possibly another Claude session's — and killing it mid-suite flakes their
# tests and can corrupt their run dir. Use --force to override the age gate
# when you KNOW the process is yours and wedged.
#
# Usage:
#   kill-stuck-jvms.sh             # kill JVMs older than 15 min
#   kill-stuck-jvms.sh --dry-run   # report only
#   kill-stuck-jvms.sh --force     # kill regardless of age (dangerous)

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

DRY=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
  esac
done

MIN_AGE_SECONDS="${MIN_AGE_SECONDS:-900}"

# etime formats: MM:SS | HH:MM:SS | D-HH:MM:SS
etime_to_seconds() {
  local e="$1" days=0 rest
  case "$e" in
    *-*) days="${e%%-*}"; rest="${e#*-}" ;;
    *)   rest="$e" ;;
  esac
  local IFS=':'
  set -- $rest
  local secs=0
  case $# in
    2) secs=$((10#$1 * 60 + 10#$2)) ;;
    3) secs=$((10#$1 * 3600 + 10#$2 * 60 + 10#$3)) ;;
  esac
  echo $((days * 86400 + secs))
}

# Match GameTest server JVMs (and only those — gradle daemon JVMs do NOT contain
# 'gametestserver' in their cmdline).
PIDS=$(pgrep -f "gametestserver" 2>/dev/null || true)

KILLED=()
SPARED=()
for pid in $PIDS; do
  if [ $FORCE -eq 0 ]; then
    ETIME=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -n "$ETIME" ]; then
      AGE=$(etime_to_seconds "$ETIME")
      if [ "$AGE" -lt "$MIN_AGE_SECONDS" ]; then
        SPARED+=("$pid")
        continue
      fi
    fi
  fi
  if [ $DRY -eq 1 ]; then
    KILLED+=("$pid")
  else
    kill -9 "$pid" 2>/dev/null && KILLED+=("$pid") || true
  fi
done

# Comma-join (guard against empty arrays under set -u).
ids=""
if [ ${#KILLED[@]} -gt 0 ]; then
  for p in "${KILLED[@]}"; do ids+="${p},"; done
  ids="${ids%,}"
fi
spared_ids=""
if [ ${#SPARED[@]} -gt 0 ]; then
  for p in "${SPARED[@]}"; do spared_ids+="${p},"; done
  spared_ids="${spared_ids%,}"
fi

emit_json killed_count="${#KILLED[@]}" pids="$ids" spared_young_count="${#SPARED[@]}" spared_pids="$spared_ids" dry_run="$DRY"
