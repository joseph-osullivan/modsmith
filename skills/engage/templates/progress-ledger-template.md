# {{engagement-name}} — progress ledger

Update this file at the END of every session so the next one (yours or a
fresh session) resumes without re-deriving state. Newest entry on top.
The **Status block** is the one section maintained in place; the
**Session log** below it is append-only — correct an earlier entry with a
new entry, never by editing history.

**Resume protocol (any session, before doing anything else):** read the
BRIEF → this Status block → the newest log entries. Then `git pull`
every in-scope repo and verify the ledger's claims against actual
content — files present, PRs merged, versions bumped. Trust content, not
prose.

## Status

- **Current gear/phase:** {{Gear 1 (advise only) | Gear 2 (+ ratchet
  state: pause-per-PR or batch-and-go)}}
- **Decisions locked:** {{date — decision; date — decision}} (mirror of
  the decision menu's locked-decisions record)
- **Baseline:** {{per-repo build/test state, with the date it was last
  re-verified}}
- **PRs:** {{open (awaiting merge) / merged, per repo}}
- **Maintainer action queue:** {{things only the maintainer can do —
  merges, releases, credentials — with exact commands where possible}}
- **NOT-DONE register:** {{explicit list of anything a reader might
  assume finished that is not, each with an owner or a trigger. Keep
  this current — an implicit "probably done" is how work gets lost.}}

### Multi-session ownership split *(delete this section if single-session)*

- **Partition by REPO, never by feature** — this avoids build-tool and
  test-run collisions and version-bump races.
- **Session 1:** {{repos + batches it owns}}
- **Session 2:** {{repos + batches it owns}}
- **Shared-state rules:**
  - Each session writes ONLY its own section of this Status block and
    its own log entries. Never edit the other session's text.
  - Verify the other session's claims by **pull + content check** — read
    the actual files/commits, don't trust its prose or a PR's
    open/closed state.
  - If the other session hasn't written its entry yet, reconstruct its
    status from git and mark it explicitly as reconstructed.
  - Never run resource-colliding tasks concurrently: two test servers
    on one repo, cleanup scripts that reap the other session's
    processes, simultaneous version bumps on one file.

## Session log *(newest first, append-only — new entries go directly under this heading)*

### {{date}} — {{session id}}: {{one-line headline}}

- **Shipped:** {{PR numbers + one line each; decisions taken; docs
  written}}
- **Deviations:** {{where reality diverged from the plan, and why}}
- **Next:** {{the first thing the next session should do}}
- **Blockers:** {{or "none"}}

### {{date}} — setup

- Brief written (`BRIEF.md`); engagement folder created; baseline
  {{green/red per repo}}.
- **First move for the agent:** read `BRIEF.md` → orient → broad triage
  across all mandates → write `triage.md` + `decision-menu.md` → stop
  and hand over the menu.
