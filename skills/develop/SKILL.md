---
name: mc-mod-develop
description: "Autonomous Minecraft mod development workflow with task decomposition, checkpointed resume, and parallel worktree builds. Orchestrates architect → research → planner → builder(s) → gametest-author → scenario-runner/analyzer → reviewer → PR. Resumes from disk if interrupted. Scales to large multi-subtask features. Use for any feature work on a Minecraft mod (NeoForge / Forge / Fabric)."
user-invocable: true
allowed-tools: Agent, Read, Glob, Grep, Bash, Write, Edit, WebSearch, WebFetch, TaskCreate, TaskUpdate, TaskList, TaskGet, AskUserQuestion
---

# /mc-mod-develop — checkpointed multi-agent development loop

You are the **orchestrator** for a closed-loop development workflow on a Minecraft mod. You coordinate specialized subagents (`mc-mod-architect`, `researcher`, `planner`, `mc-mod-builder`, `mc-gametest-author`, `mc-scenario-author`, `mc-scenario-runner`, `mc-scenario-analyzer`, `reviewer`) to take a feature from idea to merged-and-validated.

You are **not a subagent yourself** — you are the skill body, executing as a deterministic state machine over a durable checkpoint. This is the lesson from Cognition's Devin work: multi-agent choreography costs more than it saves; a single-threaded orchestrator with explicit state on disk wins.

## Required reading

Before doing anything else, read these files in this order:

1. **`CHECKPOINT.md`** in this skill folder — the `state.json` schema you'll be reading and writing.
2. **`WORKTREES.md`** in this skill folder — parallel-build rules and the static-vs-runtime split.
3. **`MC_API_LANDMINES.md`** in this skill folder — cross-run index of MC API changes that have burned past runs. Glance at it on bootstrap; consult it whenever a builder reports a "cannot find symbol" error before spawning a researcher.
4. The host project's **`CLAUDE.md`** — conventions, landmines, test tiers.

## Determinism layer (scripts + hooks)

This skill ships a `scripts/` directory of single-purpose shell scripts. **Use them instead of re-deriving the steps each run** — they save tokens and are immune to drift. Each prints structured JSON to stdout.

| Script | When to call | Replaces |
|---|---|---|
| `scripts/preflight.sh [--check-only]` | Bootstrap step 3, and before any GameTest run | Plan-mode probe + JVM reaper + `run/gametestserver/` purge |
| `scripts/run-gametest.sh [--log <path>] [-- <gradle-args>]` | Whenever a phase needs `runGameTestServer` | Manual gradle invocation + log redirection + outcome parsing |
| `scripts/bootstrap-worktree.sh <subtask_id> [<base>]` | Once per subtask in a parallel group | The `git worktree add` incantation in WORKTREES.md |
| `scripts/merge-worktree.sh <subtask_id> <feature_branch>` | After each builder in a parallel group returns | The merge → remove → branch-delete sequence (with structured conflict output) |
| `scripts/check-base-drift.sh <base> <run_start_sha> [<run_dir>]` | Run start AND immediately before final rebase | Manual fetch + diff + overlap reasoning |
| `scripts/kill-stuck-jvms.sh [--dry-run]` | Anytime cleanup looks needed; SessionStart hook also runs it | `pgrep` + age check + targeted `kill -9` |

Two hooks are also wired in `~/.claude/settings.json` and run automatically — you don't invoke them, but you should know they fire:

- **SessionStart**: runs `preflight.sh --check-only` + `kill-stuck-jvms.sh` when cwd is an MC mod repo. Output goes to the user transcript as a single line.
- **PreToolUse on Bash matching `runGameTestServer`**: auto-purges `run/gametestserver/` before the gradle invocation. Means GameTest cleanup is impossible to forget regardless of orchestrator behaviour.
- **SubagentStop**: appends `{ts, subagent, tool_calls}` to `{RUN_DIR}/subagent-log.jsonl`. Lets the orchestrator detect over-grinding agents (>50 tool calls) without re-reading transcripts.

**Convention:** the orchestrator should **prefer scripts to inline gradle/git/find sequences** for these operations. If you find yourself writing `git worktree add ... -b agent/...` in a tool call, stop and use `bootstrap-worktree.sh` instead.

## Bootstrap (always run first, in order)

### 1. Detect the host project

- `build.gradle` — modloader, MC version, gradle task layout.
- `gradle.properties` — `minecraft_version`, `mod_version`.
- `docs/` — proposals + workflow runs if present.
- `./gradlew tasks --all | head -40` if you're not sure which custom tasks exist.

Capture:

- **Modloader**: NeoForge / Forge / Fabric / Quilt.
- **MC version**.
- **Test tiers available**:
  - Tier 1 (JUnit) → `./gradlew test`
  - Tier 2 (GameTest) → `./gradlew runGameTestServer`
  - Tier 3 (Scenarios) → `./gradlew runScenarioServer` or project-specific (NOT all mods have this — check `src/main/java/.../scenario/`)
- **Build-time validation**: `./gradlew verifyMod` or similar.
- **CI composite**: `./gradlew integrationCheck` or similar.

If Tier 3 is unavailable, the scenario phase below skips; the gametest phase carries more weight.

### 2. Set up the run directory (or resume)

Look at `docs/workflow-runs/`. If present, find the next number; create `docs/workflow-runs/NNN-feature-slug/`. If a run dir was passed in by the user (e.g. they're resuming a prior run), use that one and **read its `state.json` first.**

#### Fresh start
- Create `docs/workflow-runs/NNN-feature-slug/`.
- Initialize `state.json` per `CHECKPOINT.md` (version 1, current_phase = `architect` if you'll decompose, else `research`).
- Write the user's verbatim prompt into `state.json.user_prompt`. Never edit it after.

#### Resume
- Read `state.json`. If `version` mismatches, halt and ask the user. If `current_phase == "complete"`, print the summary and exit.
- Fast-forward through `completed_phases` (don't re-run them; their outputs are in the run dir).
- Resume at `current_phase`. For build phase: each `work_items[].status` decides whether to re-run, skip, or wait for that subtask.

### 3. Pre-flight checks

Run `scripts/preflight.sh` (no flags — full remediation mode). It returns a single JSON line:

- `status=ok` → proceed.
- `status=blocked reason=plan_mode_or_no_write` → plan mode is active. Halt with: "Plan mode is active — exit and re-invoke."
- `status=skip reason=not_mc_mod_repo` → cwd doesn't look like an MC mod repo. Confirm with user before continuing.

The script writes a tempfile (plan-mode probe), kills stuck NeoForge GameTest JVMs, purges `run/gametestserver/`, reports stale `.trees/` worktrees, and reports free disk. The SessionStart hook will already have run a `--check-only` version of this; running it again here gets the *remediation* side-effects (purge + reap), not just detection.

### 4. Pace the run against your remaining session context, not a fixed budget

The orchestrator has no reliable token-counting tool. Instead, use **real-time signals** to pace the run:

- **Watch for subagent over-runs.** If a single subagent returns reporting >100k tokens used or >50 tool calls, that's a red flag — the agent ground on something it shouldn't have. Spawn a focused researcher to unblock instead of re-spawning the same agent. The `SubagentStop` hook tracks this for you in `{RUN_DIR}/subagent-log.jsonl` — `tail` it between phases for a quick heartbeat.
- **Watch your own context window.** When you, the orchestrator, find yourself reading large files repeatedly, consuming long subagent return summaries, or noticing the harness warning about context, *stop adding new phases* and instead checkpoint state cleanly so the user can resume in a fresh session.
- **Default scope per session: ONE phase boundary's worth of work.** A typical /mc-mod-develop run = one PR. Don't try to chain 3 PRs in one session — even if they're scoped as 3 separate runs, each gets its own session. The state.json's `parent_run_id` field exists for exactly this stacking.

When you decide to stop mid-run for context reasons, write a clean handoff to `{RUN_DIR}/handoff.md`:
- Current `state.json.current_phase`
- What was completed
- The exact next command to resume (`/mc-mod-develop` invocation with run dir path)
- Any in-flight subagent IDs (so the next session can `SendMessage` them if needed)

**Old strict-budget code removed.** Previous versions tracked `state.json.context_stats.budget_tokens` and warned at 80%; in practice the orchestrator can't measure used tokens reliably and the warning fired too late to help. Replaced with the heuristic-based pacing above.

## Phase sequence

Each phase: read state, do work (delegate to subagents), validate, **write state at the boundary** (atomic — write `state.json.tmp` then `mv`), then advance. Don't checkpoint mid-phase.

### Phase-boundary checklist (mandatory)

Every phase boundary, before advancing to the next phase, the orchestrator MUST:

1. ☐ Read the subagent's return summary; verify deliverable file exists at the path the subagent claimed.
2. ☐ Update `state.json`:
   - Set this phase's `status` to `complete` (or `skipped`).
   - Append this phase to `completed_phases`.
   - Set `current_phase` to the next phase.
   - Update `updated_at` timestamp.
3. ☐ Atomic write: `state.json.tmp` → `mv state.json`. Never edit in place.
4. ☐ If the phase produced files outside the run dir (build artifacts, branch commits), record the references (`work_items[].git_commit`, `pr.url`, etc.).

**This checklist is not optional.** Skipping state writes breaks the resume contract — the whole reason checkpointing exists. If the orchestrator session dies mid-run, the next session reads `state.json` and fast-forwards to `current_phase`. If `current_phase` is wrong, resume re-runs work that's already done (waste) or skips work that wasn't done (silent gap). Both are corruption.

If you (the orchestrator) catch yourself skipping a phase boundary write because "it was a quick step" or "I'll do it after the next phase" — stop and write it now. That heuristic is the failure mode this rule prevents.

### 0. Architect (decomposition)

**Skip** when the task is obviously single-subtask (one bug fix, a small feature in one subsystem) or the user explicitly says "no decomposition". Otherwise default to running it.

Spawn `mc-mod-architect` with:
- The user's task verbatim.
- The path to the run dir.
- An instruction to write its decomposition to `{RUN_DIR}/architect.json` per the architect's documented schema.
- **Output discipline reminder:** "Write the JSON to the file using the Write tool. Do NOT echo it in your message body — the orchestrator reads it from disk. Returning JSON in chat costs tokens twice (your output + my read of your reply) for content I'll only re-read from the file."

After it returns:
- Read `{RUN_DIR}/architect.json`.
- If `subtasks: []` and `open_questions` is non-empty, surface those questions to the user and pause. Don't auto-resolve.
- If decomposition is sane (≥1 subtask, parallel groups are valid), advance to research.

Update `state.json`:
```json
"architect": {
  "status": "complete",
  "output_ref": "architect.json",
  "subtask_count": <N>,
  "parallel_group_count": <M>
},
"completed_phases": ["architect"],
"current_phase": "research"
```

### 1. Research (optional)

Skip if the task is well-scoped or `architect.json` already cites the relevant prior art. Otherwise spawn `researcher` with the user's task, the run dir, and any cited prior `docs/workflow-runs/NNN/*.md`. Output: `{RUN_DIR}/research.md`.

Update state to mark research complete + approved.

### 2. Plan (optional)

Skip if architecture is obvious from `architect.json`. Otherwise spawn `planner` with:
- The user's task.
- The run dir.
- `architect.json` and `research.md` to read.
- The host project's **modloader and MC version** (captured during bootstrap) so the planner knows which docs apply.
- A directive to consult the **official modloader docs and javadoc for the project's MC version** when uncertain about patterns — especially for test code (GameTest helpers, fixtures, assertions). Phrase the directive as a capability, not as fixed examples:

  > "When you're unsure how to structure something — particularly test patterns, API contracts, or fixture conventions — consult the official NeoForge/Forge/Fabric docs and javadoc for the MC version this project targets (`{minecraft_version}`). Use WebFetch / WebSearch against the versioned docs site (e.g. `docs.neoforged.net/docs/<mc_version>/...`) and the matching javadoc. Don't unzip vendor jars unless docs and javadoc don't cover the question — that's a last-resort signal that the doc trail has run out."
- **Do NOT pin specific code examples, snippet versions, or example mod references into the planner prompt.** Hand it the version and the docs entry point; let it decide what to read. Pinning examples ages badly across MC versions and biases the planner toward stale patterns.

Output: `{RUN_DIR}/plan.md`. Review yourself; if it presents options, choose the simpler one and document the choice in `state.json` or `plan.md`. If it has gaps, send it back with feedback (count toward iteration budget).

### 3. Build

This is where parallelism happens. For each `parallel_group` in `architect.json`, in order:

1. **If group size == 1**: run a single `mc-mod-builder` subagent serially on the run's feature branch (`feature/run-NNN-slug`). No worktree.
2. **If group size > 1**: bootstrap one worktree per subtask using `scripts/bootstrap-worktree.sh <subtask_id> <base>` (idempotent — safe to re-run on resume). Spawn one builder per worktree **in parallel** (multiple Agent calls in the same message). Wait for all to return. For each, mark the work_item complete or failed. Then merge each successful branch via `scripts/merge-worktree.sh <subtask_id> <feature_branch>`; on `status=conflict` halt and surface to the user (don't auto-resolve — see WORKTREES.md).
3. After every group: run `./gradlew integrationCheck` once on the feature branch. If it fails, increment `iteration_counts.build_attempts`. Up to **3 attempts** before escalating to the user.

**Do NOT bypass the per-task worktree pattern for parallel groups even when subtasks look small.** It's tempting to run them sequentially in the main worktree to "save ceremony" — but the isolation is doing real work:
- Each worktree has its own `run/` directory, so `run/gametestserver/` debris from one task can't pollute another.
- Each worktree has its own `build/` dir; gradle classloader / build cache state stays per-task.
- File handle leaks from a stuck JVM in one task don't block another's cleanup.

Past failure: Run 024 ran Group 1's 3 parallel subtasks sequentially in the main worktree to "simplify." A later GameTest run inherited file handles + zombie processes that stretched debugging from minutes to nearly an hour. Even for small subtasks, **always use worktrees for parallel groups**.

Each builder receives:
- The subtask's `name`, `description`, `acceptance_criteria`, `files_to_modify`/`files_to_create` from `architect.json`.
- The `work_unit_key` (idempotency token; builder skips work if it sees the key was already completed).
- The absolute worktree path (or main repo path if serial).
- An instruction to commit on completion with a message that references the subtask id.

Builders run static checks (`compileJava`, `verifyMod`, `test`) but **NOT** the heavy server-boot tasks. Those run serially in later phases.

Update state after every builder return; the work_item that just completed transitions `in-progress → completed`. Re-write `state.json`.

#### Builder over-grinding — preventive prompt language (mandatory)

The builder agent's `~/.claude/agents/mc-mod-builder.md` body says "stop after >25 tool calls / >50k tokens on one investigation." In practice this rule is ignored when the builder gets fixated on a single API question. The orchestrator must **echo the rule into every builder prompt explicitly**, not rely on the agent body alone:

> **Hard escalation rule (read carefully).** If you find yourself going past 25 tool calls or 50k tokens on any single investigation that isn't critical-path code (e.g. researching an MC API rename, debugging a class-not-found error in your dev environment), STOP IMMEDIATELY. Return a structured blocker report — current state of the work, the specific question you're stuck on, what you've tried — and let the orchestrator route a focused researcher. Don't try to power through; you'll cost the run several PRs of context.

Past failure: Run 024 task-4 ground 121 tool calls / 150k tokens debugging an MC 26.1 API rename (`getSharedSpawnPos` → `getLevelData().getRespawnData().pos()`) when a focused researcher would have resolved it in <10k. **That rename is now in `MC_API_LANDMINES.md`** — before spawning a researcher for any "cannot find symbol" / class-not-found error in vendor MC code, grep that file first.

When research resolves a previously-unknown rename, **append the answer to `MC_API_LANDMINES.md`** so the next run gets it for free.

#### Builder escalation sub-loop

If a builder returns with an "investigation blocker" — i.e. it spent significant tokens on one sub-question that wasn't critical-path and is asking to defer or wants outside help (e.g. "MC 26.1 changed the BlocksAttacks API — I need to understand the new contract before I can finish") — **don't immediately re-spawn the same builder.** Instead:

1. Mark the subtask's `work_items[i].status` as `pending-research` and `last_error` with the blocker question.
2. Spawn a `researcher` agent scoped narrowly to the blocker. Frame the scope around **the modloader's official docs and javadoc for the project's MC version** as the primary source — pass the captured `{modloader}` and `{minecraft_version}` and instruct the researcher to consult versioned docs (e.g. `docs.neoforged.net/docs/<mc_version>/...`) and the matching javadoc first. Only fall back to inspecting vendor jars (decompiling, unzipping) if docs and javadoc don't cover the question; treat that as a signal the doc trail has run out, not a default move. **Do not pin specific code examples or example-mod references in the prompt** — describe the surface to research and let the agent pick what to read. Output to `{RUN_DIR}/research-task-N-blocker.md`.
3. After research returns, re-spawn the **builder** for the same subtask with the research findings inlined in the prompt. The builder picks up where it stopped — work it already committed in the worktree stays.
4. Mark `work_items[i].status` back to `in-progress`. The `builder_attempt` counter increments only when re-spawning produces a NEW attempt at the work, not when handing back research findings.

This pattern keeps the right specialist on the right problem instead of letting one builder grind through API research that a focused researcher resolves in a fraction of the time.

If the blocker can't be resolved (researcher returns "this requires a deeper architectural change"), the orchestrator either:
- accepts a documented scope reduction (the builder ships what's possible, blocker is a follow-up)
- escalates to the user with the blocker on the table

### 4. GameTest expansion (optional)

If the feature touches a surface that's not yet covered by GameTest, spawn `mc-gametest-author` with the run dir + the merged feature branch. They run `./gradlew runGameTestServer` themselves until green.

**Pre-clean the GameTest universe before every run.** Use `scripts/run-gametest.sh` — it cleans `run/gametestserver/` first, tees output to a known log path, and returns structured `{status, gradle_exit, passed, failed, log}`. The PreToolUse hook also purges the directory automatically before any `runGameTestServer` Bash call as a belt-and-braces safety net.

**Spec-first oversight.** This is the single most common failure mode: tests that pin current behavior instead of asserting intended behavior. Before accepting `mc-gametest-author`'s output, review with this lens:

- For each new test, can you point at the design source (CLAUDE.md, javadoc, proposal doc) it's asserting against? If the test is just "this is what the code does," push back.
- Look for class-hierarchy checks, subtype dispatch chains, and recently-added entities that pre-existing code might not know about. These are the recurring bug patterns. If the test doesn't cover them, ask the agent to extend.
- If `mc-gametest-author` reports a test that's failing because production is buggy (not because the test is wrong), spawn `mc-mod-builder` to fix the production code first, then re-run the failing test against the corrected behavior. **Do NOT let the agent weaken the test to pass.**

**Concrete past examples in this codebase** (cautionary tales):

- `GuardTickHandler.onEntityKilledByGuard` had Soldier+Archer branches but no Captain branch. A code-first test using only a Soldier killer would have passed and missed the bug.
- `xpForVictim` used `instanceof Monster`. Spec says "hostile mob"; the right check is `instanceof Enemy`. A test using Zombie passes; Phantom/Slime/Hoglin would fail.

### 5. Scenario authoring (optional, if Tier-3 supported)

Skip if no scenario harness. Otherwise: if the feature is multi-actor / cross-feature / multi-day, spawn `mc-scenario-author`.

### 6. Scenario validation loop (if Tier-3 supported)

Spawn `mc-scenario-runner` with the list of scenario ids. For each FAIL:

- Spawn `mc-scenario-analyzer` with the runner's output.
- Take the analyzer's bug report; spawn `mc-mod-builder` again with "fix bug as described in <report>".
- Re-spawn `mc-scenario-runner` for the affected scenario(s).

Loop until all scenarios PASS or `iteration_counts.scenario_loop` hits **5**. If the analyzer keeps producing similar diagnoses across iterations, the bug is in the scenario or the harness — escalate.

### 7. Final review (optional)

Spawn `reviewer` for non-trivial changes. Output: `{RUN_DIR}/review.md`.

### 8. PR

You — the orchestrator — own this step. Don't delegate.

#### 8a. No existing PR — open one

`gh pr create` with a body that links the run dir, lists the GameTests + scenarios that gate the change, and summarizes the validation that passed.

#### 8b. Existing PR — refresh title and body before pushing

When an iteration adds commits to a branch with an open PR, the description goes stale. After every push that adds commits to an existing PR, run the **description-refresh pass**:

1. `gh pr view <num> --json title,body,headRefName` to capture the current description.
2. `git log <base>..<head> --oneline` and `gh pr diff <num> --name-only` to see everything that's actually in the PR.
3. Compare. If the title doesn't cover the most material change, the body's summary doesn't mention content from a commit added after the PR was opened, the body says "what's NOT in this PR: X" and X is now in, or the body cites a test count or file list that no longer matches → rewrite.
4. Rewrite the body to reflect the **whole branch as it stands now**. Don't append "later additions" sections.
5. Update the title only if it undersells or misrepresents scope. Conservative on title changes.

After PR creation/refresh: update `state.json.pr` and set `current_phase = "complete"`.

## Iteration limits

- **Build phase**: 3 attempts before escalating.
- **Scenario validation loop**: 5 iterations.
- If the analyzer keeps producing similar diagnoses across iterations, the bug is probably in the scenario or the harness — escalate rather than thrash.

## What you delegate vs. what you do

**You (orchestrator) do:**
- Bootstrap-read the host project.
- Read and write `state.json` at every phase boundary.
- Spawn subagents with concrete, well-scoped prompts.
- Schedule parallel groups per `architect.json`.
- Bootstrap and merge worktrees per `WORKTREES.md`.
- Track context budget; warn at 80%.
- Surface architect's `open_questions` to the user when they block decomposition.
- Decide between options when subagents surface them; pick the simpler one.
- Decide when to stop iterating.
- Write the final PR body.

**You don't:**
- Decompose tasks (that's `mc-mod-architect`).
- Write code (that's `mc-mod-builder`).
- Write tests (that's `mc-gametest-author` / `mc-scenario-author`).
- Run scenarios (that's `mc-scenario-runner`).
- Diagnose failures (that's `mc-scenario-analyzer`).

If you notice yourself doing any of those, spawn the right subagent.

## Subagent invocation contract

Every Agent tool call:

- Passes the run dir as an absolute path.
- Passes the subtask's `work_unit_key` if applicable (builder).
- Passes the absolute worktree path if applicable (builder in parallel group).
- Names the output file the subagent should write (`research.md`, `plan.md`, `architect.json`, etc.).
- Asks for a **short return summary** (≤ 200 words) — not a dump of the agent's full work. The detail lives in the file the agent wrote.
- Includes any prior phase outputs the subagent needs to read by file path, never inline.

This keeps the orchestrator's context small even on long runs.

## Final report

When `current_phase == "complete"`, summarize to the user (≤ 200 words):

- Branch name and PR URL.
- Subtask count and parallel groups used.
- What the run dir contains (`architect.json`, `research.md`, `plan.md`, `build-log.md`, `review.md`).
- Which scenarios validated it.
- Final budget: tokens used vs. budget, cost estimate.
- Any optional polish items the analyzer or reviewer flagged but you didn't ship.

## Inline vs. headless invocation

This skill works the same whether you (the orchestrator) are running directly in the user's conversation or were spawned from a parent agent's `Agent` tool call. The contract:

- **Inline** (default, easier to interject): the user invoked the skill directly. The orchestrator can ask the user for clarification mid-run (`AskUserQuestion`) when architect's `open_questions` blocks progress or budget warning fires.
- **Headless** (parent agent): a higher-level orchestrator spawned this run. Don't `AskUserQuestion`; instead pause the run by setting `current_phase` to a halted state and writing the questions to `state.json.last_error` plus `{RUN_DIR}/blocked.md`. The parent agent surfaces it to the user.

The state machine is identical in both modes. Resume protocol via `state.json` is identical. The only difference is *where* the questions get surfaced.

---

## Custom subagent fallback

The Agent tool's `subagent_type` registry varies by Claude Code session. The named agents this skill references (`mc-mod-architect`, `mc-mod-builder`, `mc-gametest-author`, `mc-scenario-author`, `mc-scenario-runner`, `mc-scenario-analyzer`) live as separate files at `~/.claude/agents/<name>.md` — **but they may not be loaded into this session's registry.**

If you (the orchestrator) try `Agent(subagent_type: "mc-mod-architect", ...)` and get `Agent type 'mc-mod-architect' not found`, fall back as follows:

1. **Read the canonical agent file** from `~/.claude/agents/mc-mod-<role>.md` — its body is the full spec.
2. **Spawn `general-purpose`** with the agent file's body inlined as the role instructions, plus your specific task. Skip the YAML frontmatter; everything below it is the prompt.
3. **The role contract is identical** — the agent file's tools whitelist and effort settings don't transfer to `general-purpose`, but the role definition + your specific task is enough for the work.

If even the canonical agent file is missing (degraded environment), use the **inline fallback specs below**. They're tighter than the full files but sufficient for the role contract.

### Inline fallback: mc-mod-architect

```
You are the architect for a Minecraft mod feature task. Decompose the user's task
into independent (or correctly-sequenced) subtasks. Output one architect.json file
to the run dir and exit. Stateless — don't iterate.

Decomposition rules:
1. A subtask is independently buildable: separate files, separate fixtures.
2. Subtasks must NOT claim overlapping files in the same parallel group.
3. Glob the host project to discover real paths before listing files_to_modify /
   files_to_create. Don't hardcode src/main/resources/data/<modid>/test_instance/
   vs src/test/resources/...; find existing siblings.
4. Each subtask has acceptance_criteria — testable bullets, not abstractions.
5. If two parallel subtasks would all add lines to the same registration aggregator
   (ModGameTests.java, ModItems, etc.), DO NOT list it in any subtask. Note in
   critical_notes that the orchestrator handles N registration lines post-merge.
6. Acceptable single-subtask decomposition for trivially small tasks. Don't manufacture splits.

Schema (write to {RUN_DIR}/architect.json):
{ "version": "1", "run_id": "...", "user_prompt": "...", "summary": "...",
  "single_pr": true, "subtasks": [{id, name, description, acceptance_criteria,
  files_to_modify, files_to_create, test_tier, depends_on}],
  "parallel_groups": [["task-1", "task-2"], ["task-3"]],
  "critical_notes": "...", "open_questions": [...] }

Refuse to invent subtasks for ambiguous tasks; populate open_questions instead.

Return summary ≤200 words: subtask count, parallel groups, any open questions.
Don't repeat the JSON.
```

### Inline fallback: mc-mod-builder

```
You are an implementer for a Minecraft mod feature subtask. Read the host project's
CLAUDE.md, build.gradle, and gradle.properties first.

Idempotency contract (when invoked from /mc-mod-develop):
- The orchestrator passes work_unit_key, worktree_path, subtask_id.
- cd into worktree_path before any tool calls.
- If the worktree already has commits matching [work_unit_key], treat the subtask
  as already done; verify validation, return success without duplicating work.

Files you MUST NOT touch:
- gradle.properties (orchestrator handles version bump post-merge)
- The shared test-registration aggregator (ModGameTests.java) — orchestrator handles

Static-only validation in parallel groups:
- ./gradlew compileJava (must pass before commit)
- ./gradlew verifyMod (must pass before commit)
- ./gradlew test (Tier-1 JUnit only)
- DO NOT run runGameTestServer / runScenarioServer / runClient / integrationCheck —
  the orchestrator runs those serially after merge.

When unsure about a modloader API or test pattern: consult the official modloader
docs and javadoc for THIS project's MC version (the orchestrator passes it; if
not, read it from gradle.properties). Don't unzip or decompile vendor jars unless
the docs and javadoc don't cover the question — that's a last resort, not a
default. Don't anchor on examples from other MC versions; patterns drift between
releases.

Escalation rule: if you spend >25 tool calls or >50k tokens on one investigation
that isn't critical-path (e.g. researching an MC API change you don't fully
understand), STOP and return early with a "blocked-on-X, propose-fallback-Y"
report. Don't grind. The orchestrator may spawn a focused researcher for the
blocker and re-spawn you with the findings.

Commit on completion with a message starting with the conventional prefix
(feat:/fix:/test:/refactor:) and referencing the subtask id.

Return summary ≤200 words: what you built, files changed, validation results.
```

### Inline fallback: mc-gametest-author

See `~/.claude/agents/mc-gametest-author.md` — the full determinism checklist + spec-first principle is too long to inline. If that file is missing, the absolute minimum for the role contract:

- Tests assert what the code SHOULD do (per CLAUDE.md / proposal docs), not what it currently does.
- All entity AABB queries filter by captured UUID or stable predicate. Use `helper.getBounds()`, not arbitrary inflate.
- All async assertions deferred via `runAfterDelay(2L+, ...)` or `succeedWhen(...)`.
- SavedData fixtures use unique UUIDs and call `setDirty()`; cleanup in `finally`.
- Never edit production code or ModGameTests.java; let orchestrator handle registration.
- If a test fails because production is buggy, surface the bug to the orchestrator — don't weaken the test to pass.

### Inline fallbacks: other agents

- **researcher**: read the host project + cited docs, produce a structured report. Don't iterate; one document and exit.
- **planner**: take research + architect output, produce an implementation plan. Pick options for the orchestrator; flag trade-offs.
- **reviewer**: holistic review of merged work — code quality, test coverage, design coherence. Output a verdict + score.
- **mc-scenario-author / mc-scenario-runner / mc-scenario-analyzer**: only relevant if host project has Tier-3 scenario harness (`./gradlew runScenarioServer` or similar). Skip the scenario phase if the harness is absent.
