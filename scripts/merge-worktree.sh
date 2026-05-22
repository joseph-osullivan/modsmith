#!/bin/bash
# merge-worktree.sh — merge a subtask's branch into the run feature branch,
# then remove the worktree and delete the agent branch.
#
# Usage:
#   merge-worktree.sh <subtask_id> <feature_branch>
#
# Stdout: JSON {status, conflict_files?, via?}.
#   status=merged                       | clean merge, worktree removed, branch deleted
#   status=conflict                     | conflict — orchestrator must surface to user; nothing removed
#   status=already_merged via=ancestor  | branch tip is an ancestor of feature_branch
#   status=already_merged via=content   | branch's commits are patch-equivalent in feature (squash-merge case)
#
# Exit 0 on merged/already_merged; 1 on conflict; 2 on usage error.

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SUBTASK_ID="${1:-}"
FEATURE="${2:-}"

if [ -z "$SUBTASK_ID" ] || [ -z "$FEATURE" ]; then
  warn "usage: merge-worktree.sh <subtask_id> <feature_branch>"
  exit 2
fi

ROOT=$(repo_root)
cd "$ROOT"

BRANCH="agent/$SUBTASK_ID"
WT_PATH=".trees/$SUBTASK_ID"

if ! git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  warn "branch $BRANCH does not exist"
  exit 2
fi

# Ensure we're on the feature branch in the main checkout (NOT in the worktree).
git checkout "$FEATURE" >&2

# Already merged via fast-forward ancestry?
if git merge-base --is-ancestor "$BRANCH" "$FEATURE"; then
  emit_json status=already_merged branch="$BRANCH" via=ancestor
  git worktree remove --force "$WT_PATH" 2>/dev/null || true
  git branch -D "$BRANCH" 2>/dev/null || true
  exit 0
fi

# Already merged via content-equivalence (squash-merge case)?
# Compute the hypothetical merged tree (git merge-tree --write-tree). If it
# equals the feature's current tree, merging would change nothing — i.e. the
# branch's content is already in feature (regardless of how many commits the
# squash collapsed). Robust to multi-commit branches and avoids the patch-ID
# pitfall of `git cherry` for squashed-into-one merges.
MERGE_BASE=$(git merge-base "$FEATURE" "$BRANCH" 2>/dev/null || echo "")
if [ -n "$MERGE_BASE" ]; then
  HYPOTHETICAL=$(git merge-tree --write-tree --merge-base "$MERGE_BASE" "$FEATURE" "$BRANCH" 2>/dev/null || echo "")
  FEATURE_TREE=$(git rev-parse "$FEATURE^{tree}")
  if [ -n "$HYPOTHETICAL" ] && [ "$HYPOTHETICAL" = "$FEATURE_TREE" ]; then
    emit_json status=already_merged branch="$BRANCH" via=content
    git worktree remove --force "$WT_PATH" 2>/dev/null || true
    git branch -D "$BRANCH" 2>/dev/null || true
    exit 0
  fi
fi

# Attempt merge.
if git merge --no-ff --no-edit "$BRANCH" >&2; then
  git worktree remove --force "$WT_PATH" 2>/dev/null || true
  git branch -d "$BRANCH" 2>/dev/null || git branch -D "$BRANCH" 2>/dev/null || true
  emit_json status=merged branch="$BRANCH"
  exit 0
fi

# Conflict — abort, surface, leave everything intact for human resolution.
CONFLICT_FILES=$(git diff --name-only --diff-filter=U | tr '\n' ',' | sed 's/,$//')
git merge --abort 2>/dev/null || true
emit_json status=conflict branch="$BRANCH" files="$CONFLICT_FILES"
exit 1
