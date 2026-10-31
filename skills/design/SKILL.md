---
name: design
description: "Gameplay design for a Minecraft mod: interview the developer into a design bible (hook, pillars, loops, archetypes, non-goals, discoverability and feedback vocabulary), write per-feature design briefs, run the nine-question design gate on a proposal, or audit shipped features against the bible. Project-agnostic: all output lands in the host project's docs/design/."
when_to_use: "Starting a new mod ('what is this mod?'), adding a player-facing feature ('should we add X?', 'design the Y system'), unsure whether a change is good for the game ('is this fun?', 'orient'), or auditing an existing mod's features for cut/fix/keep. Also whenever /modsmith:develop finds a player-facing change with no bible."
user-invocable: true
allowed-tools: Read, Glob, Grep, Write, Edit, Bash, WebSearch, WebFetch, AskUserQuestion
---

# /modsmith:design — bible, brief, orient, audit

The design layer answers one question before any code exists: *is this
good for the game?* It rests on two references in this plugin:
[`references/game-design.md`](../../references/game-design.md) (why) and
[`references/design-gate.md`](../../references/design-gate.md) (the nine
questions). Read both before the first invocation in a session.

Everything this skill writes goes into the **host project** under
`docs/design/`. modsmith holds no per-mod opinions.

```
docs/design/
  bible.md            the mod's design bible (one per project)
  briefs/<slug>.md    one design brief per player-facing feature
  long-tail.md        proposals that failed the gate, with the failing line
  audit-<date>.md     output of audit mode
```

## Modes

Pick from the user's words; ask only if genuinely ambiguous.

| Mode | Trigger | Output |
|---|---|---|
| **bible** | New mod, or no `docs/design/bible.md` exists | `docs/design/bible.md` |
| **brief** `<feature>` | A player-facing feature is about to be built | `docs/design/briefs/<slug>.md` with the gate filled |
| **orient** `<proposal>` | "Should we…", "is this fun", mid-task doubt | Verdict in chat (pass / fail with the failing lines), filed to `long-tail.md` on fail |
| **audit** | Existing mod; "what should we cut/fix" | `docs/design/audit-<date>.md`: every shipped feature through the gate → keep / fix / cut |

`brief`, `orient`, and `audit` **require a bible**. If none exists, say
so in one line and offer to run bible mode first; never fabricate the
hook from the code.

## Bible mode: the interview

The bible is written *with* the developer, not for them. Use
`AskUserQuestion` in rounds of two to four multiple-choice questions,
each with a recommended option first, until every section below has an
answer the developer has seen and accepted. Offer your own candidate
answers drawn from the kickoff material (README, design docs, prompts,
issue tracker) so the developer edits rather than composes. Stop asking
when the sections are filled; do not pad.

Read first: the project README, any existing design doc or kickoff
prompt, the issue labels, and `game-design.md`. For an existing mod also
skim the registered content (blocks, items, entities, screens) so the
candidate answers describe what is actually there.

### Bible sections (keep the whole file under ~150 lines)

1. **Player fantasy** — one sentence in the second person: *"You are…"*.
2. **Who plays** — the archetypes (explorer, builder, grinder, socializer…)
   and the real group if known (solo first? two or three friends?). Note
   the multiplayer stance: solo-first with multiplayer-safe systems, or
   multiplayer-first.
3. **Hook** — one paragraph: what is unique here that would make someone
   install this over the nearest existing mod. Name the nearest existing
   mod and the difference.
4. **Loops** — the 30-second loop, the 10-minute loop, the session loop,
   each with the decision the player makes inside it and the LeBlanc
   aesthetic it serves.
5. **Pillars** — three to five, each phrased as a trade-off: *"We would
   rather X than Y."* Pillars are what the gate's "hook fit" line checks
   against.
6. **Scope gate** — the three-use test, the vanilla-redundant test, and
   any project-specific intake rules. Point at `design-gate.md`.
7. **Non-goals** — what this mod will not do, including tempting things.
8. **Discoverability plan** — how players learn, in order of preference
   (observable world usage, NPC behavior, advancements, Ponder-style
   scenes, guidebook last), and the rule that chat is never the only
   channel.
9. **Feedback vocabulary** — the mod's world-based signals for success and
   failure (sounds, particles, block states, animations, NPC reactions),
   so every feature draws from the same palette.
10. **Progression and mastery** — what is learned early, what re-presents
    it later, where the end state is, and what the long-session playtest
    must check.
11. **Open questions** — decisions deferred, each with a default.
12. **Provenance** — date, who signed it, what it supersedes, and a
    "re-read this when" line (every roadmap phase, every audit).

Write the bible, show the developer the whole file, and ask for sign-off
in one question. Record the sign-off date in Provenance. The bible is a
living document: later changes go through a short "Changes" list at the
bottom, never a silent rewrite.

## Brief mode

For one player-facing feature:

1. Re-read the bible's hook, pillars, loops, archetypes.
2. Fill the pre-build gate from `design-gate.md` completely.
3. Add: the first-encounter staging as a short scene ("the player
   notices… tries… the twist is… the payoff is…"), the world-feedback
   list, the smallest shippable slice, and what would make this a cut
   later.
4. If any gate line fails, stop and present the failure with the
   alternative that passes (as in the gate's worked example). Do not
   write a brief for a failing feature; file it in `long-tail.md`.
5. Write `docs/design/briefs/<slug>.md`. The brief is what the builder
   and the PR body cite.

## Orient mode

Fast and conversational. Read the bible, run the nine questions on the
proposal, give the verdict in under 200 words with the failing lines
quoted, and the passing alternative if one is obvious. On fail, append
to `docs/design/long-tail.md`. This mode is also what `/modsmith:develop`
invokes when it meets a player-facing change with no brief.

## Audit mode (existing mods)

1. Enumerate shipped player-facing features from the code and data:
   blocks, items, entities, screens, commands, advancements, guidebook
   entries, chat messages.
2. Run each through the gate against the bible. Group as **keep**,
   **fix** (passes the hook but fails discoverability, feedback, or
   parity; name the failure mode), **cut** (fails hook fit or three uses;
   state the reason and what is lost).
3. Rank fixes by player impact over effort. Chat-only feedback and
   invisible mechanics usually top the list; they are cheap and they are
   the "technically right, not fun" complaint in concrete form.
4. Write `docs/design/audit-<date>.md` and present the cut list as a
   decision menu; cuts are the developer's call, with reasons on record.

## Rules of engagement

- Never decide taste for the developer: the gate catches *bad* decisions
  (parity, redundancy, invisibility, chat-only); whether something is
  *fun enough* is theirs, and you surface it as a question.
- Quote the bible and `game-design.md` by section when giving a verdict,
  so the reasoning is checkable.
- Keep on-screen text in any proposed encounter near eight words.
- Cite the nearest existing mod when claiming uniqueness; web-search
  before asserting "no mod does this."
- When the developer's answer contradicts the bible, say so and ask
  whether the bible or the proposal should change. Both are allowed;
  silence is not.
