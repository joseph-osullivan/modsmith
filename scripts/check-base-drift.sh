#!/bin/bash
# check-base-drift.sh — detect whether the run's base branch has moved out from
# under us, and whether any drifted commits touch files our run touched.
#
# Run-024 was bitten by this: PR #70 merged and a follow-up refactor reorganized
# packages mid-run; rebase produced 5-file conflicts. The orchestrator can call
# this at run start AND just before final rebase; if drift is high or overlaps
# touched files, prompt the user.
#
# Usage:
#   check-base-drift.sh <base_branch> <run_start_sha> [<run_dir>]
#
# Stdout: JSON {drift_commits, drift_files, overlap_files, files_run_touched}
# Exit 0 always (informational).

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

BASE="${1:-}"
RUN_START_SHA="${2:-}"
RUN_DIR="${3:-}"

if [ -z "$BASE" ] || [ -z "$RUN_START_SHA" ]; then
  warn "usage: check-base-drift.sh <base_branch> <run_start_sha> [<run_dir>]"
  exit 2
fi

ROOT=$(repo_root)
cd "$ROOT"

git fetch origin "${BASE#origin/}" >&2 2>/dev/null || true
NOW_SHA=$(git rev-parse "$BASE" 2>/dev/null || echo "$RUN_START_SHA")

DRIFT_COMMITS=$(git rev-list --count "$RUN_START_SHA..$NOW_SHA" 2>/dev/null || echo 0)

# Files changed on base since run start.
DRIFT_FILES_LIST=$(git diff --name-only "$RUN_START_SHA..$NOW_SHA" 2>/dev/null || echo "")
DRIFT_FILES=$(printf '%s\n' "$DRIFT_FILES_LIST" | grep -c . 2>/dev/null || echo 0)

OVERLAP=""
TOUCHED=0
if [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ]; then
  # Files our run modified — derive from feature branch commits.
  # Architect.json's files_to_modify isn't authoritative; git is.
  CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "$BASE" ]; then
    RUN_TOUCHED=$(git diff --name-only "$RUN_START_SHA..HEAD" 2>/dev/null || echo "")
    TOUCHED=$(printf '%s\n' "$RUN_TOUCHED" | grep -c . 2>/dev/null || echo 0)
    if [ -n "$RUN_TOUCHED" ] && [ -n "$DRIFT_FILES_LIST" ]; then
      OVERLAP=$(comm -12 <(printf '%s\n' "$RUN_TOUCHED" | sort -u) <(printf '%s\n' "$DRIFT_FILES_LIST" | sort -u) | tr '\n' ',' | sed 's/,$//')
    fi
  fi
fi

# Severity hint for the orchestrator.
SEVERITY=low
[ "$DRIFT_COMMITS" -gt 50 ] && SEVERITY=high
[ -n "$OVERLAP" ] && SEVERITY=critical

emit_json \
  base="$BASE" \
  run_start_sha="${RUN_START_SHA:0:10}" \
  now_sha="${NOW_SHA:0:10}" \
  drift_commits="$DRIFT_COMMITS" \
  drift_files="$DRIFT_FILES" \
  overlap_files="$OVERLAP" \
  files_run_touched="$TOUCHED" \
  severity="$SEVERITY"
