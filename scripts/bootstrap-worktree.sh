#!/bin/bash
# bootstrap-worktree.sh — create a worktree for one parallel-group subtask.
# Idempotent: if the worktree already exists at the expected path, reports it
# without recreating.
#
# Usage:
#   bootstrap-worktree.sh <subtask_id> [<base_branch>]
#
# Stdout: JSON {path, branch, existed, base_sha}
# Exit 0 on success; 2 on usage error; 1 on git failure.

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SUBTASK_ID="${1:-}"
BASE="${2:-origin/main}"

if [ -z "$SUBTASK_ID" ]; then
  warn "usage: bootstrap-worktree.sh <subtask_id> [<base_branch>]"
  exit 2
fi

if ! is_mc_mod_repo; then
  warn "not a Minecraft mod repo (no minecraft_version in gradle.properties)"
  exit 2
fi

ROOT=$(repo_root)
cd "$ROOT"

WT_PATH=".trees/$SUBTASK_ID"
BRANCH="agent/$SUBTASK_ID"
BASE_SHA=$(git rev-parse "$BASE" 2>/dev/null || echo "")

if [ -z "$BASE_SHA" ]; then
  warn "base $BASE not found — fetching"
  git fetch origin "${BASE#origin/}" >&2
  BASE_SHA=$(git rev-parse "$BASE")
fi

if git worktree list --porcelain | awk '/^worktree/ {print $2}' | grep -qx "$ROOT/$WT_PATH"; then
  emit_json path="$WT_PATH" branch="$BRANCH" existed=true base_sha="$BASE_SHA"
  exit 0
fi

# If the branch exists from a prior aborted run, reuse it; otherwise create.
if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  git worktree add "$WT_PATH" "$BRANCH" >&2
else
  git worktree add "$WT_PATH" -b "$BRANCH" "$BASE" >&2
fi

emit_json path="$WT_PATH" branch="$BRANCH" existed=false base_sha="$BASE_SHA"
