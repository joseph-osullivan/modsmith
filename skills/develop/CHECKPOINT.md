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

  "current_phase": "bootstrap | architect | research | plan | build | doctor | handoff | kick_back | pr | complete",
  "completed_phases": ["bootstrap", "architect", "research", "plan"],

  "preferred_loader": "neoforge",

  "targets_matrix": {
    "layout": "multiloader",
    "common_subproject": ":common",
    "targets": [
      { "loader": "fabric",   "mc_version": "26.1.2", "loader_version": "0.18.6",        "subproject": ":fabric",   "java_toolchain": 25 },
      { "loader": "neoforge", "mc_version": "26.1.2", "loader_version": "26.1.2.7-beta", "subproject": ":neoforge", "java_toolchain": 25 }
    ],
    "java_toolchain": 25,
    "detection_notes": []
  },

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

  "phase_5_doctor_result": {
    "summary": {
      "hard_fail_count": 0,
      "warn_count": 2,
      "passed_count": 14,
      "verdict": "pass | pass_with_warnings | fail"
    },
    "findings": [],
    "ran_at": "2026-05-21T19:32:12Z",
    "targets_json_path": "targets-matrix.json",
    "warnings_logged_at": "2026-05-21T19:32:12Z"
  },

  "phase_6_handoff": {
    "status": "skipped | pending | complete",
    "preferred_loader_used": "neoforge",
    "headless": false,
    "dev_server_started_at": "2026-05-21T19:33:01Z",
    "dev_server_ended_at": "2026-05-21T19:41:33Z",
    "log_watcher_report_path": "runs/neoforge/watcher-report.json",
    "gametest_results": [
      {
        "loader": "neoforge",
        "mc_version": "26.1.2",
        "subproject": ":neoforge",
        "report_path": "runs/neoforge/gametest-results.json",
        "passed": 4,
        "failed": 0,
        "status": "complete"
      },
      {
        "loader": "fabric",
        "mc_version": "26.1.2",
        "subproject": ":fabric",
        "report_path": "runs/fabric/gametest-results.json",
        "passed": 4,
        "failed": 0,
        "status": "complete"
      }
    ],
    "scenario_results": [],
    "reviewer_report_path": "runs/review.json",
    "summary_printed": true
  },

  "kick_back_queue": [],

  "kick_back_history": [
    {
      "iteration": 1,
      "started_at": "2026-05-21T19:42:08Z",
      "ended_at": "2026-05-21T19:48:51Z",
      "bug_report_count": 3,
      "bug_reports": [
        {
          "source": "reviewer",
          "file": "common/src/main/java/.../ShopkeeperTickHandler.java",
          "line": 47,
          "loader": "common",
          "symptom": "NPE when reputation tag is missing on player",
          "suggested_fix": "Default to NEUTRAL tier when tag is absent.",
          "severity": "hard_fail"
        }
      ],
      "builder_output_path": "kick-back/01/builder-output.md",
      "phase_6_rerun_summary": "All 4 gametests green; reviewer verdict: approve",
      "outcome": "address_succeeded"
    }
  ],

  "kick_back_escalation": null,

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
    "review_subagent_runs": 0,
    "log_watcher_subagent_runs": 0
  },

  "iteration_counts": {
    "build_attempts": 0,
    "scenario_loop": 0,
    "kick_back": 0
  },

  "last_error": null
}
```

## Field rules

- **`version`** — always `"1"` for now. Bump if the schema changes incompatibly. Resumers must reject mismatched versions and ask the user.
- **`targets_matrix`** — written once during bootstrap (verbatim from `scripts/detect-targets.sh`). The full set of `(loader, mc_version, loader_version, subproject, java_toolchain)` tuples for the run, plus `layout` and `common_subproject`. Passed to every downstream agent as first-class context (see SKILL.md "Pass the matrix to every downstream agent"). Use `layout` to decide whether `common_subproject` is meaningful (`null` for `single-loader`). The orchestrator does NOT mutate this field after bootstrap; re-running detection during resume should produce the same JSON unless the host project's gradle config changed.
- **`parent_run_id`** — null for fresh runs; the prior `run_id` when this run is stacked on top of another (e.g. continuing work in the same PR). Used so the orchestrator can skip-back to read the parent's state if needed.
- **`base_branch`** — the branch worktrees branch off from. `origin/main` for fresh runs; the parent run's feature branch when stacked. Required at run start.
- **`extends_pr`** — null for fresh runs; the PR number when this run extends an existing PR (orchestrator uses the description-refresh pass at the end instead of opening a new PR).
- **`current_phase`** — single source of truth for "where are we?". Always lands in one of the listed values. Never two phases active.
- **`completed_phases`** — append-only as phases finish. Used during resume to skip approved phases.
- **`work_items[].work_unit_key`** — `sha256(run_id + ':' + subtask_id + ':' + subtask_name)[:16]`. Builders receive this and use it as an idempotency token.
- **`work_items[].status`** — `pending` (no worktree) → `in-progress` (worktree created, builder running) → `completed` (builder returned success) → `merged` (branch merged into the run's main feature branch). `failed` is terminal until manually reset.
- **`*.output_ref`** — relative path inside the run dir. The orchestrator never inlines large content here.
- **`phase_status`** — counts how many subagent invocations each phase has consumed. Useful for resume diagnostics and detecting runaway iteration. Not a budget — the orchestrator paces against real-time session-context signals (see SKILL.md "Pace the run against your remaining session context"), not a fixed token budget.
- **`preferred_loader`** — set by Phase 6 (Handoff) once the orchestrator resolves which loader gets the foreground dev server. Null until Phase 6 picks. Resume reads this so the second visit to Handoff stays on the same loader. `"fabric" | "neoforge" | null`.
- **`phase_5_doctor_result`** — verbatim JSON from the last `doctor.sh --json` run, plus a `ran_at` timestamp and the `targets_json_path` Doctor was invoked against. `summary.verdict` drives the gate decision (see SKILL.md Phase 5). On `pass_with_warnings`, the orchestrator also sets `warnings_logged_at` (timestamp) — the field's presence signals the next phase that warnings were noted without blocking.
- **`phase_6_handoff`** — written during the Handoff phase. `dev_server_started_at` / `dev_server_ended_at` are ISO-8601 timestamps. `log_watcher_report_path`, `reviewer_report_path` are relative paths to the agents' JSON reports. `gametest_results` is an array with one entry per target in `targets_matrix.targets`; each entry mirrors `targets_matrix.targets[i]` plus runtime fields (`passed`, `failed`, `status`). `scenario_results` follows the same shape but is `[]` when no scenario harness exists. `headless: true` when the skill was invoked with `--headless`; in that case `dev_server_started_at` / `dev_server_ended_at` are null. `summary_printed: true` once the orchestrator has rendered the Handoff summary for the player.
- **`kick_back_queue`** — array of bug reports waiting for Phase 7. Each entry: `{source: "doctor" | "reviewer" | "log-watcher" | "gametest", file?, line?, symptom, suggested_fix, severity, work_unit_key?}`. Cleared after Phase 7 consumes it; the iteration counter persists across clears.
- **`iteration_counts.kick_back`** — counts kick-back rounds (Phase 7). Capped at 3; on cap-hit, the orchestrator surfaces the queue to the user instead of looping.
- **`kick_back_history`** — append-only array; one entry per completed kick-back iteration in Phase 7. Each entry captures the **snapshot** of inputs and outputs for that round: `iteration` (1-indexed, mirrors `iteration_counts.kick_back` at the time the round started), `started_at` / `ended_at` (ISO-8601), `bug_report_count`, `bug_reports` (the verbatim queue handed to the builder — frozen for that iteration, not mutated by later rounds), `builder_output_path` (relative path to the builder's return summary saved under `kick-back/NN/`), `phase_6_rerun_summary` (one-line aggregate of the doctor + handoff re-run for this iteration; `"skipped — headless"` when `--headless`), and `outcome` (`"address_succeeded"` = re-run cleared the queue, `"address_partial"` = builder fixed some entries but new findings remain, `"escalated"` = iteration cap hit or builder returned `cannot_fix`). Resume reads this array to determine where to pick up: the length tells the orchestrator how many rounds have already finished; the last entry's `outcome` tells it whether to start a new round or surface the escalation.
- **`kick_back_escalation`** — `null` while the loop is healthy. When the orchestrator escalates (cap hit, `cannot_fix`, or reviewer `verdict == "needs_human"`), this is populated with `{escalated_at, reason, final_queue, recommendation, history_ref: "kick_back_history"}` so the human (or a future resume) has the full snapshot in one place without re-walking the history array.

## `targets_matrix` examples

A single-loader NeoForge repo emits:

```json
"targets_matrix": {
  "layout": "single-loader",
  "common_subproject": null,
  "targets": [
    { "loader": "neoforge", "mc_version": "26.1.2", "loader_version": "26.1.2.43-beta", "subproject": ":", "java_toolchain": 25 }
  ],
  "java_toolchain": 25,
  "detection_notes": []
}
```

If `detect-targets.sh` cannot find a recognized loader plugin, it exits with code 1 and `layout` is `"unknown"` (or `"monolith"` when a `minecraft_version` pin exists without a loader plugin); the orchestrator halts rather than proceeding.

## Example: state.json after a successful Phase 6 (Handoff)

A trimmed slice showing the Doctor result, Handoff payload, empty kick-back queue, and the resolved `preferred_loader`. The PR phase has not yet run, so `current_phase` is `pr` and `pr.status` is `pending`.

```jsonc
{
  "version": "1",
  "run_id": "run-031-shopkeeper-discount",
  "current_phase": "pr",
  "completed_phases": ["bootstrap", "architect", "research", "plan", "build", "doctor", "handoff"],
  "preferred_loader": "neoforge",

  "phase_5_doctor_result": {
    "summary": { "hard_fail_count": 0, "warn_count": 2, "passed_count": 14, "verdict": "pass_with_warnings" },
    "findings": [
      { "check": "pinned-versions-recent", "severity": "warn", "status": "fail",
        "message": "fabric_api 0.145.4 is 4 releases behind 0.149.0", "fix_hint": "bump in gradle.properties" }
    ],
    "ran_at": "2026-05-21T19:32:12Z",
    "targets_json_path": "docs/workflow-runs/031-shopkeeper-discount/targets-matrix.json",
    "warnings_logged_at": "2026-05-21T19:32:12Z"
  },

  "phase_6_handoff": {
    "status": "complete",
    "preferred_loader_used": "neoforge",
    "headless": false,
    "dev_server_started_at": "2026-05-21T19:33:01Z",
    "dev_server_ended_at": "2026-05-21T19:41:33Z",
    "log_watcher_report_path": "runs/neoforge/watcher-report.json",
    "gametest_results": [
      { "loader": "neoforge", "mc_version": "26.1.2", "subproject": ":neoforge",
        "report_path": "runs/neoforge/gametest-results.json", "passed": 4, "failed": 0, "status": "complete" },
      { "loader": "fabric",   "mc_version": "26.1.2", "subproject": ":fabric",
        "report_path": "runs/fabric/gametest-results.json",   "passed": 4, "failed": 0, "status": "complete" }
    ],
    "scenario_results": [],
    "reviewer_report_path": "runs/review.json",
    "summary_printed": true
  },

  "kick_back_queue": [],
  "iteration_counts": { "build_attempts": 1, "scenario_loop": 0, "kick_back": 0 },

  "pr": { "status": "pending", "url": null, "number": null, "branch": "feature/run-031-shopkeeper-discount", "merged": false }
}
```

## Example: state.json after a 1-iteration kick-back cycle

A trimmed slice showing what `state.json` looks like after Phase 7 ran exactly once: the reviewer/log-watcher kicked back a `hard_fail`, the builder addressed it, the doctor + handoff re-ran clean, and the orchestrator advanced to PR. The `kick_back_history` array has one entry; `kick_back_queue` is empty (consumed); `iteration_counts.kick_back` is `1`; `kick_back_escalation` is `null` (the loop resolved happily).

```jsonc
{
  "version": "1",
  "run_id": "run-031-shopkeeper-discount",
  "current_phase": "pr",
  "completed_phases": ["bootstrap", "architect", "research", "plan", "build", "doctor", "handoff", "kick_back", "doctor", "handoff"],
  "preferred_loader": "neoforge",

  "phase_5_doctor_result": {
    "summary": { "hard_fail_count": 0, "warn_count": 2, "passed_count": 14, "verdict": "pass_with_warnings" },
    "findings": [],
    "ran_at": "2026-05-21T19:49:02Z",
    "targets_json_path": "docs/workflow-runs/031-shopkeeper-discount/targets-matrix.json",
    "warnings_logged_at": "2026-05-21T19:49:02Z"
  },

  "phase_6_handoff": {
    "status": "complete",
    "preferred_loader_used": "neoforge",
    "headless": false,
    "dev_server_started_at": "2026-05-21T19:49:11Z",
    "dev_server_ended_at": "2026-05-21T19:54:02Z",
    "log_watcher_report_path": "runs/neoforge/watcher-report.json",
    "gametest_results": [
      { "loader": "neoforge", "mc_version": "26.1.2", "subproject": ":neoforge",
        "report_path": "runs/neoforge/gametest-results.json", "passed": 4, "failed": 0, "status": "complete" },
      { "loader": "fabric",   "mc_version": "26.1.2", "subproject": ":fabric",
        "report_path": "runs/fabric/gametest-results.json",   "passed": 4, "failed": 0, "status": "complete" }
    ],
    "scenario_results": [],
    "reviewer_report_path": "runs/review.json",
    "summary_printed": true
  },

  "kick_back_queue": [],
  "kick_back_history": [
    {
      "iteration": 1,
      "started_at": "2026-05-21T19:42:08Z",
      "ended_at": "2026-05-21T19:48:51Z",
      "bug_report_count": 2,
      "bug_reports": [
        {
          "source": "reviewer",
          "file": "common/src/main/java/.../ShopkeeperTickHandler.java",
          "line": 47,
          "loader": "common",
          "symptom": "NPE when reputation tag is missing on player",
          "suggested_fix": "Default to NEUTRAL tier when tag is absent.",
          "severity": "hard_fail"
        },
        {
          "source": "log-watcher",
          "file": "common/src/main/java/.../ShopkeeperTickHandler.java",
          "line": 47,
          "loader": "common",
          "symptom": "java.lang.NullPointerException: Cannot invoke \"...ReputationTag.tier()\" because the return value is null",
          "suggested_fix": "Same root cause as reviewer's bug_reports[0] (de-duped, see SKILL.md Phase 7 de-dupe rule).",
          "severity": "hard_fail"
        }
      ],
      "builder_output_path": "kick-back/01/builder-output.md",
      "phase_6_rerun_summary": "doctor: pass_with_warnings (2 warns, same as round 0); gametest: 8 pass / 0 fail across both targets; reviewer: approve; log-watcher: 0 hard_fail, 1 warn",
      "outcome": "address_succeeded"
    }
  ],
  "kick_back_escalation": null,

  "iteration_counts": { "build_attempts": 1, "scenario_loop": 0, "kick_back": 1 },

  "pr": { "status": "pending", "url": null, "number": null, "branch": "feature/run-031-shopkeeper-discount", "merged": false }
}
```

Note that `completed_phases` contains `doctor` and `handoff` twice — once for the initial Phase 5/6, once for the re-run after the kick-back. The orchestrator appends them on each successful pass; the array is a log of phase transitions, not a set.

## Write rules

1. **Write only at phase boundaries.** After a phase completes, after a validation gate is passed, after a builder returns. Not after every tool call. Per-phase frequency keeps the file small and bug-free.
2. **Atomic writes.** Write to `state.json.tmp` then `mv` over `state.json`. Never edit in place. Cheap insurance against corrupt state if a run is killed mid-write.
3. **Never delete fields, only update.** Resumers may rely on prior fields. Keep the schema additive across versions of this skill.
4. **One process owns the file at a time.** Parallel builders write to their own `work_items[i]` entries via the orchestrator, not directly. The orchestrator is the single writer.

## Resume protocol

Orchestrator startup, in order:

1. Look for `state.json` in the determined run dir.
2. If missing → fresh start. Initialize with `current_phase: "bootstrap"` (or jump to `"architect"` if Bootstrap already wrote `targets_matrix`), `completed_phases: []`, `preferred_loader: null`, `kick_back_queue: []`, etc.
3. If present and `version` mismatches → halt, ask user what to do.
4. If present and `current_phase == "complete"` → already done. Print summary, exit.
5. Otherwise → fast-forward through `completed_phases`, then resume at `current_phase`. Per-phase resume notes:
   - `build`: each `work_item.status` decides whether to re-run that builder, skip it (already complete), or wait for it (in-progress at last write — likely killed mid-flight; treat as pending unless a recoverable signal exists).
   - `doctor`: re-run `doctor.sh` against the cached `targets_matrix`; compare against `phase_5_doctor_result` to detect regressions vs. fresh failures.
   - `handoff`: read `preferred_loader` so the dev server resumes on the same loader. If the prior run left a stale `runs/<loader>/server.pid`, treat it as a crashed session and proceed to finalize-without-dev-server (the kick-back queue receives the crash finding from the log-watcher).
   - `kick_back`: read `kick_back_history` first (length = how many rounds have already finished, last entry's `outcome` tells you whether the round closed cleanly or escalated). Then read `kick_back_queue`:
     - If `kick_back_escalation` is non-null → the prior session decided to escalate; do not loop. Surface the escalation to the user.
     - Else if `kick_back_queue` is empty AND the last `kick_back_history` entry is `outcome == "address_succeeded"` → the prior session closed cleanly; advance to the next planned phase (typically PR).
     - Else if `kick_back_queue` is non-empty AND `iteration_counts.kick_back < 3` → resume Phase 7 mid-iteration (the prior session was killed mid-round). Use the current queue to spawn the builder.
     - Else (`kick_back_queue` non-empty AND `iteration_counts.kick_back >= 3`) → cap reached; write `kick_back_escalation` and surface to the user.

## What does NOT belong in `state.json`

- Full subagent output (write to `*.md` files, reference them).
- Tool call transcripts.
- File diffs (the git history is the source of truth).
- User chat history.
- Build logs longer than a single line summary (write `build-log.md`).

If a field would push `state.json` past ~10 KB, it's probably the wrong place for that data.
