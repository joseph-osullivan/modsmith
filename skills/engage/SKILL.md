---
name: engage
description: "Set up or resume a multi-day autonomous engagement on a codebase: a BRIEF with explicit mandates and an autonomy contract (the PR is the checkpoint, not the merge), Gear-1 triage → decision menu, Gear-2 batched implementation, and an append-only progress ledger any future session can resume from cold."
when_to_use: "When the user wants a bounded multi-session audit-and-improve campaign over one or more repos — 'spend the week on this codebase', 'audit these mods and fix what you find', 'resume the engagement' — rather than a single feature or fix (that's /modsmith:develop). Also when a prior engagement folder exists and a new session must pick up where the last one stopped."
user-invocable: true
allowed-tools: Agent, Read, Glob, Grep, Bash, Write, Edit, WebSearch, WebFetch, AskUserQuestion
---

# /modsmith:engage — multi-day autonomous engagement

Structure for a bounded (days-long, multi-session) campaign over one or
more repos: audit, improve, and hand over — with the autonomy boundary
drawn in advance so the agent can batch work instead of pausing between
items. `/modsmith:develop` builds one change; `engage` is the layer
above it — it decides *which* changes, in what order, with what
evidence, across sessions that do not share memory.

The four templates in [`templates/`](./templates/) are the standing
documents of an engagement. They encode a field-proven shape — fill
them, don't re-derive them:

| Document | Template | Role |
|---|---|---|
| `BRIEF.md` | [BRIEF-template.md](./templates/BRIEF-template.md) | Standing orders: mandates, autonomy contract, evidence bar, escalation rules, deliverables |
| `progress.md` | [progress-ledger-template.md](./templates/progress-ledger-template.md) | Append-only ledger + Status block; any session resumes from it cold |
| `decision-menu.md` | [decision-menu-template.md](./templates/decision-menu-template.md) | Batched options for the maintainer; locked-decisions record |
| `considerations.md` | [considerations-template.md](./templates/considerations-template.md) | "You didn't ask, but consider…" — noticed → matters → cheapest next step |

## Core contract (internalize before anything else)

- **Two gears.** Gear 1: advise only — triage and menu, change nothing
  else. Gear 2 (only after the user picks from the menu): implement the
  greenlit items autonomously.
- **The PR is the checkpoint, not the merge.** Open PRs on your own; the
  user merges. **Never push the default branch. Never cut a release
  that reaches players.** That is the one line that is genuinely hard
  to walk back.
- **Autonomy covers greenlit items only.** New work you discover goes on
  the *next* menu. Discovering it needs no sign-off; acting on it does.
- **Ratchet.** Pause after the first Gear-2 PRs for a calibration
  check; once the user says "keep going", stop pausing and batch.

## Resume an existing engagement (checklist)

1. Locate the engagement folder; read `BRIEF.md`, then the ledger's
   Status block, then its newest log entries.
2. `git pull` every in-scope repo; verify the ledger's claims against
   actual content (files present, PRs merged, versions bumped) — trust
   content, not prose.
3. Confirm which gear you are in and, in Gear 2, what is greenlit and
   unstarted. If another session is active, obey the ledger's
   multi-session ownership split.
4. Continue from "what's next" in the newest entry. Do not re-triage
   unless the BRIEF or the user says to.

## Instantiate a new engagement (checklist)

1. **Elicit the mandate set** from the user (AskUserQuestion works
   well):
   - window length (days) and repos in scope, plus how they relate and
     how the software actually reaches its users;
   - which mandates apply — the field-proven trio is **A: audit**
     (bugs, inconsistencies, performance), **B: improve the product**
     (alternatives, features, roadmap), **C: improve the dev process
     and tooling** ("does it rot?");
   - autonomy bounds beyond the defaults (anything else the user
     reserves: releases, user-visible behavior, spend);
   - decisions the user wants surfaced rather than made, and any
     defaults to use meanwhile.
2. **Create the engagement folder** OUTSIDE the repos (a sibling
   directory). All deliverables live there; the repos receive only
   branches and PRs.
3. **Write `BRIEF.md`** from the template. Fill every placeholder,
   delete the guidance comments, and play it back to the user for
   sign-off — it is the contract both sides will cite later.
4. **Seed `progress.md`** from the ledger template with a setup entry:
   brief written, baseline state, the first move for the next session.
5. **Gear 1 — triage.** Breadth before depth: one broad, prioritized
   pass across all mandates and all repos — not a deep fix of the first
   bug found. Hold the BRIEF's evidence bar (`file:line`, concrete
   failure scenario, severity × confidence, refute-before-report,
   confirmed vs suspected kept separate). Fan out subagents for
   parallel audit lanes when the surface is large — but personally
   re-verify each top finding before it enters the triage doc, and mark
   the re-verified ones.
6. **Write `triage.md` + `decision-menu.md`**, append the session's
   ledger entry, hand the user the menu, and STOP. That is the end of
   Gear 1 — do not implement anything until the user picks.
7. **Gear 2 — implement in batches.** Work the greenlit list in menu
   order; don't idle between items. Each item: one coherent change =
   one branch = one PR, run through `/modsmith:develop` (Lane 1) or the
   host repo's own workflow if it has one, with a version bump when the
   repo convention expects it. Honor the ratchet; respect the
   escalation rules in the BRIEF.

## Ledger discipline (every session, no exceptions)

- Update `progress.md` at the END of every session: what shipped (PR
  numbers plus one line each), deviations from plan, what's next,
  blockers. Newest entry on top. Entries are append-only — correct an
  earlier entry with a new one, never by editing it.
- Keep the **Status block** current in place: gear + ratchet state,
  locked decisions, baseline, maintainer action queue, and the
  **NOT-DONE register** — anything a reader might assume finished that
  is not, each with an owner or a trigger.
- **Multi-session rules** (two or more concurrent sessions):
  - Partition ownership **by repo, never by feature** — this avoids
    build-tool and test-run collisions and version-bump races.
  - Each session writes only its own ledger section and entries.
  - Verify the other session's claims by **pull + content check**, not
    by its prose or a PR's open/closed state; if its entry is missing,
    reconstruct from git and label the reconstruction as such.
  - Never run resource-colliding tasks concurrently (two test servers
    on one repo; cleanup scripts that reap the other session's
    processes).

## Decision-menu cadence

- **Menu 1** goes out with the triage — it is the Gear-1 → Gear-2 gate.
- A **new numbered menu** whenever the greenlit queue drains or
  discovered work has accumulated. Discovered work never jumps the
  queue: it waits for its menu.
- Every item carries **scope, effort, risk, recommendation**, and any
  decision the user must supply (with the default you'll use if they
  reply with just the letter). Lead with a "your queue first" section
  for actions only the user can take (merges, releases, credentials).
- Record each reply in the menu's **Locked decisions** section with the
  date, and mirror it into the ledger's Status block. A decision that
  lives only in chat is lost to the next session.

## Wind-down (the final session(s) of the window)

1. Write **`considerations.md`** from its template — the observations
   that fit neither triage nor proposals: noticed → why it matters →
   cheapest next step.
2. Finalize the **NOT-DONE register** in the ledger — explicit, so
   nothing reads as implicitly finished.
3. Give every **date-bound task that outlives the window** an owner:
   hand it to the user, a scheduled job, or complete it early on a
   shorter-but-clean evidence window. Never leave one unowned.
4. Restate the **maintainer action queue** in one place, with exact
   commands.
5. Final ledger entry: per-mandate state (done / partial / not
   started), PRs awaiting merge, and where every deliverable lives.

## Worked example (shape only)

For a `shopkeeper` mod suite — a flagship mod, a small companion mod,
and a pack repo that ships both — a typical engagement: Mandate A finds
a persistence bug behind the shopkeeper's storage menu (severity high,
confirmed by a red-then-green GameTest); Mandate B proposes deepening
the trade loop over adding a new one; Mandate C notices the companion
repo has no tests or conventions file and bootstraps a minimal kit
rather than cloning the flagship's heavier setup. Menu 1 batches these
as A/B/C with a suggested order; the user replies "A, C"; Gear 2 ships
each as its own PR; the discovered trade-ledger quirk waits for menu 2.
