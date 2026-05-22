# Parallel git worktrees for `/mc-mod-develop`

When the architect outputs `parallel_groups` with more than one subtask, the orchestrator runs those builders in **parallel git worktrees**. Each subtask gets its own worktree at `.trees/{subtask_id}` on its own branch `agent/{subtask_id}`.

This file documents the bootstrap, run, merge, and cleanup contract.

## Why worktrees

- **File-level isolation.** Two builders writing to disk in the same directory would silently overwrite each other. Worktrees give each builder its own checkout.
- **Shared object store.** All worktrees share the parent's `.git` objects — no duplicated history, no extra disk pressure.
- **Conflicts surface at merge time, not silently mid-build.** Standard git tooling flags them.
- **Fresh branches.** Each subtask's commits are scoped to its own branch; the orchestrator stitches them together at the end.

## Critical constraint (read before parallelizing)

Worktrees provide **file-level isolation only.** They do NOT isolate runtime resources:

- Gradle daemons, build caches, ports.
- POI / SavedData / world files at `run/world/`.
- The user's local Minecraft mods folder.

This means **only run static checks (`compileJava`, `verifyMod`) in parallel.** Anything that boots the dedicated server, opens ports, or reads/writes the run-dir world (`runGameTestServer`, `runScenarioServer`, `runClient`) must run **serially**, after parallel builders return.

The orchestrator schedules accordingly (see `SKILL.md` Phase 3 build dispatch).

## Bootstrap (one worktree per subtask)

Use `scripts/bootstrap-worktree.sh <subtask_id> <base>` — it handles the git incantation, is idempotent (safe on resume), and reuses an existing branch from a prior aborted run. Output is JSON `{path, branch, existed, base_sha}`; record the path in `state.json.work_items[i].worktree_path`.

The script intentionally does *not* warm the build cache. If you want that:

```bash
( cd .trees/{subtask_id} && ./gradlew compileJava --quiet ) &
```

…but don't fight it — gradle's daemon usually handles cold starts fine, and warming N caches in parallel can starve disk I/O.

## Builder invocation

For each worktree, the orchestrator spawns one `mc-mod-builder` subagent. The Agent tool's `prompt` includes:

- The subtask's `name`, `description`, `acceptance_criteria`, `files_to_modify` (verbatim from `architect.json`).
- The `work_unit_key` (idempotency token from `state.json.work_items[i].work_unit_key`).
- The full path to the worktree (`/abs/path/to/repo/.trees/{subtask_id}`).
- An instruction to `cd` into that worktree before running any commands.

Builders run **only static-check validation** locally:

- `./gradlew compileJava` — must pass before commit.
- `./gradlew verifyMod` — must pass before commit.
- `./gradlew test` (Tier 1 JUnit) — fine to run in parallel; cheap.

Builders **do NOT run** in this phase:

- `./gradlew runGameTestServer` — saved for the gametest phase, runs serially.
- `./gradlew runScenarioServer` / `runClient` — same.
- `./gradlew integrationCheck` — runs the heavy stuff; runs serially.

This split keeps parallelism safe.

## Merge

Use `scripts/merge-worktree.sh <subtask_id> <feature_branch>`. It checks out the feature branch, attempts a `--no-ff` merge, and on success removes the worktree + deletes the agent branch. Output:

- `status=merged` — clean. Continue.
- `status=already_merged` — branch was already an ancestor (e.g. on resume). Continue.
- `status=conflict files=<comma-list>` — abort + surface to user. **Don't auto-resolve.** Conflicts mean the architect mis-grouped these subtasks (they touched the same file). Mark `state.json.work_items[i].validation_status = "rejected"`, `last_error = "merge conflict: <files>"`, set `current_phase = "build"`, and pause the run with a clear "resolve manually then re-invoke" message.

After all subtasks in a group merge, run the full `./gradlew integrationCheck` once on the merged branch. If that fails, treat it as a build-attempt failure (count toward the `build_attempts` iteration limit).

## Cleanup

After merging a worktree's branch into the feature branch:

```bash
# Remove the worktree's working directory:
git worktree remove .trees/{subtask_id}

# Optionally delete the agent/ branch (it's now reachable from feature/):
git branch -d agent/{subtask_id}
```

If a worktree's builder failed, **don't auto-remove**. Keep it for at least 24 hours so the user can inspect what went wrong. Mark `state.json.work_items[i].status = "failed"` and reference the worktree path so a retry knows where to look.

## Sequential fallback

If `parallel_groups[i].length == 1`, no worktree machinery is needed. Run the builder directly on the feature branch in the main checkout. Worktrees add overhead; only use them when actually parallelizing.

The orchestrator decides per-group:

```
if len(parallel_groups[i]) == 1:
    run_builder_serial(parallel_groups[i][0], feature_branch)
else:
    for subtask_id in parallel_groups[i]:
        bootstrap_worktree(subtask_id)
    spawn_builders_parallel(parallel_groups[i])
    wait_all()
    merge_branches_serial(parallel_groups[i])
```

## Disk pressure

Worktrees share the object store, but each one has a full working-tree checkout. For a Minecraft mod repo (~50 MB), 5 parallel worktrees is ~250 MB. Trim `.trees/` periodically; the orchestrator's cleanup step handles this for the current run, but old failed worktrees from prior runs may need manual `git worktree prune`.

## Common failure modes

- **`git worktree add: 'agent/X' is already checked out`** — a previous run didn't clean up. `git worktree remove --force .trees/{subtask_id}` then retry.
- **Gradle daemon contention** — symptoms include builders hanging on `./gradlew`. Mitigation: pass `--no-daemon` for parallel static checks, or limit `parallel_groups` to 3 concurrent builders.
- **Builders write to repo-root instead of their worktree** — the prompt forgot to `cd`. Always include the absolute worktree path in the builder's prompt and a explicit "cd into this directory before any tool calls" instruction.
