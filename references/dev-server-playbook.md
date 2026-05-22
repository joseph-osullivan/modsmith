# Dev-server handoff playbook

The **Handoff phase** of `/modsmith:develop` is where modsmith's design
diverges most from a conventional CI-first workflow: as soon as
`/modsmith:doctor` passes, modsmith hands the dev server to *you*
(the player) for live play-testing while gametest, scenario, reviewer,
and log-watcher all run concurrently in the background. This collapses
wall-time and gives "feel" testing that the gametest layer structurally
cannot provide.

This playbook documents the foreground/background protocol, how exits
are observed, edge cases (crashes, restarts, multi-target), and the
`--headless` opt-out.

## Default behavior: dev server auto-starts

After the Doctor gate passes, the orchestrator selects a **preferred
loader** for the dev session (see "Multi-target prefer-loader" below)
and launches:

```bash
scripts/start-dev-server.sh <loader>
```

This script:

1. Resolves `runs/<loader>/play-session.log` (creating `runs/<loader>/`
   if missing).
2. Invokes `./gradlew :<loader>:runClient` (or `:runServer` if the
   feature is server-only — the architect notes this in the feature
   spec).
3. **Tees** the combined stdout/stderr through `tee -a
   runs/<loader>/play-session.log` so the file is appended in
   real-time, while the player still sees a live console.
4. Records start time + process group ID in
   `runs/<loader>/play-session.meta.json` so the orchestrator can
   reliably observe the process across reattach.
5. Prints the **testing plan** (next section) to stdout BEFORE the MC
   client opens its window.

The orchestrator then waits on the dev-server process **and** spawns
the background agents (next section).

## The printed testing plan

The architect's feature spec includes an intent map: which player
actions exercise which work units. The orchestrator renders this as a
testing plan before launch.

Example output:

```
modsmith testing plan for feature "shopkeeper-discount"
─────────────────────────────────────────────────────────
target: neoforge / MC 26.1.2

1. Walk to spawn (slash-tp /tp @s 0 100 0 should work).
2. Find a shopkeeper villager (added in this feature) at
   spawn radius < 50 blocks. Look for the unique nameplate.
3. Right-click the shopkeeper while UNTAGGED.
   Expect: trade GUI opens. Prices shown are baseline.
4. Exit the trade GUI, run /tag @s add hero, then right-click
   the same shopkeeper.
   Expect: prices reduced by 10% (visible in tooltip).
5. Open the F3 menu briefly to confirm no error-spam in the
   log.
6. ^C (Ctrl-C) or `:q` (in-MC console) when done. Background
   results will surface afterward.

Running concurrently (will report on your exit):
- log-watcher  (tailing runs/neoforge/play-session.log)
- gametest     (Tier-2 tests for "shopkeeper-discount")
- scenario     (any scenarios tagged shopkeeper)
- reviewer     (full PR-level review)
─────────────────────────────────────────────────────────
```

Players who want a no-frills run can pass `--no-plan` to skip the
printed plan; the background agents still run.

## Background agent fan-out

Concurrent with the dev server, these agents run **in the background**:

| Agent | What it does | Output |
| --- | --- | --- |
| `log-watcher` | Tails `play-session.log` against `play-expectations.json` (architect-emitted) and universal baselines (`log-watcher-rules.md`). | `runs/<loader>/watcher-state.json` (running), final structured report on player-exit. |
| `gametest-author` | Writes Tier-2 gametests for the feature (uses `gametest-rules.md`). | New Java files under `<loader>/src/main/java/.../gametest/`. |
| `gametest-runner` (×N for N targets) | Runs Tier-2 gametests via `scripts/run-gametest.sh --warmup`. | `runs/<loader>/gametest-results.json` per target. |
| `scenario-runner` (×N) | Runs any pre-existing scenarios applicable to the feature. | `runs/<loader>/scenario-results.json` per target. |
| `reviewer` | Full PR-level review across all artifacts and findings. | `runs/review.json`. |

These are spawned as Task tool calls from the orchestrator, all in a
single launch batch so they overlap. The orchestrator polls their
completion **only when** the foreground dev-server process exits.

## How player exit is observed

The dev server exits when:

1. Player closes the MC client window.
2. Player presses `^C` in the orchestrator terminal.
3. Player runs `:q` (built-in MC server console, server-only runs).
4. The dev server crashes (treated as an exit with non-zero code).

In all cases, the `start-dev-server.sh` script exits and writes
`runs/<loader>/play-session.exit.json`:

```jsonc
{
  "exit_code": 0,
  "duration_s": 512,
  "wall_clock_end": "2026-05-21T19:42:11Z",
  "crash_signal": null
}
```

The orchestrator detects this, then:

1. Sends a "finalize" signal to the `log-watcher` (it reads
   `play-session.exit.json` as its cue and writes its final report).
2. Joins / harvests results from all background agents.
3. Composes a **Handoff summary** for the player.

### The Handoff summary

```
─────────────────────────────────────────────────────────
modsmith handoff summary — shopkeeper-discount
─────────────────────────────────────────────────────────
Play session: 8m 32s on neoforge / MC 26.1.2

Background results:
  ✓ log-watcher   — 1 warn, 0 hard-fails. See runs/neoforge/watcher-report.json
  ✓ gametest      — 4/4 passing on neoforge. See runs/neoforge/gametest-results.json
  ✓ gametest      — 4/4 passing on fabric.   See runs/fabric/gametest-results.json
  ✓ scenario      — no applicable scenarios.
  ⚠ reviewer      — 2 minor suggestions. See runs/review.json
─────────────────────────────────────────────────────────
```

Failures from any layer flip the summary line to a hard `✗` and the
orchestrator transitions to the **reviewer kick-back loop** rather
than the PR phase.

## `--headless` flag (skip dev server entirely)

For CI or any non-interactive context, pass `--headless` to
`/modsmith:develop`:

```
/modsmith:develop "implement shopkeeper discount" --headless
```

With `--headless`:

- Dev server does NOT start.
- Background agents still run (gametest, scenario, reviewer,
  log-watcher).
- log-watcher has no `play-session.log` to tail; it operates only on
  the gametest-runner's log output. (The architect's
  `play-expectations.json` is checked against gametest logs only;
  `should_see` lines that depend on player action are auto-marked
  "skipped — headless" rather than "missing".)
- A summary still prints; just no testing plan and no live play
  segment.

## Edge case: dev server crashes mid-play

A crash is a meaningful signal, not a failure to handle.

- `play-session.exit.json` records `exit_code != 0` and (if available)
  `crash_signal`.
- `log-watcher` finalizes as usual; the stack trace will be a
  `hard_fail` finding (universal baselines catch `Exception in server
  tick` / unhandled stack traces).
- The Handoff summary surfaces the crash as a top-level item, distinct
  from background-agent results.
- The `hard_fail` finding **auto-promotes into the kick-back queue**.
  The builder must address it on the next iteration.

## Edge case: server restart needed (kick-back loop)

If the player notices an issue and the orchestrator returns to the
build phase (kick-back), the dev server **does not auto-resume** — the
mod has changed underneath it and the world state may now be
incompatible. After the kick-back iteration completes Doctor again,
the Handoff phase restarts and the dev server launches fresh.

The previous `runs/<loader>/play-session.log` is rotated to
`play-session.<iso8601>.log` so each iteration's logs are preserved.

## Edge case: multi-target prefer-loader selection

When the target matrix has multiple loaders (e.g. `fabric` and
`neoforge`), the dev server only runs ONE of them — a player can't
play in two clients at once. The orchestrator picks by this hierarchy:

1. **CLI flag:** `--prefer fabric` or `--prefer neoforge` (explicit
   wins).
2. **Feature spec hint:** the architect can mark a feature `prefer:
   <loader>` (e.g. if the feature is mostly NeoForge-specific code
   the loader-specific path is more interesting to play-test).
3. **Project default:** `gradle.properties` may set
   `modsmith.prefer_loader=neoforge`.
4. **Fallback:** NeoForge if present, else Fabric. NeoForge wins ties
   because its dev-server is the slightly richer environment (richer
   F3, more dev-time logging).

The other loader(s) still get the full **background** treatment —
gametest, scenario, log-watcher (on gametest logs only), and reviewer
all run for each target.

## Edge case: dev server crash before any play

If the dev server crashes during boot (e.g. a mixin failed to apply,
a config has a typo), the player never sees a live MC window. The
orchestrator detects this:

1. `play-session.exit.json` shows `duration_s < 30 && exit_code != 0`.
2. The watcher report **still finalizes** — boot failures usually
   show up as `hard_fail` stack traces in the log, which is exactly
   what the watcher is for.
3. Background agents continue (gametest may also fail-fast for the
   same reason; reviewer will get both signals).
4. Handoff summary prints with a top-line note: "dev server failed
   to boot; see runs/<loader>/play-session.log".
5. Kick-back queue receives the boot-failure finding.

## Auto-default-on, opt-out by flag

The dev-server handoff is **on by default**. The reasoning: features
shipped without a live play-test are routinely broken in ways
gametests miss — UI, audio, render order, network latency, click
feedback. The default exists so the player doesn't have to remember
to opt in.

To opt out: `--headless`. To opt out per-project: set
`modsmith.headless=true` in `gradle.properties` (the orchestrator
reads this on bootstrap).

## Quick reference: file paths

- `runs/<loader>/play-session.log` — live tee'd dev-server output.
- `runs/<loader>/play-session.meta.json` — start time + PID.
- `runs/<loader>/play-session.exit.json` — exit code + duration; the
  watcher's "finalize" cue.
- `runs/<loader>/watcher-state.json` — log-watcher running state.
- `runs/<loader>/watcher-report.json` — final watcher findings.
- `runs/<loader>/gametest-results.json` — per-target gametest report.
- `runs/<loader>/scenario-results.json` — per-target scenario report.
- `runs/review.json` — single reviewer report across all targets.
