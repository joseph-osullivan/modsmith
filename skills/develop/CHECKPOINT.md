# Checkpoint format — `state.json`

Every `/mc-mod-develop` run owns a directory `docs/workflow-runs/NNN-feature-slug/` and writes a single `state.json` in it. This file is the **source of truth** for resume — when the orchestrator starts, the first thing it does is read `state.json` and fast-forward to the current phase.

Inspired by LangGraph's checkpoint model: capture metadata + file references, NOT raw content. Detailed phase outputs live in sibling markdown files (`research.md`, `plan.md`, `build-log.md`, `review.md`); `state.json` only references them.

## Schema (version 1)

```json
{
  "version": "1",
  "run_id": "run-023-feature-slug",
  "created_at": "ISO-8601",
  "updated_at": "ISO-8601",
  "user_prompt": "<verbatim, never edited after run start>",

  "parent_run_id": "run-022-bundle-a-bug-fixes",
  "base_branch": "feat/run-022-bundle-a",
  "extends_pr": 79,

  "current_phase": "architect | research | plan | build | gametest | scenario | review | pr | complete",
  "completed_phases": ["architect", "research", "plan"],

  "architect": {
    "status": "skipped | pending | complete",
    "output_ref": "architect.json",
    "subtask_count": 4,
    "parallel_group_count": 2
  },

  "research": {
    "status": "skipped | pending | complete",
    "output_ref": "research.md",
    "approved_by_user": true
  },

  "plan": {
    "status": "skipped | pending | complete",
    "output_ref": "plan.md",
    "approved_by_user": true
  },

  "work_items": [
    {
      "subtask_id": "task-1",
      "status": "pending | in-progress | completed | failed | merged",
      "work_unit_key": "<sha256:16 of run_id:subtask_id:name>",
      "worktree_path": ".trees/task-1",
      "branch": "agent/task-1",
      "builder_attempt": 1,
      "git_commit": "abc1234def",
      "tests_passed": true,
      "validation_status": "pending | approved | rejected",
      "output_summary_ref": "build-log.md#task-1",
      "last_error": null
    }
  ],

  "gametest": {
    "status": "skipped | pending | complete",
    "tests_added_count": 6,
    "all_passed": true,
    "spec_first_review_done": true
  },

  "scenarios": {
    "status": "skipped | pending | complete",
    "scenario_ids": ["charter_stone_creates_village"],
    "all_passed": true,
    "iterations_used": 0
  },

  "review": {
    "status": "skipped | pending | complete",
    "output_ref": "review.md",
    "verdict": "approved | needs-iteration",
    "score": 8
  },

  "pr": {
    "status": "pending | complete",
    "url": "https://github.com/.../pull/76",
    "number": 76,
    "branch": "feature/run-023-slug",
    "merged": false
  },

  "phase_status": {
    "architect_subagent_runs": 1,
    "build_subagent_runs": 4,
    "gametest_subagent_runs": 0,
    "review_subagent_runs": 0
  },

  "iteration_counts": {
    "build_attempts": 0,
    "scenario_loop": 0
  },

  "last_error": null
}
```

## Field rules

- **`version`** — always `"1"` for now. Bump if the schema changes incompatibly. Resumers must reject mismatched versions and ask the user.
- **`parent_run_id`** — null for fresh runs; the prior `run_id` when this run is stacked on top of another (e.g. continuing work in the same PR). Used so the orchestrator can skip-back to read the parent's state if needed.
- **`base_branch`** — the branch worktrees branch off from. `origin/main` for fresh runs; the parent run's feature branch when stacked. Required at run start.
- **`extends_pr`** — null for fresh runs; the PR number when this run extends an existing PR (orchestrator uses the description-refresh pass at the end instead of opening a new PR).
- **`current_phase`** — single source of truth for "where are we?". Always lands in one of the listed values. Never two phases active.
- **`completed_phases`** — append-only as phases finish. Used during resume to skip approved phases.
- **`work_items[].work_unit_key`** — `sha256(run_id + ':' + subtask_id + ':' + subtask_name)[:16]`. Builders receive this and use it as an idempotency token.
- **`work_items[].status`** — `pending` (no worktree) → `in-progress` (worktree created, builder running) → `completed` (builder returned success) → `merged` (branch merged into the run's main feature branch). `failed` is terminal until manually reset.
- **`*.output_ref`** — relative path inside the run dir. The orchestrator never inlines large content here.
- **`phase_status`** — counts how many subagent invocations each phase has consumed. Useful for resume diagnostics and detecting runaway iteration. Not a budget — the orchestrator paces against real-time session-context signals (see SKILL.md "Pace the run against your remaining session context"), not a fixed token budget.

## Write rules

1. **Write only at phase boundaries.** After a phase completes, after a validation gate is passed, after a builder returns. Not after every tool call. Per-phase frequency keeps the file small and bug-free.
2. **Atomic writes.** Write to `state.json.tmp` then `mv` over `state.json`. Never edit in place. Cheap insurance against corrupt state if a run is killed mid-write.
3. **Never delete fields, only update.** Resumers may rely on prior fields. Keep the schema additive across versions of this skill.
4. **One process owns the file at a time.** Parallel builders write to their own `work_items[i]` entries via the orchestrator, not directly. The orchestrator is the single writer.

## Resume protocol

Orchestrator startup, in order:

1. Look for `state.json` in the determined run dir.
2. If missing → fresh start. Initialize with `current_phase: "architect"` (or `"research"` if user opted out of decomposition), `completed_phases: []`, etc.
3. If present and `version` mismatches → halt, ask user what to do.
4. If present and `current_phase == "complete"` → already done. Print summary, exit.
5. Otherwise → fast-forward through `completed_phases`, then resume at `current_phase`. For `build`: each `work_item.status` decides whether to re-run that builder, skip it (already complete), or wait for it (in-progress at last write — likely killed mid-flight; treat as pending unless a recoverable signal exists).

## What does NOT belong in `state.json`

- Full subagent output (write to `*.md` files, reference them).
- Tool call transcripts.
- File diffs (the git history is the source of truth).
- User chat history.
- Build logs longer than a single line summary (write `build-log.md`).

If a field would push `state.json` past ~10 KB, it's probably the wrong place for that data.
