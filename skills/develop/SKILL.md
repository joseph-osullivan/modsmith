---
name: develop
description: "Use for ANY feature, bug-fix, refactor, or test work on a Minecraft mod (NeoForge / Fabric — single-loader, multi-loader, or multi-MC repos). Lane 1 (default): branch → failing test → fix → gate → PR, no ceremony. Lane 2 (opt-in, for genuinely multi-subsystem features): architect decomposition, parallel worktree builders, checkpointed resume, dev-server handoff."
when_to_use: "Any request to add, fix, refactor, or test code in a Minecraft mod repo — 'add a feature', 'fix this bug', 'write a GameTest', 'port to a new MC version'. Invoke BEFORE writing code."
user-invocable: true
allowed-tools: Agent, Read, Glob, Grep, Bash, Write, Edit, WebSearch, WebFetch, TaskCreate, TaskUpdate, TaskList, TaskGet, AskUserQuestion
---

# /modsmith:develop — two-lane development workflow

Two lanes. **Lane 1 is the default** and covers almost all work: one
coherent change, one branch, one PR, tests as the gate, no run directory,
no checkpoint file. **Lane 2** is the orchestrated machine — architect
decomposition, parallel builders in worktrees, durable `state.json`,
dev-server handoff — and is **opt-in only** for tasks that genuinely
decompose into 3+ independent subtasks.

Why this shape: the checkpoint-everything design was built for long
multi-subtask runs, but field history across two dozen archived runs
shows the ceremony cost more than it saved for typical work — state files
rotted into lies while plain branch→test→PR loops shipped fine. A state
file nobody resumes from is not a checkpoint, it's a liability. Lane 2
keeps the machinery for the tasks that need it (its parallel builders
demonstrably paid off only on zero-file-overlap decompositions); Lane 1
legitimizes what works.

**Design principles (apply to any change to this skill or its agents):**

- The acceptance criteria: *a future mid-tier-model session codes faster
  here and makes fewer mistakes.* For every mechanism ask: does it earn
  its ceremony? and does it age well across MC/loader version jumps, or
  decay into stale, actively-misleading facts?
- Tooling that **executes** (verify rules, scripts, hooks, tests) rots
  loudly — it breaks and gets fixed. Tooling that **instructs** (prose,
  landmine entries, state files) rots silently — it keeps sounding
  authoritative after it stops being true. Prefer executing form; give
  instructing form a staleness signal.
- **Pilot before codify:** process changes ship only after a real-work
  pilot.

## Lane selection

- **Lane 1** unless told otherwise. A bug fix, a feature in one or two
  subsystems, a test batch, a refactor — all Lane 1, even when they touch
  many files.
- **Lane 2** when the user explicitly asks for decomposition/parallelism,
  or when your read of the task finds **3+ subtasks with disjoint files
  that would genuinely proceed in parallel** — in which case *propose*
  Lane 2 with the subtask sketch and let the user confirm. Never silently
  escalate. **Admission test:** the architect must be able to write a
  zero-file-overlap (or provably disjoint-method) ownership plan per
  builder; if it can't, Lane 1. Budget the post-merge wiring step
  (deferred aggregator registration means builders can't run their own
  GameTests) as a real gate.
- Mid-Lane-1 discovery that the task is bigger than scoped → stop, say
  so, propose either a scope cut (ship the coherent core) or a Lane 2
  restart.

In Lane 2 you are the **orchestrator** for a closed-loop workflow,
coordinating the plugin's specialized subagents (`modsmith-architect`,
`modsmith-builder`, `modsmith-gametest-author`, `modsmith-scenario-author`,
`modsmith-scenario-runner`, `modsmith-scenario-analyzer`,
`modsmith-log-watcher`, `modsmith-reviewer`) as a deterministic state
machine over a durable checkpoint — single-threaded orchestration with
explicit state on disk, never free-form multi-agent choreography.

## Required reading

Before doing anything else, read these files in this order:

1. **`references/landmines.md`** (plugin root) — cross-run index of MC API changes that have burned past runs. Glance at it on bootstrap; consult it whenever a "cannot find symbol" error appears, before spawning a researcher.
2. The host project's **`CLAUDE.md`** — conventions, landmines, test tiers. Fresh modsmith scaffolds ship one. If the host project has none, don't dead-end: take conventions from `agents/builder.md` and `references/`, default the version-bump rule to a patch bump, and note the absence in the PR body.
3. *(Lane 2 only)* **`CHECKPOINT.md`** in this skill folder — the `state.json` schema you'll be reading and writing.
4. *(Lane 2 only)* **`WORKTREES.md`** in this skill folder — parallel-build rules and the static-vs-runtime split.

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

The plugin's `hooks/hooks.json` wires these hooks to run automatically — you don't invoke them, but you should know they fire:

- **SessionStart**: runs `preflight.sh --check-only` + `kill-stuck-jvms.sh` when cwd is an MC mod repo. Output goes to the user transcript as a single line.
- **PreToolUse on Bash matching `runGameTestServer`**: auto-purges `run/gametestserver/` before the gradle invocation. Means GameTest cleanup is impossible to forget regardless of orchestrator behaviour.
- **SubagentStop**: appends `{ts, subagent, tool_calls}` to `{RUN_DIR}/subagent-log.jsonl`. Lets the orchestrator detect over-grinding agents (>50 tool calls) without re-reading transcripts.

**Convention:** the orchestrator should **prefer scripts to inline gradle/git/find sequences** for these operations. If you find yourself writing `git worktree add ... -b agent/...` in a tool call, stop and use `bootstrap-worktree.sh` instead.

## Bootstrap (both lanes, always run first, in order)

### 1. Detect the host project

#### 1a. Detect the target matrix (loaders × MC versions)

Modsmith supports both **single-loader** repos (one root `build.gradle` applies `net.fabricmc.fabric-loom` *or* `net.neoforged.moddev`) and **multi-loader** repos (MultiLoader-Template-style `common/` + `fabric/` + `neoforge/` subprojects). The bootstrap detects which shape the host project has by calling a deterministic script and treats the output as the canonical target matrix for the run.

Resolve the plugin install root and invoke the script:

```bash
# CLAUDE_PLUGIN_ROOT is authoritative — Claude Code sets it when the skill
# executes inside an installed plugin (for locally-linked installs it points
# at the symlink target, i.e. the modsmith repo).
MODSMITH_DIR="$CLAUDE_PLUGIN_ROOT"
bash "$MODSMITH_DIR/scripts/detect-targets.sh"
```

If `CLAUDE_PLUGIN_ROOT` is **unset** (legacy / direct skill invocation), do
NOT derive the root from `$0` — snippets here run via the Bash tool, where
`$0` is the shell binary, so a `$(dirname "$0")/..` walk-up resolves to an
unrelated directory. Instead substitute the plugin checkout path you
already know (the directory containing this SKILL.md, two levels up), or
probe upward from the SKILL.md location for the marker file
`scripts/detect-targets.sh`. If neither works, fail loudly and ask the
user for the plugin path — never guess.

The script emits a single JSON document with the schema documented in `scripts/detect-targets.sh` and `CHECKPOINT.md` (the `targets` / `layout` fields). Example:

```jsonc
{
  "layout": "multiloader",            // "multiloader" | "single-loader" | "monolith" | "unknown"
  "common_subproject": ":common",     // null when single-loader
  "targets": [
    { "loader": "fabric",   "mc_version": "26.1.2", "loader_version": "0.18.6",          "subproject": ":fabric",   "java_toolchain": 25 },
    { "loader": "neoforge", "mc_version": "26.1.2", "loader_version": "26.1.2.7-beta",   "subproject": ":neoforge", "java_toolchain": 25 }
  ],
  "java_toolchain": 25,
  "detection_notes": []
}
```

Interpret the script's exit code:

- `exit 0` → at least one target detected. **Lane 1:** there is no run dir and no `state.json` — keep the matrix in your working context for the rest of the run (and paste it verbatim into any subagent prompt, per 1b). **Lane 2:** persist the entire JSON document as the `targets_matrix` field in `state.json` (see CHECKPOINT.md). In both lanes, use the `targets` array, `common_subproject`, `layout`, and `java_toolchain` fields as first-class context throughout the run.
- `exit 1` → `layout == "unknown"` (or `monolith` with no recognized loader plugin). Halt and surface the `detection_notes` to the user — this skill needs a recognizable loader.

#### 1b. Pass the matrix to every downstream agent

Every subsequent agent invocation (architect, builder, gametest-author, scenario-author, scenario-runner, scenario-analyzer, log-watcher, reviewer) MUST receive — as first-class context in the initial prompt — the matrix the script emitted. Concretely, include in each Agent invocation prompt:

- `layout` (string) — so the agent knows whether it can write to `common/` or only to one subproject.
- `common_subproject` (string-or-null) — only meaningful when `layout == "multiloader"`.
- `targets` (array) — the full list of `(loader, mc_version, loader_version, subproject, java_toolchain)` tuples. Architects use it to tag work units `scope=common | fabric-only | neoforge-only`. Builders use the `subproject` to know which Gradle path their work lives under (`:` for single-loader, `:fabric` / `:neoforge` for multi-loader). Gametest/scenario runners fan out over the targets.
- `java_toolchain` (int-or-null) — top-level toolchain hint; per-target toolchain may differ in mixed-MC-version matrices.

Pass these as a structured block at the top of each Agent prompt under a heading like `## Target matrix (read first)`. **Do not paraphrase the JSON** — paste it verbatim so agents can parse it deterministically if they need to.

#### 1c. Other capture work (still needed)

In addition to the matrix, also capture from the host project:

- `docs/` — proposals + workflow runs if present.
- `./gradlew tasks --all | head -40` if you're not sure which custom tasks exist.
- **Test tiers available**:
  - Tier 1 (JUnit) → `./gradlew test` (or `./gradlew :common:test` in multi-loader)
  - Tier 2 (GameTest) → `./gradlew runGameTestServer` (or per-subproject `./gradlew :neoforge:runGameTestServer`)
  - Tier 3 (Scenarios) → `./gradlew runScenarioServer` or project-specific (NOT all mods have this — check `src/main/java/.../scenario/`)
- **Build-time validation**: `./gradlew verifyMod` or similar.
- **CI composite**: `./gradlew integrationCheck` or similar.

If Tier 3 is unavailable, the scenario phase below skips; the gametest phase carries more weight.

### 2. (Lane 2 only) Set up the run directory (or resume)

Lane 1 skips this step entirely — no run dir, no `state.json`; the branch
and the PR body are the run record.

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
- `status=skip reason=not_mc_mod_repo` → cwd doesn't look like an MC mod repo. Interactive: confirm with the user before continuing. Headless (no user to ask): if the repo is *demonstrably* an MC mod repo — `gradle.properties` declares `minecraft_version` (or a loader version), a loader plugin appears in a build file, or loader subprojects exist — record the skip and your evidence in the PR body's Deviations / Surprises section and proceed; otherwise halt.

The script writes a tempfile (plan-mode probe), kills stuck NeoForge GameTest JVMs, purges `run/gametestserver/`, reports stale `.trees/` worktrees, and reports free disk. The SessionStart hook will already have run a `--check-only` version of this; running it again here gets the *remediation* side-effects (purge + reap), not just detection.

### 4. (Lane 2 only) Pace the run against your remaining session context, not a fixed budget

The orchestrator has no reliable token-counting tool. Instead, use **real-time signals** to pace the run:

- **Watch for subagent over-runs.** If a single subagent returns reporting >100k tokens used or >50 tool calls, that's a red flag — the agent ground on something it shouldn't have. Spawn a focused researcher to unblock instead of re-spawning the same agent. The `SubagentStop` hook tracks this for you in `{RUN_DIR}/subagent-log.jsonl` — `tail` it between phases for a quick heartbeat.
- **Watch your own context window.** When you, the orchestrator, find yourself reading large files repeatedly, consuming long subagent return summaries, or noticing the harness warning about context, *stop adding new phases* and instead checkpoint state cleanly so the user can resume in a fresh session.
- **Default scope per session: ONE phase boundary's worth of work.** A typical Lane 2 run = one PR. Don't try to chain 3 PRs in one session — even if they're scoped as 3 separate runs, each gets its own session. The state.json's `parent_run_id` field exists for exactly this stacking.

When you decide to stop mid-run for context reasons, write a clean handoff to `{RUN_DIR}/handoff.md`:
- Current `state.json.current_phase`
- What was completed
- The exact next command to resume (`/modsmith:develop` invocation with run dir path)
- Any in-flight subagent IDs (so the next session can `SendMessage` them if needed)

**Old strict-budget code removed.** Previous versions tracked `state.json.context_stats.budget_tokens` and warned at 80%; in practice the orchestrator can't measure used tokens reliably and the warning fired too late to help. Replaced with the heuristic-based pacing above.

# Lane 1 — the default loop

You do the work yourself. Spawn a subagent only when a bounded piece is
genuinely delegable (e.g. `modsmith-gametest-author` for a batch of tests
on a surface you've already fixed) — never as ceremony.

1. **Branch** from the default branch: `fix/<slug>` or `feat/<slug>`. One
   coherent change per branch.
2. **Red first.** For a bug: write the test that reproduces it at the
   cheapest tier that can express it, and watch it fail with the failure
   you predicted — a red run that fails for the *predicted reason* is the
   evidence the test pins the bug. For a feature: acceptance tests
   alongside the code is fine; red-first where the surface allows.
   **Verify the premise first** when the fix traces to a documented
   "known gap" or landmine entry: probe or red-test the claim before
   writing production code — documented reasoning goes stale even within
   one MC version.
3. **Fix / build.** Follow host conventions and the multi-loader scope
   rules (common vs per-loader — same rules as `agents/builder.md`).
   Extract decision logic into pure functions where that makes Tier-1
   coverage possible — that pattern compounds.
4. **Gate.** Run the heaviest pre-merge tier the repo actually has —
   key it on the capabilities captured in Bootstrap 1c, not on a fixed
   command list: `integrationCheck` if it exists; else `check` +
   `runGameTestServer` (per-target `:loader:check` in multiloader
   repos); else plain `check`/`build`. If no GameTest tier exists, say
   so in the PR body rather than skipping silently. Run
   `scripts/doctor.sh` when the change touches loader plumbing; doctor
   `verdict=fail` **blocks the PR** unless each `hard_fail` is verified
   false or pre-existing against the working tree and documented in the
   Deviations / Surprises section. Flaky-looking failure? Re-run before
   believing it; if it IS flaky and load-bearing, root-cause it now or
   file it visibly — never normalize a red gate.
5. **Version bump** per host convention, assigned at merge time from the
   default branch's current stream — never at plan time. Assert new !=
   old.
6. **PR.** You own the body: what broke and the failure scenario, what
   changed, red→green evidence, behavior changes a reviewer should
   eyeball, known gaps, and a mandatory **"Deviations / Surprises"**
   section — the plan-vs-reality confession is the highest-signal
   artifact in the field record. **The PR is the checkpoint. Never merge
   it yourself; never push the default branch.** If the repo has no
   GitHub remote (or `gh` is unavailable), write the full PR body — same
   mandatory sections — to `PR_BODY.md` at the repo root, commit it on
   the branch, tell the user, and stop: the branch plus the body file
   are the checkpoint.
7. **Iterating on an open PR**: fix on the same branch; after any push
   that adds commits, refresh the PR title/body to describe the whole
   branch as it now stands.

No run dir, no `state.json`, no handoff files. If the session dies, the
branch + PR (or the diff on disk) carry the state.

**Escalation guard (applies to you too):** >25 tool calls or >50k tokens
on one non-critical-path investigation — stop, grep
`references/landmines.md`, probe with `scripts/symbol-check.sh`, or spawn
ONE focused researcher. Don't grind.

## Evidence rules (Lane 1)

Distilled from the archived-run record — the failure classes no compile
gate catches:

- **Runtime semantics need runtime evidence.** The costliest field bugs
  all compiled clean: hooks that never fire, silently-degraded calls,
  patch-gated vanilla paths. Any claim of the form "vanilla hook X fires
  for entity/path Y" must cite the decompiled source (file:line) or ship
  a GameTest through the REAL trigger path in the same PR. An API spike
  that only compiles is not a spike — log actual returned values.
- **Visual surfaces need a visual pass.** New/changed item, block,
  screen, or renderer → `runClient`, hold it / place it / open it,
  before the PR. No compile gate or headless GameTest sees an invisible
  item.
- **A validation item counts only if automated or executed with recorded
  output.** Anything else is labeled UNVERIFIED in the PR body.
  (Unexecuted manual test scripts map 1:1 to post-approval bugs in the
  field record.)
- **Artifact citations, not confidence percentages.** Claims about
  vanilla assets, API behavior, or the host codebase cite a jar listing,
  decompiled file:line, or repo grep — or are labeled speculation.
- **Risk note for unverified API surfaces**: a few lines in the first
  commit — risk, detection command, pre-authorized fallback. A risk
  without a detection command and fallback is a wish.
- **Feed the landmine index in the same PR**: any bug whose fix cites
  decompiled source gets a `references/landmines.md` entry before merge.
- **No orphan pitfalls**: every research pitfall and DoD/checklist item
  traces to an implementation step, an automated check, or an explicit
  one-line rejection.
- A review verdict (yours or an agent's) **records the reviewed SHA**;
  if HEAD moves before merge, append a delta note or re-review the diff.

## Stacked PRs under squash-merge (both lanes)

Avoid stacking when a sequential pair of PRs would do. When you do stack:
declare merge order in BOTH bodies; merge bottom-first (enable
"Automatically delete head branches" so children auto-retarget); after a
parent squash-merges, immediately rebase each child onto the default
branch dropping the squashed commits, and verify the resulting tree is
byte-identical to the tested one before force-pushing.

---

# Lane 2 — orchestrated decomposition (opt-in)

Everything from here to the end of this file is Lane 2's machine.

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

### Phase numbering at a glance

```
0. Bootstrap   — detect host project, emit targets matrix, set up run dir
1. Architect   — decompose task; also emit play-expectations.json for the watcher
2. Research    — optional, only if novel APIs / blockers
3. Plan        — optional, only if architecture isn't obvious
4. Build       — common first, then per-loader builders (in worktrees)
5. Doctor gate — block on hard_fail; route failures as kick-back
6. Handoff     — foreground dev server + background log-watcher / gametest / reviewer
7. Kick-back   — reviewer/log-watcher findings routed back into Build (cap = 3)
8. PR          — orchestrator-owned; opens or refreshes existing PR
```

Phases 5 and 6 collectively replace the previous serial `GameTest → Scenario → Review` triptych: doctor is now a hard gate, and the dev-server handoff in Phase 6 runs gametest, scenario, log-watcher, and reviewer concurrently behind a foreground play-test session. See the per-phase sections below for full mechanics.

### 0. Bootstrap

Already documented in the **Bootstrap (always run first, in order)** section above. The phase number here exists so resume / state-machine logic can refer to "Phase 0" uniformly. Bootstrap covers: target-matrix detection (`scripts/detect-targets.sh`), run-dir creation or resume, preflight checks, pacing setup. State writes for Bootstrap happen at the boundary into Phase 1.

### 1. Architect (decomposition)

**Skip** when the task is obviously single-subtask (one bug fix, a small feature in one subsystem) or the user explicitly says "no decomposition". Otherwise default to running it.

Spawn `modsmith-architect` with:
- The user's task verbatim.
- The path to the run dir.
- An instruction to write its decomposition to `{RUN_DIR}/architect.json` per the architect's documented schema.
- An instruction to **also emit `{RUN_DIR}/play-expectations.json`** — the per-feature spec the log-watcher consumes in Phase 6 (see `references/log-watcher-rules.md` and `agents/log-watcher.md` for the schema). The architect derives `should_see` / `should_not_see` patterns from the feature work units; when a `should_see` pattern presupposes a log line the builder needs to add, the architect must call that out in the corresponding subtask's `acceptance_criteria` so the builder includes the `LOGGER.info(...)` call.
- **Output discipline reminder:** "Write the JSON files to disk using the Write tool. Do NOT echo them in your message body — the orchestrator reads them from disk. Returning JSON in chat costs tokens twice (your output + my read of your reply) for content I'll only re-read from the file."

After it returns:
- Read `{RUN_DIR}/architect.json`.
- Read `{RUN_DIR}/play-expectations.json` (if absent: warn but continue — the watcher will fall back to universal baselines only).
- If `subtasks: []` and `open_questions` is non-empty, surface those questions to the user and pause. Don't auto-resolve.
- If decomposition is sane (≥1 subtask, parallel groups are valid), advance to research.

Update `state.json`:
```json
"architect": {
  "status": "complete",
  "output_ref": "architect.json",
  "play_expectations_ref": "play-expectations.json",
  "subtask_count": <N>,
  "parallel_group_count": <M>
},
"completed_phases": ["bootstrap", "architect"],
"current_phase": "research"
```

### 2. Research (optional)

Skip if the task is well-scoped or `architect.json` already cites the relevant prior art. Otherwise spawn `researcher` with the user's task, the run dir, and any cited prior `docs/workflow-runs/NNN/*.md`. Output: `{RUN_DIR}/research.md`.

Update state to mark research complete + approved.

### 3. Plan (optional)

Skip if architecture is obvious from `architect.json`. Otherwise spawn `planner` with:
- The user's task.
- The run dir.
- `architect.json` and `research.md` to read.
- The host project's **modloader and MC version** (captured during bootstrap) so the planner knows which docs apply.
- A directive to consult the **official modloader docs and javadoc for the project's MC version** when uncertain about patterns — especially for test code (GameTest helpers, fixtures, assertions). Phrase the directive as a capability, not as fixed examples:

  > "When you're unsure how to structure something — particularly test patterns, API contracts, or fixture conventions — consult the official NeoForge/Forge/Fabric docs and javadoc for the MC version this project targets (`{minecraft_version}`). Use WebFetch / WebSearch against the versioned docs site (e.g. `docs.neoforged.net/docs/<mc_version>/...`) and the matching javadoc. Don't unzip vendor jars unless docs and javadoc don't cover the question — that's a last-resort signal that the doc trail has run out."
- **Do NOT pin specific code examples, snippet versions, or example mod references into the planner prompt.** Hand it the version and the docs entry point; let it decide what to read. Pinning examples ages badly across MC versions and biases the planner toward stale patterns.

Output: `{RUN_DIR}/plan.md`. Review yourself; if it presents options, choose the simpler one and document the choice in `state.json` or `plan.md`. If it has gaps, send it back with feedback (count toward iteration budget).

### 4. Build

This is where parallelism happens. For each `parallel_group` in `architect.json`, in order:

1. **If group size == 1**: run a single `modsmith-builder` subagent serially on the run's feature branch (`feature/run-NNN-slug`). No worktree.
2. **If group size > 1**: bootstrap one worktree per subtask using `scripts/bootstrap-worktree.sh <subtask_id> <base>` (idempotent — safe to re-run on resume). Spawn one builder per worktree **in parallel** (multiple Agent calls in the same message). Wait for all to return. For each, mark the work_item complete or failed. Then merge each successful branch via `scripts/merge-worktree.sh <subtask_id> <feature_branch>`; on `status=conflict` halt and surface to the user (don't auto-resolve — see WORKTREES.md).
3. After every group: run `./gradlew integrationCheck` once on the feature branch. If it fails, increment `iteration_counts.build_attempts`. Up to **3 attempts** before escalating to the user.

**Do NOT bypass the per-task worktree pattern for parallel groups even when subtasks look small.** It's tempting to run them sequentially in the main worktree to "save ceremony" — but the isolation is doing real work:
- Each worktree has its own `run/` directory, so `run/gametestserver/` debris from one task can't pollute another.
- Each worktree has its own `build/` dir; gradle classloader / build cache state stays per-task.
- File handle leaks from a stuck JVM in one task don't block another's cleanup.

Past failure: a field run executed a group's 3 parallel subtasks sequentially in the main worktree to "simplify." A later GameTest run inherited file handles + zombie processes that stretched debugging from minutes to nearly an hour. Even for small subtasks, **always use worktrees for parallel groups**.

Each builder receives:
- The subtask's `name`, `description`, `acceptance_criteria`, `files_to_modify`/`files_to_create` from `architect.json`.
- The `work_unit_key` (idempotency token; builder skips work if it sees the key was already completed).
- The absolute worktree path (or main repo path if serial).
- An instruction to commit on completion with a message that references the subtask id.

Builders run static checks (`compileJava`, `verifyMod`, `test`) but **NOT** the heavy server-boot tasks. Those run serially in later phases.

Update state after every builder return; the work_item that just completed transitions `in-progress → completed`. Re-write `state.json`.

#### Builder over-grinding — preventive prompt language (mandatory)

The builder agent's body (`agents/builder.md`) says "stop after >25 tool calls / >50k tokens on one investigation." In practice this rule is ignored when the builder gets fixated on a single API question. The orchestrator must **echo the rule into every builder prompt explicitly**, not rely on the agent body alone:

> **Hard escalation rule (read carefully).** If you find yourself going past 25 tool calls or 50k tokens on any single investigation that isn't critical-path code (e.g. researching an MC API rename, debugging a class-not-found error in your dev environment), STOP IMMEDIATELY. Return a structured blocker report — current state of the work, the specific question you're stuck on, what you've tried — and let the orchestrator route a focused researcher. Don't try to power through; you'll cost the run several PRs of context.

Past failure: a field-run builder ground 121 tool calls / 150k tokens debugging an MC 26.1 API rename (`getSharedSpawnPos` → `getLevelData().getRespawnData().pos()`) when a focused researcher would have resolved it in <10k. **That rename is now in `references/landmines.md`** — before spawning a researcher for any "cannot find symbol" / class-not-found error in vendor MC code, grep that file first.

When research resolves a previously-unknown rename, **append the answer to `references/landmines.md`** so the next run gets it for free.

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

#### Multi-MC build ordering (when `layout == "multiloader-multi-mc"`)

The single-MC ordering above ("common builder runs first, then loader builders in parallel after common merge") generalises to **three stages** when the host repo has per-MC overlays under `versions/<mc>/`. The architect's work-unit scopes drive the staging:

- `scope: top-common` → Stage **4a** (top-level `common/`, shared across every MC line).
- `scope: per-mc-common` → Stage **4b** (one builder per MC line, writes to `versions/<mc>/common/`).
- `scope: per-mc-fabric` / `scope: per-mc-neoforge` → Stage **4c** (one builder per `(MC, loader)` pair, writes to `versions/<mc>/<loader>/`).

```
              ┌──────────────────────────────────────┐
              │ Stage 4a — top-common builder        │
              │ (1 builder, sequential)              │
              │ scope=top-common work units          │
              │ writes to: common/                   │
              └──────────────────────┬───────────────┘
                                     │ merge to working branch
                                     ▼
        ┌────────────────────────────┴────────────────────────────┐
        │ Stage 4b — per-MC common builders (parallel)            │
        │ (one builder per MC version in the matrix)              │
        │ scope=per-mc-common work units, grouped by mc_version   │
        │ writes to: versions/<mc>/common/                        │
        └───┬──────────────────────┬──────────────────────────┬───┘
            │ MC 1.21.1 builder    │ MC 26.1.2 builder        │ ...
            │ writes to versions/  │ writes to versions/      │
            │ 1.21.1/common/       │ 26.1.2/common/           │
            └──────────────────────┴──────────────────────────┘
                                     │ all merge to working branch
                                     ▼
        ┌────────────────────────────┴────────────────────────────┐
        │ Stage 4c — per-MC loader builders (parallel)            │
        │ (one builder per MC × loader pair in the matrix)        │
        │ scope=per-mc-fabric / per-mc-neoforge, grouped by       │
        │   (mc_version, loader)                                  │
        │ writes to: versions/<mc>/<loader>/                      │
        └──┬───────────────┬────────────────┬───────────────┬─────┘
           │ 1.21.1×fabric │ 1.21.1×neoforge│ 26.1.2×fabric │ 26.1.2×neoforge
           │               │                │               │
           └───────────────┴────────────────┴───────────────┘
                                     │ all merge to working branch
                                     ▼
                              (Phase 5 — Doctor)
```

**Dependency graph.** 4a must complete (and merge) before 4b starts. 4b's per-MC builders all run in parallel; **all** of them must complete (and merge) before 4c starts. 4c's per-(MC × loader) builders all run in parallel.

For a 2 MC × 2 loader matrix the staging is: 1 builder (4a, sequential) → 2 builders in parallel (4b) → 4 builders in parallel (4c). Total: 7 builders across 3 stage barriers.

**Per-stage rules.**

1. **Stage 4a (top-common).** One builder, working on the run's feature branch directly (no worktree — there's only one builder in this stage). Receives every `scope: top-common` work unit from `architect.json`. Commits its work on the feature branch; the orchestrator marks each work_item complete and moves on.

   - If `architect.json` has zero `top-common` work units, **skip 4a entirely** and proceed directly to 4b. Record `state.json.phase_4_build.stages["4a_top_common"].skipped = true`.

2. **Stage 4b (per-MC common, parallel fanout).** For each `mc_version` in `targets_matrix.mc_commons[]`, gather every `scope: per-mc-common` work unit whose `mc_versions` array contains that MC. Bootstrap one worktree per MC (`scripts/bootstrap-worktree.sh per-mc-common-<mc>`) and spawn one builder per worktree **in the same tool-call batch** so they run in parallel.

   Each Stage-4b builder receives:
   - The full `targets_matrix` (verbatim, same contract as Bootstrap).
   - A **filtered work-unit list**: only the `per-mc-common` units that include this MC in their `mc_versions` array. The builder writes those units into `versions/<mc>/common/`.
   - The explicit MC version this builder owns (e.g., `target_mc_version: "1.21.1"`). This pin makes it easy for the builder to reject any work that drifts into another MC's tree.

   Wait for all 4b builders to return. For each, merge via `scripts/merge-worktree.sh`. If any merge produces conflict, halt and surface to the user — common-level overlaps between MC lines almost always mean an architectural problem (a `top-common` candidate that the architect mis-classified as `per-mc-common`).

   - If `architect.json` has zero `per-mc-common` work units, **skip 4b entirely** and proceed directly to 4c. Record `state.json.phase_4_build.stages["4b_per_mc_common"]` as an empty array.

3. **Stage 4c (per-MC loader, parallel fanout).** For each `(mc_version, loader)` pair in `targets_matrix.targets[]`, gather every `scope: per-mc-<loader>` work unit whose `mc_versions` array contains that MC. Bootstrap one worktree per pair (`scripts/bootstrap-worktree.sh per-mc-<loader>-<mc>`) and spawn one builder per worktree **in the same tool-call batch**.

   Each Stage-4c builder receives:
   - The full `targets_matrix`.
   - The pair this builder owns (`target_mc_version`, `target_loader`).
   - The filtered work-unit list (per-mc-<loader> units that include this MC).

   Wait for all 4c builders, merge each, surface conflicts to user.

   - If `architect.json` has no `per-mc-fabric` / `per-mc-neoforge` work units for some `(MC, loader)` pair, **omit that pair from Stage 4c**. Stage 4c's parallelism is `min(matrix size, work units to dispatch)`.

**State writes.** Stage boundaries are the resume-relevant points. After each stage completes (all parallel builders returned + all merges done), write `state.json.phase_4_build.stages` per the CHECKPOINT.md schema — record builder spawn IDs and ISO-8601 completion timestamps per stage. Atomic write the same as any other phase boundary.

**Resume from mid-stage.** When a session resumes mid-Phase-4 in multi-MC mode, read `state.json.phase_4_build.stages` to determine which stage was in flight:
- If `4a_top_common.completed_at` is null → re-run Stage 4a (idempotency contract on the builder handles the "already committed" case).
- Else if any entry in `4b_per_mc_common` has `completed_at: null` → spawn only the missing 4b builders.
- Else if any entry in `4c_per_mc_loader` has `completed_at: null` → spawn only the missing 4c builders.

The `work_items[].status` field is still authoritative per-builder; the stages structure is a higher-level grouping that lets resume skip already-complete stages without re-walking every `work_item`.

**Single-MC fallback.** When `layout != "multiloader-multi-mc"`, the orchestrator falls back to the original ordering documented at the top of Phase 4 ("common first, then per-loader in parallel"). The stage structure is not used; `state.json.phase_4_build.stages` stays absent.

### 5. Doctor gate

After Build (and after every kick-back iteration), the orchestrator runs `/modsmith:doctor` non-interactively as a hard gate. Doctor's output is consumed as structured JSON — never paraphrase its findings into prose for the gate decision.

**Invocation:**

```bash
# Prefer the cached targets matrix from state.json. If state is stale
# (e.g. files moved during the Build phase), recompute first.
TARGETS_JSON="$RUN_DIR/targets-matrix.json"  # written during Bootstrap
if [ ! -f "$TARGETS_JSON" ] || [ "$RECOMPUTE_TARGETS" = "1" ]; then
  bash "$MODSMITH_DIR/scripts/detect-targets.sh" > "$TARGETS_JSON"
fi
bash "$MODSMITH_DIR/scripts/doctor.sh" --json --targets "$TARGETS_JSON" > "$RUN_DIR/doctor-result.json"
DOCTOR_EXIT=$?
```

(`MODSMITH_DIR` is resolved the same way Bootstrap resolves it — `${CLAUDE_PLUGIN_ROOT}` when set; never a `$0` walk-up.)

**Parse the JSON output** (shape documented in `scripts/doctor.sh`):

```jsonc
{
  "summary": {
    "hard_fail_count": 0,
    "warn_count": 2,
    "passed_count": 14,
    "verdict": "fail" | "pass" | "pass_with_warnings"
  },
  "findings": [
    { "check": "...", "severity": "hard_fail | warn | info",
      "status": "fail | pass | skip", "file": "...", "line": N,
      "message": "...", "fix_hint": "..." }
  ]
}
```

**Verdict handling:**

- **`verdict == "pass"`** — write `state.json.phase_5_doctor_result` with the full JSON, mark phase complete, advance to Phase 6 (Handoff).
- **`verdict == "pass_with_warnings"`** — log the warnings into `state.json.phase_5_doctor_result.warnings_logged_at` (timestamp). Do NOT block. Advance to Phase 6. The reviewer in Phase 6 will see the warnings via the same JSON file.
- **`verdict == "fail"`** — **do not advance to Handoff.** Convert each `severity == "hard_fail" && status == "fail"` finding into a structured bug report:

  ```jsonc
  {
    "source": "doctor",
    "check": "<check id>",
    "file": "<finding.file>",
    "line": <finding.line>,
    "symptom": "<finding.message>",
    "suggested_fix": "<finding.fix_hint>",
    "severity": "hard_fail"
  }
  ```

  Append the array of bug reports to `state.json.kick_back_queue` and transition `current_phase = "kick_back"`. Phase 7 (below) routes them back into Phase 4 (Build).

Always write `phase_5_doctor_result` (full JSON) into `state.json` before transitioning — even on fail, the next iteration may need to diff against the prior result to detect regressions vs. fresh failures.

### 6. Handoff (dev server + concurrent agents)

**This phase replaces the previous serial GameTest / Scenario / Review phases.** Foreground = a live dev-server play-test by the human player. Background = log-watcher, gametest-author, gametest-runner (per target), scenario-runner (per target), and reviewer all running concurrently. The full protocol is documented in `references/dev-server-playbook.md` — this section is the orchestrator-side wiring.

If the skill was invoked with `--headless` (or `gradle.properties` has `modsmith.headless=true`), **skip the dev-server start entirely**. The headless path runs gametest-runner → scenario-runner → reviewer sequentially in the foreground and falls through to the Handoff summary. See "Headless mode" at the end of this section.

#### 6a. Pick the preferred loader

```
prefer ← state.json.preferred_loader  (if already set this run)
      ← --prefer <loader> CLI flag    (explicit wins)
      ← architect.json.prefer         (feature spec hint, optional)
      ← gradle.properties: modsmith.prefer_loader
      ← "neoforge" if present in targets_matrix.targets[].loader
      ← targets_matrix.targets[0].loader   (last resort)
```

Persist the resolved choice into `state.json.preferred_loader` so resume picks the same loader.

##### Multi-MC: pick the preferred target (when `layout == "multiloader-multi-mc"`)

In multi-MC mode, "loader" alone isn't enough — the foreground dev server attaches to a single **`(mc_version, loader)` pair**, i.e. one Gradle subproject like `:versions:26.1.2:neoforge`. Resolve a `preferred_target` subproject string in addition to (and consistent with) `preferred_loader`:

```
preferred_target ← state.json.preferred_target  (if already set this run)
                ← --server-target :versions:<mc>:<loader>  (explicit wins;
                  also accepted as the short forms <mc>:<loader> or
                  <mc>/<loader>; orchestrator normalises to the colon form)
                ← architect.json.preferred_target  (feature spec hint, optional;
                  same syntax as the CLI flag)
                ← gradle.properties: modsmith.preferred_target
                ← latest MC × NeoForge from targets_matrix.targets[]  (a)
                ← latest MC × first available loader (b)
                ← targets_matrix.targets[0].subproject   (last resort, c)
```

"Latest MC" means the highest `mc_version` string from `targets_matrix.targets[].mc_version` under semver-ish ordering (split on `.`, compare numerically component-wise, then lexicographically for any non-numeric tails). If the matrix has both `1.21.1` and `26.1.2`, `26.1.2` wins.

Resolve `preferred_loader` to the loader half of the resolved `preferred_target` so downstream paths (`runs/<loader>/...`) stay consistent. Persist both `state.json.preferred_target` (the full subproject string, e.g. `":versions:26.1.2:neoforge"`) and `state.json.preferred_loader` so resume picks the same pair.

**Reject invalid `--server-target` values.** If the user-supplied target doesn't match any subproject in `targets_matrix.targets[]`, halt with an error listing the valid subprojects rather than silently falling back. This is a user-facing typo, not an automation gap.

#### 6b. Start the dev server (foreground)

```bash
bash "$MODSMITH_DIR/scripts/start-dev-server.sh" "$PREFERRED_LOADER"
```

That script (see `scripts/start-dev-server.sh`):

- Creates `runs/<loader>/` if missing.
- Invokes `./gradlew :<loader>:runClient` with stdout/stderr tee'd to `runs/<loader>/play-session.log`. The player still sees a live console — `tee` preserves real-time output.
- Writes `runs/<loader>/server.pid` containing the gradle process PID. (The same script removes the PID file on exit.)
- Writes `runs/<loader>/play-session.meta.json` with start time + loader. The orchestrator records `phase_6_handoff.dev_server_started_at` at this point.
- Blocks until the gradle process exits (player closes the MC window, ^C, `:q`, or crash).
- On exit, writes `runs/<loader>/.session-ended` (the sentinel the `log-watcher` agent watches for) and `runs/<loader>/play-session.exit.json` (`{exit_code, duration_s, wall_clock_end, crash_signal}`).

The orchestrator does NOT need to write `.session-ended` itself; `start-dev-server.sh` owns that. (The convention is documented at the top of the script.)

#### 6c. Print the testing plan

Before invoking `start-dev-server.sh`, render and print the testing plan to the player's terminal. Source the plan from one of:

1. `architect.json.testing_plan` — preferred. The architect's feature spec emits a structured plan: an array of player-action steps tied to work-unit acceptance criteria. Format as a numbered list of 5–10 steps.
2. If absent, **build the plan from work-unit acceptance criteria** by joining each subtask's `acceptance_criteria` bullets into a single numbered list (cap at 10).

Append the "Running concurrently" block listing background agents (log-watcher, gametest, scenario, reviewer) so the player knows what's happening off-screen. The exact format is shown in `references/dev-server-playbook.md` (search for "The printed testing plan").

#### 6d. Spawn background agents

The orchestrator launches four background agent groups concurrent with the foreground dev server. Spawn them in a **single tool-call batch** so they overlap.

The Claude Code primitive used to spawn background agents varies by host version:

- **Preferred (Claude Code ≥ 2.1.110):** use the `Task` tool with `subagent_type` set to the agent's slug (`log-watcher`, `gametest-author`, `gametest-runner`, `reviewer`). The orchestrator gets back per-agent handles it can later harvest. This is the canonical primitive — Task spawns are non-blocking from the orchestrator's perspective when issued together in one tool-call batch (the harness joins them on the orchestrator's next turn).
- **Fallback (older / general-purpose registry):** use `Agent(subagent_type: "general-purpose", ...)` and inline the relevant agent file's body as the role instructions (same pattern as the "Custom subagent fallback" section at the end of this skill). When using this path, treat each Agent call as effectively concurrent if and only if all are issued in the same tool-call batch — the harness still parallelizes them.

The orchestrator should try `Task` first and fall back to `Agent` on registry errors. Either way, the four logical agents are:

| Agent | Cardinality (v1) | Inputs | Output file |
| --- | --- | --- | --- |
| `log-watcher` | 1 (for the foreground loader) | `LOG_PATH`, `EXPECTATIONS_PATH`, `RULES_PATH`, `STATE_PATH`, `REPORT_PATH`, `SESSION_SENTINEL`, `LOADER` (see `agents/log-watcher.md`) | `runs/<loader>/watcher-report.json` |
| `gametest-author` | 1 (writes tests for all loaders — common code lives in `common/`) | run dir, architect.json, targets matrix | new Java files under `<loader>/src/main/java/.../gametest/` |
| `gametest-runner` | 1 per target in the matrix | target tuple, run dir | `runs/<loader>/gametest-results.json` |
| `reviewer` | 1 (runs once gametest results are in) | run dir, all background artifacts, doctor JSON | `runs/review.json` |

v1 spawns one `log-watcher` for the foreground loader only; background loaders' play-session logs don't exist (no second MC client). `gametest-author` writes tests once for the whole repo. `gametest-runner` fans out to one per target. `reviewer` waits for gametest-runners to finish (the orchestrator gates the reviewer spawn on the runner harvest, or instructs the reviewer to consume runner artifacts that appear during its loop).

**Multi-MC fanout (when `layout == "multiloader-multi-mc"`).** The cardinalities above stay the same in spirit, but "one per target" now means `len(targets_matrix.targets)` = MC count × loader count:

- `gametest-runner`: one per `(mc_version, loader)` pair. A 2 MC × 2 loader matrix spawns **4** runners, all in the same tool-call batch. Each writes to `runs/<mc>/<loader>/gametest-results.json` (the per-MC subdirectory disambiguates results when multiple MC lines share a loader name).
- `scenario-runner`: same fanout shape as `gametest-runner` (one per target). Output: `runs/<mc>/<loader>/scenario-results.json`.
- `log-watcher`: still cardinality 1. It watches only the foreground dev server's log, which is whichever `(mc_version, loader)` was resolved as `preferred_target` in 6a. Output stays at `runs/<mc>/<loader>/watcher-report.json` for the foreground target only.
- `reviewer`: still cardinality 1. It consumes every per-target result file across all `(mc_version, loader)` pairs and produces a single verdict spanning the whole matrix. Output: `runs/review.json` (unchanged).
- `gametest-author`: still cardinality 1. Tests live in the source tree (top-common, per-mc-common, or per-mc-loader source sets) and are written once per logical test; the runners discover them per target.

Each agent receives an absolute run-dir path and the targets matrix verbatim in its prompt (same contract as Bootstrap step 1b).

#### 6e. Detect player exit, finalize, summarize

The orchestrator detects exit via either:

- **PID-file polling** — `runs/<loader>/server.pid` no longer corresponds to a live PID (preferred; cheap and reliable).
- **Sentinel-file** — `runs/<loader>/.session-ended` exists (written by `start-dev-server.sh` on its own exit).

Either signal is sufficient. The sentinel is what the `log-watcher` agent listens for to trigger its finalize pass — see `agents/log-watcher.md`.

After exit:

1. Record `state.json.phase_6_handoff.dev_server_ended_at` (ISO-8601).
2. Wait for background agents to complete. Collect:
   - `runs/<loader>/watcher-report.json` (log-watcher report) → `phase_6_handoff.log_watcher_report_path` (single-MC) / `runs/<mc>/<loader>/watcher-report.json` (multi-MC; the path always points at the foreground target)
   - `runs/<loader>/gametest-results.json` per target → `phase_6_handoff.gametest_results` (array). In multi-MC mode the report path per target is `runs/<mc>/<loader>/gametest-results.json`.
   - `runs/<loader>/scenario-results.json` per target (if applicable) → `phase_6_handoff.scenario_results` (array). Same per-MC path nesting in multi-MC mode.
   - `runs/review.json` → `phase_6_handoff.reviewer_report_path`
3. **Compose the Handoff summary** (the structured aggregate of all findings) and print it. Format documented in `references/dev-server-playbook.md` (search for "The Handoff summary"). Record `state.json.phase_6_handoff.summary_printed = true` after printing. In multi-MC mode, use the per-MC grouped layout below instead of the flat single-MC layout.
4. Decide next phase:
   - If reviewer verdict is `approved` AND no `hard_fail` log-watcher findings AND all gametests pass: advance to Phase 8 (PR).
   - Otherwise: build a kick-back queue (reviewer's bug reports + log-watcher `hard_fail` findings + failing gametest details) and transition to Phase 7.

##### Multi-MC summary layout (when `layout == "multiloader-multi-mc"`)

When the matrix has multiple MC lines, the flat "one row per target" summary becomes hard to scan. Group results **by MC line first**, then list loaders under each MC. Format:

```
=== Handoff Summary ===
Feature: <task description, from state.json.user_prompt (first line)>

Dev server: :versions:26.1.2:neoforge (you exited after 8m 12s)

MC 1.21.1:
  fabric:    Tier-1 ✓ (14 tests) | GameTest ✓ (6) | Scenario ✓ (2)
  neoforge:  Tier-1 ✓ (14 tests) | GameTest ✓ (6) | Scenario ✓ (2)
MC 26.1.2:
  fabric:    Tier-1 ✓ (14 tests) | GameTest ✓ (6) | Scenario ✗ (1 fail)
  neoforge:  Tier-1 ✓ (14 tests) | GameTest ✓ (6) | Scenario ✓ (2)

Log-watcher: 0 hard_fails, 1 warn (missing-texture)
Reviewer: 2 bug reports, verdict: kick_back

→ Proceeding to Phase 7 (kick-back loop, iteration 1/3)
```

Rules for rendering:

- **MC ordering.** Ascending semver-ish (`1.21.1` before `26.1.2`), matching `targets_matrix` iteration order. Stable across re-runs so the player can diff summaries between iterations by eye.
- **Loader ordering inside each MC.** Alphabetical (`fabric`, `forge`, `neoforge`, `quilt`). Stable.
- **Glyphs.** `✓` for pass, `✗` for any hard-fail, `~` for warn-only. Use the exact glyphs above so the format is machine-greppable in transcripts.
- **Tier-1 count.** Aggregate JUnit count for that target's subprojects (e.g. for MC × NeoForge, sum the `test` results in `:common`, `:versions:<mc>:common`, and `:versions:<mc>:neoforge`).
- **Single-MC fallback.** When `layout != "multiloader-multi-mc"`, **keep the existing flat summary format** from `references/dev-server-playbook.md`. The grouped layout is multi-MC-only.
- **Persist a structured grouping in state.** Write `state.json.phase_6_handoff.per_mc_results` (see CHECKPOINT.md schema) — keyed by `mc_version`, each value an object keyed by loader with the per-target counts. The printed summary is the human view; `per_mc_results` is the machine view that resume and Phase 7's aggregator both consume.

#### 6f. Headless mode (`--headless`)

When `--headless` is set:

- Skip 6b (no dev-server start), 6c (no testing plan), and 6e exit-detection.
- Run gametest-runner per target and reviewer **sequentially in the foreground** (the orchestrator awaits each Agent/Task call instead of batching). gametest-author still runs first if tests are missing.
- log-watcher runs against the gametest-runner's log output only; `should_see` patterns that require player action are auto-marked "skipped — headless" in the report.
- Compose and print the Handoff summary as usual.

CI is the canonical headless caller; any non-interactive parent agent should also pass `--headless` so the orchestrator doesn't try to attach a TTY.

### 7. Kick-back loop

Phase 7 closes the feedback loop between the player-test surface (Phase 6) and the builder (Phase 4). Phase 6 hands off **four input streams** — gametest results, scenario results, log-watcher findings, reviewer verdict — and Phase 7's job is to aggregate them into a single bug-report queue, then decide whether to (a) approve and advance to PR, (b) kick back to the builder for another iteration, or (c) escalate to the human.

The cap is **3 iterations**. The orchestrator owns the loop end-to-end; the reviewer's `verdict` is a strong input but not the sole authority — the orchestrator has the matrix view across all four streams.

#### 7a. Input streams and where they live

```
       ┌───────────────────────────────────────────────────────────────┐
       │                  state.json.phase_6_handoff                   │
       │                                                               │
       │  gametest_results[]    scenario_results[]                     │
       │       │                       │                               │
       │       ▼                       ▼                               │
       │   (per-target           (per-target                           │
       │    pass/fail)            scenario verdicts —                  │
       │                          may already include                  │
       │                          scenario-analyzer bug reports)       │
       │                                                               │
       │  log_watcher_report_path  →  runs/<loader>/watcher-report.json│
       │       │                                                       │
       │       ▼                                                       │
       │   findings[] with severity hard_fail | warn | warn_if_missing │
       │                            | warn_if_exceeded                 │
       │                                                               │
       │  reviewer_report_path  →  runs/review.json                    │
       │       │                                                       │
       │       ▼                                                       │
       │   { verdict, bug_reports[], coverage_gaps[], praise[] }       │
       └───────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
                          ┌────────────────────┐
                          │   AGGREGATOR (7b)  │
                          │                    │
                          │  build queue,      │
                          │  de-dupe overlaps  │
                          └─────────┬──────────┘
                                    │
                                    ▼
                          ┌────────────────────┐
                          │   DECISION (7c)    │
                          │                    │
                          │  empty?           ─┼─→ APPROVE  → Phase 8 (PR)
                          │  warn-only +      ─┼─→ APPROVE  → Phase 8 (PR)
                          │   reviewer=approve │   (with warnings logged)
                          │                    │
                          │  hard_fail,       ─┼─→ KICK BACK → 7d builder
                          │   iter < 3         │
                          │                    │
                          │  hard_fail,       ─┼─→ ESCALATE → 7e human
                          │   iter >= 3        │
                          │                    │
                          │  reviewer=        ─┼─→ ESCALATE → 7e human
                          │   needs_human      │
                          └────────────────────┘
                                                  ┌─────────────────────┐
                          KICK BACK (7d) ─────→   │  spawn builder      │
                                                  │  with bug reports   │
                                                  │  re-run Phase 5     │
                                                  │  re-run Phase 6     │
                                                  │  return to Phase 7  │
                                                  └─────────────────────┘
```

#### 7b. Aggregation step

Read all four reports from disk (paths in `state.json.phase_6_handoff`). Build a unified bug-report queue with each entry shaped:

```jsonc
{
  "source": "reviewer" | "log-watcher" | "gametest" | "scenario" | "doctor",
  "file": "<path or null>",
  "line": <int or null>,
  "loader": "common" | "fabric" | "neoforge" | null,
  "symptom": "<one sentence>",
  "suggested_fix": "<concrete change>",
  "severity": "hard_fail" | "warn",
  "work_unit_key": "<idempotency token for the affected work unit, when derivable>",
  "target": { "loader": "<...>", "mc_version": "<...>" }  // optional, multi-MC only
}
```

**Multi-MC target tagging (when `layout == "multiloader-multi-mc"`).** Every bug report that can be attributed to a specific `(mc_version, loader)` pair carries a `target` tuple. Set it from:

- `gametest_results[i].failed > 0` → `target: { loader: target_loader, mc_version: target_mc_version }` taken verbatim from the failing entry (the runner already emits per-target results).
- `scenario_results[i].failed > 0` → same as gametest.
- `log-watcher.findings[]` → `target` = the foreground target (`state.json.preferred_target` parsed back into `{loader, mc_version}`). The log-watcher only ever runs against one target so this is unambiguous.
- `reviewer.bug_reports[]` → use the reviewer's emitted `target` field if present; otherwise infer from the bug report's `file` path (`versions/1.21.1/fabric/...` → `{loader: "fabric", mc_version: "1.21.1"}`). If neither works, leave `target: null` (the builder will fan out to all matching targets).
- `phase_5_doctor_result.findings[]` → use the doctor finding's `target` if present; otherwise infer from `file` path (same rule as reviewer). Leave `null` if the finding spans the whole repo (e.g. a top-common rule violation).

In single-MC mode, omit the `target` field entirely from bug-report entries — there's only one target so the tag would be redundant.

Promotion rules per source:

| Source | What to promote | Resulting severity |
| --- | --- | --- |
| `reviewer.bug_reports[]` | Every entry — verbatim — with `source: "reviewer"` | Keep reviewer's `severity` (`hard_fail` or `warn`) |
| `log-watcher.findings[]` with `severity == "hard_fail"` | Auto-promote with `source: "log-watcher"` for tracing. Map `pattern` + `context_lines[0]` → `symptom`; the log line's file/line if derivable (e.g. from a stack trace in `context_lines`) → `file`/`line`; otherwise null | `hard_fail` |
| `log-watcher.findings[]` with `severity == "warn"`, `warn_if_missing`, or `warn_if_exceeded` | Promote only if the reviewer didn't already flag the same finding (the reviewer cross-references these per its prompt). When promoted, `source: "log-watcher"` | `warn` |
| `gametest_results[].failed > 0` (any target) | One bug-report per failing test: `loader: <target.loader>`, `source: "gametest"`, `symptom` = the test name + failure message from the runner's JSON, `suggested_fix` = empty string (the builder reads the test source itself) | `hard_fail` |
| `scenario_results[].failed > 0` (any target) | Similar to gametest. If the runner's output already includes scenario-analyzer-style bug reports (e.g. it embedded `{file, line, symptom, suggested_fix}` blobs), pass those through with `source: "scenario"` and `loader: <target.loader>`; otherwise emit a generic entry with just the scenario id + verdict | `hard_fail` |
| `phase_5_doctor_result.findings[]` with `severity == "hard_fail"` | (Carried over from Phase 5's own queueing — already in `state.json.kick_back_queue` if doctor failed before reaching Phase 6) | `hard_fail` |

The aggregator **always rebuilds the queue from scratch** at the start of Phase 7 — it does not accumulate stale entries from a prior iteration. Any entries left over from Phase 5's pre-Handoff doctor failure (i.e. doctor failed before Phase 6 ran) stay in `kick_back_queue` and are re-aggregated here alongside the Handoff streams.

**De-dupe rule** — same bug surfaced by multiple sources is one entry. Build a dedupe key from the tuple `(normalized_file, line // 5, symptom_first_8_words)`:

- `normalized_file` strips the worktree / subproject prefix (e.g. `common/src/main/java/.../Foo.java` → `Foo.java`) so the same class flagged from two loaders collapses.
- `line // 5` buckets nearby lines (within 5 lines of each other) into the same key. Catches the case where the reviewer points at the import statement and the log-watcher's stack trace points at the throw site five lines down.
- `symptom_first_8_words` lowercases the first eight whitespace-tokenized words of the symptom. Stack traces and reviewer prose phrase the same NPE differently; eight words is enough discriminator for *kind* of error without over-fitting on punctuation.

When two entries collide:
1. Keep the higher-severity one (`hard_fail` > `warn`).
2. If severities tie, prefer `source: "reviewer"` (it has the richest context — `suggested_fix` is already written in actionable English).
3. Append the discarded entry's `source` to a `corroborated_by` array on the kept entry (e.g. `"corroborated_by": ["log-watcher"]`). The builder reads this and knows the finding was independently confirmed.

When the file/line is unknown for *both* sides (e.g. two log-watcher entries about server-tick perf with no clear file), fall back to `symptom_first_8_words` alone for the key.

**Multi-MC de-dupe extension (when `layout == "multiloader-multi-mc"`).** The base dedupe key strips the worktree / subproject prefix from `normalized_file`, which would collapse `versions/1.21.1/common/Foo.java` and `versions/26.1.2/common/Foo.java` into one entry — but in multi-MC mode that's wrong: those are two **forked** copies of the same class, and a bug in one is a bug in *that copy only* until proven otherwise. Extend the dedupe key with the entry's `target.mc_version`:

- New key = `(normalized_file, line // 5, symptom_first_8_words, target.mc_version)`.
- Two findings with the same file/line/symptom but **different** `mc_version` values stay as separate entries. They may point at forked-class bugs that need per-MC fixes.
- Two findings with the same file/line/symptom and the **same** `mc_version` (or both `null`) still collapse per the base rule.

Loader is NOT part of the dedupe key — a common-side bug surfaced via both Fabric and NeoForge runners is still one bug. Use `corroborated_by` to capture the multi-loader confirmation. The `target.loader` field stays on the kept entry as a hint to the builder; if multiple loaders independently flagged the same MC's common code, keep the `target.loader` from the higher-severity / reviewer-preferred entry and add a `corroborated_loaders: ["fabric", "neoforge"]` array.

Write the final queue to `state.json.kick_back_queue` (replacing any prior contents). Also write `runs/kick-back-NN/queue.json` with the same payload + the de-dupe trace (the discarded entries and which kept entry absorbed each one) for auditability. `NN` is `iteration_counts.kick_back + 1` zero-padded — i.e. the iteration number this queue *would* feed if the decision picks kick-back.

#### 7c. Decision logic

Compute these helpers from the freshly-aggregated queue and the reviewer's verdict:

- `hard_fail_count` = entries with `severity == "hard_fail"`
- `warn_count` = entries with `severity == "warn"`
- `iterations_used` = `state.json.iteration_counts.kick_back` (rounds *completed*, not including the round being decided)
- `reviewer_verdict` = `reviewer.verdict` from `runs/review.json`

Decision table (evaluate top-to-bottom, first matching row wins):

| Condition | Action |
| --- | --- |
| `reviewer_verdict == "needs_human"` | **Escalate** (7e). Regardless of iteration count or queue contents — the reviewer has flagged something only a human can resolve (scope drift, conflicting evidence, etc.) |
| `hard_fail_count > 0` AND `iterations_used >= 3` AND `reviewer_verdict == "approve"` | **Approve with warnings logged** (7c-special). The cap is a *safety net*, not a strict block. If the reviewer's final-pass verdict is `approve` despite the cap being hit, advance to PR — but record the residual `hard_fail` entries in `state.json.last_error` for the PR body to surface. This is rare; in practice the reviewer's verdict will be `kick_back` or `needs_human` when there are still hard fails. |
| `hard_fail_count > 0` AND `iterations_used >= 3` | **Escalate** (7e). Cap reached; surface to the human. |
| `hard_fail_count > 0` AND `iterations_used < 3` | **Kick back** (7d). Spawn the builder with the queue; re-run Phase 5 → Phase 6 → Phase 7. |
| `hard_fail_count == 0` AND `warn_count > 0` AND `reviewer_verdict == "approve"` | **Approve with warnings logged**. Advance to Phase 8 (PR). Write `state.json.phase_6_handoff.warnings_logged_at` (timestamp) and include the warn entries in the PR body. |
| `hard_fail_count == 0` AND `warn_count > 0` AND `reviewer_verdict == "kick_back"` | **Kick back** if `iterations_used < 3`; the reviewer judged the warns serious enough. Same path as the third row above. |
| `hard_fail_count == 0` AND `warn_count == 0` | **Approve** (queue is empty). Advance to Phase 8 (PR). |

Whichever branch fires, **always** write the decision to `state.json.kick_back_history` if a round is starting (7d) or to `state.json.kick_back_escalation` if escalating (7e). Approval branches need no entry in either array.

#### 7d. Kick-back execution

When the decision is "kick back":

1. **Increment counter and open a history entry.** Set `state.json.iteration_counts.kick_back += 1` and append a new in-progress entry to `state.json.kick_back_history`:

   ```jsonc
   {
     "iteration": <iteration_counts.kick_back>,
     "started_at": "<ISO-8601>",
     "ended_at": null,
     "bug_report_count": <queue length>,
     "bug_reports": <verbatim queue>,
     "builder_output_path": null,
     "phase_6_rerun_summary": null,
     "outcome": null
   }
   ```

   Persist `state.json` (atomic write) *before* spawning the builder. If the builder run dies, resume reads the history entry and knows to pick up mid-round.

2. **Spawn the builder.** Prefer the `Task` tool with `subagent_type: "modsmith-builder"`. Fall back to `Agent(subagent_type: "general-purpose")` with the `agents/builder.md` body inlined (same fallback pattern as Phase 6's background spawn — see "Custom subagent fallback" at the end of this skill).

   The builder prompt MUST include:

   - **The structured bug-report queue verbatim.** Paste `state.json.kick_back_queue` as a JSON code block under a `## Bug reports to address` heading.
   - **A pointer to the original architect's plan.** Pass the absolute path to `{RUN_DIR}/architect.json` so the builder can map bug reports onto work units via `work_unit_key` (when set). Also pass the relevant `work_items[i]` entries by `subtask_id` so the builder knows which worktrees / branches the original work lives on.
   - **The full targets matrix** (verbatim from `state.json.targets_matrix`) under `## Target matrix (read first)`. Unchanged from Bootstrap.
   - **A clear scope statement:** "Address these specific bug reports. Do NOT add new features. Do NOT touch files outside the diff of work units these bug reports map to, unless the suggested_fix explicitly calls for it. Re-run Tier-1 JUnit tests (`./gradlew test` or per-subproject) for any code you change before committing. Static-only validation — leave gametest / scenario / runClient to the orchestrator's later phases."
   - **The `cannot_fix` escape hatch:** "If a bug report requires a library upgrade, a manual schema migration, a decision the user must make, or an architectural change beyond the work-unit boundary, return a `cannot_fix` outcome: emit a JSON object `{ outcome: 'cannot_fix', reasons: [...], partial_fixes: [...] }` and exit. This counts toward the iteration cap; the orchestrator surfaces it on the next aggregation pass."
   - **Per-loader fanout instructions.** When bug reports span multiple loaders, the builder bootstraps a worktree per loader (per `WORKTREES.md`) and works in parallel — same pattern as the original Phase 4. Bug reports tagged `loader: "common"` go to the common worktree; loader-specific entries go to the matching `:fabric` or `:neoforge` worktree. Re-merge the worktrees into the feature branch when done.
   - **Iteration context.** Tell the builder which iteration this is (`This is kick-back iteration <N> of 3.`) and that prior iterations' work is already on the feature branch — they're refining, not starting over.

   **Multi-MC builder fanout (when `layout == "multiloader-multi-mc"`).** Instead of one builder, the orchestrator may spawn multiple builders based on the queue's `target.mc_version` field:

   - **All bug reports share the same `target.mc_version`** (or are all `target: null` / lack a `target` field) → spawn **one** builder for that MC. The builder uses the multi-MC scope rules from `agents/builder.md` (target subproject paths under `versions/<mc>/...`).
   - **Bug reports span MC versions** (e.g. one report tagged `1.21.1` and another tagged `26.1.2`) → spawn **one builder per MC version**, in parallel (same tool-call batch). Each builder gets only the bug reports that match its MC plus any `target: null` reports (those are interpreted as "applies to every MC line in the queue"). This is the "fix the same logical bug in two forks" case — common when a forked-class bug is present in both `versions/1.21.1/common/Foo.java` and `versions/26.1.2/common/Foo.java`.

   Each parallel builder gets its own worktree (`scripts/bootstrap-worktree.sh kick-back-NN-<mc>`) and writes to `runs/kick-back-NN/<mc>/builder-output.md`. After all builders return, the orchestrator merges each worktree back to the feature branch in deterministic MC order (ascending). Conflicts in this stage almost always indicate a top-common bug that the builder mis-scoped as per-mc — surface to the user rather than auto-resolve.

   The single-MC code path (no `target` fields, or `layout != "multiloader-multi-mc"`) keeps the one-builder pattern unchanged.

   The builder writes its return summary to `runs/kick-back-NN/builder-output.md` (where `NN` is the current `iteration_counts.kick_back` zero-padded) and commits with a message like `fix: kick-back <N> — <symptom one-liner>`.

3. **Re-run Phase 5 (Doctor gate).** Same script invocation as the first Phase 5 pass. If doctor fails again, write the new doctor findings to `kick_back_queue` (replacing the prior contents from Phase 7), record `phase_6_rerun_summary: "doctor failed at re-gate: <hard_fail_count> hard_fail findings"`, and **return to Phase 7's aggregator** without running Phase 6. The next aggregation will see only the doctor entries; the decision logic still applies (typically another kick-back if iterations remain).

4. **Re-run Phase 6 (Handoff).** Full Handoff cycle: the dev server restarts so the player can re-test if they want; background log-watcher / gametest / scenario / reviewer run as before. **If `--headless`**, skip the dev server and just run gametest-runner + scenario-runner + reviewer sequentially (per Phase 6f). All four output paths get fresh files (`runs/<loader>/watcher-report.json`, etc.); the orchestrator stores them in `state.json.phase_6_handoff` (overwriting the prior pass's pointers — the prior reports remain on disk for forensic comparison but `state.json` only tracks the latest).

5. **Close the history entry.** When Phase 6 returns, fill in the open `kick_back_history` entry:

   ```jsonc
   {
     "ended_at": "<ISO-8601>",
     "builder_output_path": "kick-back/NN/builder-output.md",
     "phase_6_rerun_summary": "<one-line aggregate: gametest pass/fail totals + reviewer verdict + watcher counts>",
     "outcome": "address_succeeded" | "address_partial" | "escalated"
   }
   ```

   Determining `outcome` requires another aggregation pass (step 6).

6. **Return to Phase 7's aggregator (7b).** Read the freshly-written Phase 6 outputs, rebuild the queue, and run the decision again. This is the loop's natural recursion point:

   - If the new decision is **approve** → the just-closed history entry gets `outcome: "address_succeeded"`. Advance to Phase 8.
   - If the new decision is **kick back** AND the new queue is a strict subset of the prior queue (some bugs fixed, but new ones surfaced or partial fixes left holes) → close as `"address_partial"`, increment counter, open a new history entry, loop.
   - If the new decision is **escalate** → close as `"escalated"`, write `kick_back_escalation`, surface to the user.

   The builder's `cannot_fix` return is detected at this step: when the orchestrator parses `runs/kick-back-NN/builder-output.md` and finds `outcome: "cannot_fix"`, it treats the iteration as ended with `outcome: "escalated"` and writes a `kick_back_escalation` entry citing the builder's `reasons`. This bypasses the natural cap check — `cannot_fix` is an immediate escalation regardless of iteration count.

#### 7e. Escalation

When the decision is "escalate":

1. **Write `state.json.kick_back_escalation`** with:

   ```jsonc
   {
     "escalated_at": "<ISO-8601>",
     "reason": "cap_reached" | "reviewer_needs_human" | "builder_cannot_fix",
     "iteration_count": <iteration_counts.kick_back>,
     "final_queue": <verbatim kick_back_queue>,
     "recommendation": "<one paragraph: what you'd suggest the human do — e.g. 'Two of the three hard_fail findings are NPEs in the common ShopkeeperTickHandler; the third is a NeoForge-specific registry error that may need a NeoForge docs lookup. Recommend the human fix the NPEs manually and spawn a focused researcher for the registry error.'>",
     "history_ref": "kick_back_history",
     "diff_summary": "<output of `git diff <base_branch>..HEAD --stat`>"
   }
   ```

   The `recommendation` is the orchestrator's best take — it has the full matrix view across iterations and can spot patterns (e.g. "every iteration the builder fixes Loader A but breaks Loader B" suggests an architectural issue, not a code bug).

2. **Write `{RUN_DIR}/kick_back_escalation.json`** with the same payload — a standalone file makes it easy for the human to read without parsing the full `state.json`.

3. **Surface to the user via `AskUserQuestion`** (inline mode) or by halting with `current_phase` set to `kick_back` and writing the escalation summary to `{RUN_DIR}/blocked.md` (headless mode, same pattern as the rest of the skill).

4. **Do not advance to Phase 8.** The orchestrator pauses here; the human's next action (manual fix + resume, scope reduction, abandonment) determines what happens next.

#### 7f. Loop bookkeeping

- **`iteration_counts.kick_back`** is the canonical counter. It increments at the start of step 7d-1 and persists across resume.
- **`kick_back_history`** is append-only. Each iteration gets exactly one entry, opened at the start of the round (step 7d-1) and closed when Phase 6 returns (step 7d-5). The history is the audit log; do not edit prior entries.
- **`kick_back_queue`** is rebuilt from scratch on every Phase 7 entry. It's a *transient* working set — the snapshot lives in the history entry's `bug_reports` field.
- **Atomic writes throughout.** Every state.json mutation (counter increment, history append, queue rebuild, escalation write) follows the standard atomic-write rule from CHECKPOINT.md.

#### 7g. Edge cases

- **Same bug reported by two sources.** Handled by the de-dupe rule in 7b. The higher-severity entry wins; the lower-severity entry's `source` is appended to a `corroborated_by` array on the kept entry. The builder reads this and knows the finding is independently confirmed.
- **Builder returns `cannot_fix`.** This counts toward the iteration cap (it's a completed iteration even though no code changed). The orchestrator parses the builder's structured return, writes the open history entry with `outcome: "escalated"`, then writes `kick_back_escalation` with `reason: "builder_cannot_fix"`. Phase 6 is NOT re-run — the loop short-circuits to escalation. This is intentional: a `cannot_fix` means re-running Phase 6 would just surface the same bugs again.
- **Iteration cap reached but reviewer's verdict was `approve` on the last pass.** Do NOT escalate; advance to PR. The cap is a safety net for cases where the reviewer keeps saying `kick_back` and the builder can't close the loop. If the reviewer is satisfied, the cap is moot. Record the residual entries in `state.json.last_error` so the PR body surfaces them (the human can decide whether to follow up).
- **Headless mode.** Kick-back still works; just no dev-server restart between iterations. The headless code path through Phase 6 (per 6f) is identical regardless of which iteration triggered it. Builder, doctor re-gate, and gametest/scenario/reviewer all run; only the dev-server foreground is skipped. The `kick_back_history` entry's `phase_6_rerun_summary` should note the mode (e.g. `"headless — gametest 8/0, reviewer approve, no log-watcher coverage of player paths"`).
- **Doctor fails mid-loop.** Treated in step 7d-3 above: when re-running Phase 5 after the builder commit, if doctor's verdict is `fail`, write the doctor findings to the queue and return to the aggregator without running Phase 6. The history entry for this iteration gets `phase_6_rerun_summary: "skipped — doctor re-gate failed"` and `outcome: "address_partial"`. The next iteration's builder gets the doctor entries directly.
- **Empty queue but reviewer says `kick_back`.** Trust the reviewer's verdict — they're seeing something the deterministic aggregation missed (coverage gap, drift). Kick back with the reviewer's `coverage_gaps` rephrased as bug-reports with `severity: "warn"`. If `iterations_used >= 3`, escalate instead (the reviewer's instinct is real but the loop is out of runway).
- **Two iterations produce identical queues.** Smell — the builder isn't making progress. The orchestrator checks: if the new queue's dedupe-key set is equal to the prior iteration's set, escalate immediately (don't wait for the cap). Write `kick_back_escalation` with `reason: "no_progress"` and include both queues in the recommendation. This catches the case where the bug is in the spec or the harness, not the code.

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
- **Scenario validation loop**: 5 iterations (used by scenario-runner / scenario-analyzer when Tier-3 is available — still authoritative for that sub-loop even though scenarios now run inside Phase 6 in the background).
- **Kick-back loop (Phase 7)**: 3 iterations. Tracked in `state.json.iteration_counts.kick_back`; history per iteration lives in `state.json.kick_back_history`. On cap-hit (or builder `cannot_fix`, or reviewer `verdict == "needs_human"`), Phase 7 writes `state.json.kick_back_escalation` and surfaces to the user — see Phase 7e.
- If a downstream agent keeps producing similar diagnoses across iterations, the bug is probably in the harness or the spec — escalate rather than thrash.

## What you delegate vs. what you do

**You (orchestrator) do:**
- Bootstrap-read the host project.
- Read and write `state.json` at every phase boundary.
- Spawn subagents with concrete, well-scoped prompts.
- Schedule parallel groups per `architect.json`.
- Bootstrap and merge worktrees per `WORKTREES.md`.
- Pace the run via the real-time signals in Bootstrap step 4 (no token
  budget exists — watch subagent over-runs and your own context).
- Surface architect's `open_questions` to the user when they block decomposition.
- Decide between options when subagents surface them; pick the simpler one.
- Decide when to stop iterating.
- Write the final PR body.

**You don't:**
- Decompose tasks (that's `modsmith-architect`).
- Write code (that's `modsmith-builder`).
- Write tests (that's `modsmith-gametest-author` / `modsmith-scenario-author`).
- Run scenarios (that's `modsmith-scenario-runner`).
- Diagnose failures (that's `modsmith-scenario-analyzer`).

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
- Notable subagent over-runs, if any (from `subagent-log.jsonl`).
- Any optional polish items the analyzer or reviewer flagged but you didn't ship.

## Inline vs. headless invocation

This skill works the same whether you (the orchestrator) are running directly in the user's conversation or were spawned from a parent agent's `Agent` tool call. The contract:

- **Inline** (default, easier to interject): the user invoked the skill directly. The orchestrator can ask the user for clarification mid-run (`AskUserQuestion`) when architect's `open_questions` blocks progress or context pressure forces an early checkpoint.
- **Headless** (parent agent): a higher-level orchestrator spawned this run. Don't `AskUserQuestion`; instead pause the run by setting `current_phase` to a halted state and writing the questions to `state.json.last_error` plus `{RUN_DIR}/blocked.md`. The parent agent surfaces it to the user.

The state machine is identical in both modes. Resume protocol via `state.json` is identical. The only difference is *where* the questions get surfaced.

---

## Custom subagent fallback

The Agent tool's `subagent_type` registry varies by Claude Code session. The named agents this skill references live as separate files in the plugin's `agents/` directory — **but they may not be loaded into this session's registry.**

If you (the orchestrator) spawn one and get `Agent type '<name>' not found`, fall back as follows:

1. **Read the canonical agent file** from the plugin's `agents/<role>.md` — its body is the full spec.
2. **Spawn `general-purpose`** with the agent file's body inlined as the role instructions, plus your specific task. Skip the YAML frontmatter; everything below it is the prompt.
3. **The role contract is identical** — the agent file's tools whitelist and effort settings don't transfer to `general-purpose`, but the role definition + your specific task is enough for the work.

If even the canonical agent file is missing (degraded environment), use the **inline fallback specs below**. They're tighter than the full files but sufficient for the role contract.

### Inline fallback: modsmith-architect

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

### Inline fallback: modsmith-builder

```
You are an implementer for a Minecraft mod feature subtask. Read the host project's
CLAUDE.md, build.gradle, and gradle.properties first.

Idempotency contract (when invoked from /modsmith:develop Lane 2):
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

### Inline fallback: modsmith-gametest-author

See the plugin's `agents/gametest-author.md` — the full determinism checklist + spec-first principle is too long to inline. If that file is missing, the absolute minimum for the role contract:

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
- **modsmith-scenario-author / modsmith-scenario-runner / modsmith-scenario-analyzer**: only relevant if host project has Tier-3 scenario harness (`./gradlew runScenarioServer` or similar). Skip the scenario phase if the harness is absent.
