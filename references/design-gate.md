# The design gate — nine questions every player-facing change answers

The gate turns `game-design.md` into something an agent can fill in and a
reviewer can verify. It runs **before** code (in the design brief or the
PR body's "Design" section) and **after** code (the reviewer checks the
answers against the diff). Pure bug fixes, refactors, and dev-tooling
changes skip it; anything a player can see, hear, or do does not.

The gate needs the project's `docs/design/bible.md` (hook, pillars,
loops, archetypes, non-goals). If the project has none, say so and point
the developer at `/modsmith:design bible`; do not invent one inline.

---

## Pre-build gate (fill every line; "n/a" needs a reason)

```markdown
### Design

**Hook fit.** Which pillar(s) of the bible does this serve, in one line each?
**Loop.** Which loop does it live in (30-second / 10-minute / session) and what
decision does the player make inside it?
**Aesthetic and need.** Which LeBlanc aesthetic (sensation, fantasy, narrative,
challenge, fellowship, discovery, expression, submission) and which PENS need
(competence, autonomy, relatedness) does it serve? Name the dynamic that delivers it.
**Three uses.** Three distinct things a player does with it. Fewer → long-tail list.
**Vanilla parity.** Does vanilla already do this? Does it add a HUD, play itself,
bulk-place blocks, level the player, or depend on respawn? Each "yes" needs a reason.
**Discoverability.** How does a player who has read nothing learn it exists and
what it does, in the world, before any book? Name the first-encounter staging
(see it work → try it safely → twist → payoff).
**Feedback.** What does the world do on success and on failure (sound, particles,
block state, animation, mob behavior)? Chat must not be the only channel.
**Mastery and cost.** What pattern is learned; what re-presents it later with a
twist; time to first payoff vs the nearest vanilla equivalent; the degenerate
optimal strategy and whether it is embraced or designed out.
**Archetypes.** Which of the bible's player archetypes gain, and is any worse off?
```

A proposal fails the gate when: it serves no pillar; it has fewer than
three uses; vanilla already does it; it has no in-world discoverability
plan; its only feedback is chat; or its mastery answer is "bigger
numbers." A failed proposal is not deleted: it is filed on the project's
long-tail list with the failing line quoted, so the idea survives and the
reason is on record.

## Post-build review (the reviewer adds these to the normal checklist)

1. The Design section exists and every line is answered, or the change
   is correctly classed as not player-facing.
2. Each answer is **true of the diff**: the discoverability staging exists
   in code or data (advancement, structure, NPC behavior, Ponder-style
   scene), the feedback channels named are wired to live call sites, the
   HUD/parity answer matches what was added.
3. Nothing player-visible was added that the Design section does not
   mention (a new chat line, command, overlay, or GUI tab).
4. Text budget: on-screen text added per encounter is near George Fan's
   "eight words"; a wall of lore in a tooltip is a finding.
5. Any failure-mode name from `game-design.md` that applies is used
   verbatim in the finding (menu play, invisible mechanic, book-first
   teaching, chat-only feedback, grind as content, treadmill,
   vanilla-redundant, plays itself, scope creep, unbounded search,
   dead-space gating, archetype tax).

## Orient (when in doubt mid-task)

Re-read the bible's hook and pillars. Ask: *does the thing I am about to
do make the player feel more like the fantasy, or does it make the
spreadsheet more complete?* If the honest answer is the second, stop and
run the pre-build gate on the alternative before continuing. This is the
step that catches "technically right, not fun."

## Worked example (fixture)

Proposal: *"Add a village stats HUD overlay showing condition, treasury,
and population in the top-left while inside a claimed village."*

- Hook fit: serves "feel like a lord" only indirectly; it is information,
  not agency.
- Vanilla parity: **adds a HUD** (Jeb: "you are not wearing a HUD");
  vanilla conveys village state through bells, villager behavior, and
  iron golems, not overlays.
- Discoverability: n/a, it is always on. Feedback: n/a, it *is* feedback,
  and it replaces world feedback with numbers (menu play by another
  route).
- Three uses: read condition, read treasury, read population. One use,
  three fields.
- Mastery: none; nothing is learned.

Verdict: **fails** (vanilla parity, three uses, mastery). Filed on the
long-tail list. The alternative that passes: make condition legible in
the world (villagers repair or neglect buildings, market stalls fill or
empty, the steward's greeting changes), and keep the numbers behind the
existing steward screen for players who want them.
