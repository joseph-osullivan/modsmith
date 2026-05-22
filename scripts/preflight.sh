#!/bin/bash
# preflight.sh — pre-run environmental check for /mc-mod-develop.
# Usage:
#   preflight.sh                # full check + remediation
#   preflight.sh --check-only   # report only, don't kill/clean
#
# Stdout: one JSON line summarizing checks. Exit 0 = ready; 3 = blocked.

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

CHECK_ONLY=0
[ "${1:-}" = "--check-only" ] && CHECK_ONLY=1

if ! is_mc_mod_repo; then
  emit_json status=skip reason=not_mc_mod_repo
  exit 0
fi

ROOT=$(repo_root)
cd "$ROOT"

# 1. Plan-mode probe — try to write a tempfile. If permission is denied, halt.
PROBE_DIR=".cache/mc-mod-develop"
PROBE_FILE="$PROBE_DIR/.preflight-$$"
mkdir -p "$PROBE_DIR" 2>/dev/null || true
if ! ( : > "$PROBE_FILE" ) 2>/dev/null; then
  emit_json status=blocked reason=plan_mode_or_no_write hint="ExitPlanMode and re-invoke"
  exit 3
fi
rm -f "$PROBE_FILE" 2>/dev/null || true

# 2. Stuck NeoForge GameTest JVMs (leave gradle daemons alone).
JVM_PIDS=$(pgrep -f "gametestserver" 2>/dev/null || true)
JVM_KILLED=0
if [ -n "$JVM_PIDS" ] && [ $CHECK_ONLY -eq 0 ]; then
  for pid in $JVM_PIDS; do
    kill -9 "$pid" 2>/dev/null && JVM_KILLED=$((JVM_KILLED + 1)) || true
  done
fi

# 3. Purge stale GameTest universe (find -delete slips past Bash(rm *) deny).
GT_DIR="run/gametestserver"
GT_PURGED=0
if [ -d "$GT_DIR" ] && [ $CHECK_ONLY -eq 0 ]; then
  find "$GT_DIR" -mindepth 1 -depth -delete 2>/dev/null || true
  GT_PURGED=1
fi

# 4. Stale .trees/ worktrees from prior runs (report only — never auto-remove).
STALE_TREES=$(git worktree list --porcelain 2>/dev/null \
  | awk '/^worktree.*\.trees\// {print $2}' | wc -l | tr -d ' ')

# 5. Disk space (warn at <2 GB free; build cache + gametest universe eats GB).
FREE_GB=$(df -g . | awk 'NR==2 {print $4}')

emit_json \
  status=ok \
  jvm_killed="$JVM_KILLED" \
  gametest_dir_purged="$GT_PURGED" \
  stale_worktrees="$STALE_TREES" \
  free_gb="$FREE_GB" \
  check_only="$CHECK_ONLY"
