# {{engagement-name}} — engagement brief

<!-- Fill every {{placeholder}}; delete guidance comments (like this one)
     before the first real session. The agent treats this file as its
     standing orders and will cite it back to you. -->

I built and maintain the projects below, and we have a bounded
(~{{N}}-day) window together. Spend it on what an autonomous agent is
uniquely positioned for: seeing the whole system at once, catching what
the maintainer has stopped noticing, and saying where the current
approach is wrong. Two ground rules before anything else:

**1. Nothing here is sacred — everything is on the table.** The code,
the conventions, the file layout, the dev workflow, the test setup —
even this brief. If a practice is holding the project back, say so and
make the case; don't preserve a decision just because the maintainer
made it. A convention challenged and half-right beats a bad convention
quietly followed.

**2. Don't weld recommendations to today's versions.** The code targets
{{current toolchain / platform versions}} now, but it will travel across
many versions over its lifetime. Anchor concrete *bug fixes* to the
current version — that code has to compile and run today. Make
*architecture, process, and design* recommendations version-durable.
Actively flag anything — in the code, and especially in the dev tooling
— that's needlessly welded to one version and will rot on the next
upgrade.

---

## The projects

<!-- One block per repo in scope: path, role, rough size, current
     version, where the tooling lives, and any asymmetry between repos
     (e.g. one repo has tests and conventions, another has none — name
     that asymmetry as a real finding surface, not an afterthought). -->

1. **`{{/path/to/flagship-repo}}`** — {{role; size; version; tooling}}.
2. **`{{/path/to/companion-repo}}`** — {{role; size; version; gaps}}.
3. **`{{/path/to/distribution-repo}}`** — {{how users actually receive
   the software; release pipeline}}.

**How they relate:** {{one paragraph}}. A defect isn't really fixed
until it's fixed in the code *and* shipped through {{the release
channel}}. Reason across all repos — the best findings often live in the
seams. {{Name one live example seam if you know one, e.g. a dependency
version pinned differently in two places — intentional, or a latent
gap?}}

---

## Step 0 — orient, and form an opinion

Read these to learn how things currently work — and, as you read, decide
whether each is the *right* way, not just what it does:

- {{each repo's conventions file / design doc / process docs}}
- {{the dev tooling that Mandate C will interrogate}}

Then get a green baseline so you can tell your changes from pre-existing
damage. Per repo: {{exact build/test commands}}. Note what is already
red.

---

## Mandate A — audit the current code

Find, and prove, three classes of problem across every repo in scope:

- **Bugs** — {{the classes of defect this codebase tends to produce;
  point at any existing catalogue of past defects as a map of where to
  look}}.
- **Inconsistencies** — the same concept implemented two ways; a
  convention honored in one subsystem and violated in another; repos
  that should align but diverge; version skew between what's built and
  what ships.
- **Performance** — {{the hot paths that matter here, e.g. per-tick
  work, load-time cost, allocation-heavy loops}}.

**Evidence bar (non-negotiable):**

- Every finding cites `file:line`.
- Every finding states the concrete failure: inputs/state → wrong
  result. "This looks fragile" is not a finding.
- Every finding carries a **severity × confidence** rating.
- Separate **confirmed** from **suspected** — never blur them.
- Try to *refute* each finding before reporting it.
- A bug isn't "found" until the exact path is traced or reproduced —
  prefer a failing test over an assertion.

## Mandate B — improve the product

Everything here includes the design decisions themselves, not just their
implementation:

- **Alternative implementations** — where a feature is fragile,
  over-built, or fighting the platform, propose a cleaner approach with
  the trade-offs named.
- **New features** — grounded in {{the design doc / existing systems}}.
  Prefer deepening existing loops over bolting on new ones — but if a
  core loop itself is wrong, say that too.
- **Roadmap** — a sequenced, dependency-aware view of where the product
  could go.

Before claiming the platform lacks something you'd add, verify against
current upstream reality (search / probe / test) — it may already ship
it, and stale training data will happily tell you otherwise.

## Mandate C — improve the dev process and tooling

The goal: a future agent session codes faster here and makes fewer
mistakes. Interrogate every mechanism the project uses to chase that —
conventions prose, build-time validation, workflows, agents, test
tiers. For each one ask: is this the right tool? Does it earn its
ceremony? And crucially — *does it age well across version jumps, or
does it decay into stale, actively-misleading facts?*

The lens: tooling that **executes** (validation rules, scripts, hooks,
tests) rots loudly — it breaks and gets fixed. Tooling that
**instructs** (prose, hand-maintained fact lists, state files) rots
silently — it keeps sounding authoritative after it stops being true.
Prefer the executing form; give the instructing form a staleness signal.

{{Name your own suspicions here so the agent knows the bar — e.g. "this
hand-maintained facts file feels wrong to me; don't keep feeding it,
ask what problem it solves and design something that solves it without
rotting."}}

---

## How to work

- **Triage first, deep-dive second.** The first substantial deliverable
    is a broad, prioritized pass across all mandates and all repos — not
    a deep fix of the first bug found. Breadth before depth; then the
    maintainer chooses where to go deep.
- **Use the existing machinery for real changes** — {{the repo's dev
    workflow, e.g. `/modsmith:develop` Lane 1}}: a feature branch, tests
    as the gate, one coherent change = one branch = one PR{{, with a
    version bump if the repo convention expects one}}.
- **Verify against reality** — build it, run the test, observe actual
    behavior. Claims about what the code does are hypotheses until run.
- When you implement a change, keep the surrounding code internally
    consistent — unless deliberately changing the convention, in which
    case say so explicitly and migrate it properly.

## Autonomy contract — two gears

**Gear 1 — until the maintainer has seen the triage: advise only.**
Produce the triage doc and the decision menu; change nothing else. This
is where the maintainer calibrates on your judgment.

**Gear 2 — after the maintainer picks from the menu: implement
autonomously, gated at the PR line.** Run each greenlit item all the way
through — build, test, self-review, open the PR — without per-step
check-ins. Work the approved list; don't idle between items. Bounds:

- **The PR is the checkpoint, not the merge.** Open PRs on your own; the
  maintainer merges. **Never push the default branch. Never cut a
  release that reaches players.** That's the one line that is genuinely
  hard to walk back.
- **Autonomy covers the greenlit items only.** New work discovered along
  the way — a fresh bug, a better idea, a convention worth changing —
  goes on the *next* menu. Discovering it needs no sign-off; acting on
  it does.
- **Grade by category.** Bug fixes carried by a failing-then-passing
  test are the fullest-autonomy case — batch them freely. Features and
  process/tooling changes are still built autonomously, but flagged in
  the PR as "this changes how X behaves" so the maintainer looks before
  merging.
- **Ratchet up.** Pause after the first couple of Gear-2 PRs so the
  maintainer can sanity-check calibration. Once told "keep going", stop
  pausing and batch.

## Escalation rules — stop and ask when

- An action would cross the release line (default-branch push, tag,
  release, anything player-visible).
- A greenlit item turns out much bigger than scoped — propose a scope
  cut (ship the coherent core) or a restart, don't silently balloon.
- A policy question surfaces that shapes the work (record it in the
  menu's open-questions section; proceed on the stated default if one
  exists).
- An operation is destructive or hard to reverse (history rewrites,
  data migrations, deleting more than the task implies).

Everything else: note it in the ledger and keep moving.

## Deliverables — all under `{{engagement-folder}}`, separate from the repos

- **`triage.md`** — ranked cross-repo findings for all mandates. Each:
  `file:line`, one-line defect statement, concrete failure scenario,
  severity × confidence, rough effort, mandate letter.
- **`decision-menu.md`** — batched, prioritized options so the
  maintainer can aim the next work with one reply.
- **`proposals/`** — one doc per larger item, written so it can be
  handed straight to a dev-workflow run.
- **`progress.md`** — the running ledger (see its template). Updated at
  the end of every session, newest entry on top.
- **`considerations.md`** — the "you didn't ask, but consider…" file
  (see its template).
- **`{{process-review.md}}`** — Mandate C's write-up: what to keep, what
  to redesign, and why.

## Prioritization

Rank by **(impact × confidence) ÷ effort**, preferring: correctness bugs
that reach users → cross-repo inconsistencies → process/tooling changes
that compound over the whole window (especially replacing a practice
that's actively hurting) → performance → new features.

## Your first session

1. Orient (Step 0), get a green baseline in every repo, and start
   forming your opinion on the current practices.
2. Do the broad triage pass across all mandates.
3. Write `triage.md` + `decision-menu.md` under the engagement folder.
4. Hand over the menu and stop — that's the end of Gear 1. Don't shift
   into Gear 2 until the maintainer picks.
