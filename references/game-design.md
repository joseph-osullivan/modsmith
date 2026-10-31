# What makes a Minecraft mod fun — the reference behind every gameplay decision

Read this before proposing, designing, building, or reviewing anything a
player can see or do. It is general to Minecraft mods (and most games); the
per-mod answers live in that project's `docs/design/bible.md`, produced by
`/modsmith:design`. The fillable questions are in `design-gate.md`; this
file is the *why* behind them.

Compiled 2026-10-31 from the sources listed at the end. Verified claims
cite a source; unmarked lines are the synthesis.

---

## 1. Fun is learning, and boredom is finishing the lesson

Raph Koster: "Fun in games arises out of mastery... With games, learning
is the drug." Once a pattern is mastered it goes trivial and the player is
bored unless the pattern is re-presented in a new form. This single fact
explains the content treadmill (bigger numbers, same pattern), why grind
reads as filler, and why late-game collapse is the most common modpack
failure (SevTech's ages 4–5, Vault Hunters' third edition both drew exactly
that review).

**Decision rule.** For every mechanic, name the *pattern* the player
learns and name what *re-presents* it later with a twist. If the only
answer is "more of the same with bigger numbers", it is treadmill, not
depth. Depth is "hard to master"; complexity is "hard to learn"; a mod
should buy the first, not the second.

## 2. Mechanics → dynamics → aesthetics: design the feeling, ship the rule

The MDA framework (Hunicke, LeBlanc, Zubek 2004): designers write
mechanics, players experience aesthetics, and the dynamics in between are
emergent. LeBlanc's eight aesthetics name what a player can actually enjoy:
**sensation, fantasy, narrative, challenge, fellowship, discovery,
expression, submission** (the comfort of a routine).

**Decision rule.** Every feature states which aesthetic it serves and
which dynamic produces it. "Adds a tax system" is a mechanic; "the player
feels like a lord whose decisions visibly change a village (fantasy,
expression)" is the aesthetic, and "villagers build when fed and starve
when not" is the dynamic that delivers it. A feature with no nameable
aesthetic is bookkeeping.

## 3. Three needs keep people playing

Self-Determination Theory as applied to games (Rigby & Ryan, PENS):
sustained play tracks **competence** (I am getting better and can tell),
**autonomy** (I chose this and could have chosen otherwise), and
**relatedness** (this matters to someone, even an NPC). Agnes Larsson on
vanilla: "if the game gets too template and predetermined, you risk
killing the creative joy"; players set their own goals.

**Decision rule.** Prefer mechanics that offer *choices with visible
consequences* over mechanics that prescribe one path. A single optimal
build order kills autonomy; a mechanic nobody could notice kills
competence; a kingdom that never reacts to you kills relatedness.

## 4. Minecraft's own rules (Jeb's internal design book, as reported)

Mojang's design principles, summarized by a secondary source and
consistent with every public Mojang statement:

- **One block at a time.** No templates or bulk placement for the
  player; the world is built and read block by block. Players learn by
  watching things happen.
- **Not quite an RPG.** Progression comes through items and knowledge,
  not character levels or stat screens.
- **You are not wearing a HUD.** Minimal UI; show through the world,
  not through overlays and text.
- **Finding things is fun. Searching for them is not.** Hidden rewards
  must be *reachable*: maps, hints, visible landmarks. Unbounded searching
  is a chore.
- **It is up to the players to build the world.** The game provides
  materials and threats, not finished content to consume.
- **Death is real** (loss has teeth), **bugs are not features**, **expand
  the mysteries** (a new system should raise questions, not close them).
- **Items must serve a purpose; new features respect existing ones;
  hostile mobs are unique; mobs have personality.**

Create's stated philosophy matches: "designed to leave as many design
choices to the player as possible... the game isn't played inside a bunch
of UIs." Its tutorials are Ponder scenes (the mechanic performs itself in
a little world), not pages of text.

**Decision rule.** Treat these as a parity check. A feature that adds a
HUD element, plays itself, levels the player, bulk-places blocks, relies
on respawn, or duplicates a vanilla capability needs a written reason or
a redesign. AE2's intake rule is the sharpest form: a suggestion that is
already achievable in vanilla is invalid.

## 5. Teach through the world, not the book

The best-documented teaching patterns:

- **Present the problem before the tool** (GMTK on Half-Life 2's
  Ravenholm): let the player see a sawblade kill a zombie before handing
  over the gravity gun. The player should *want* the mechanic before being
  told it exists.
- **Learn by doing, spread mechanics out, eight words on screen at a
  time** (George Fan, Plants vs. Zombies GDC talk). Each new thing arrives
  alone, in a safe context, with almost no text.
- **Kishōtenketsu** (Koichi Hayashida, Super Mario 3D World): introduce
  the idea safely, develop it, twist it, resolve with a payoff. A first
  encounter with any mod mechanic can be staged this way.
- **Observable usage** beats description: a hot spring surrounded by
  heating runes teaches heating runes; a village whose guards drill
  teaches that guards train.

Players actively dislike the alternative: forum threads single out mods
that "throw a book with all the knowledge in the UNIVERSE at you", and
reviewers fault packs for gating in dead space and letting early mistakes
go unnoticed for hours.

**Decision rule.** Every player-facing mechanic ships with a
*discoverability plan*: how does a player who has read nothing find out
this exists and what it does, inside the world? Guidebooks (Patchouli,
Modonomicon) and advancements are the reference, never the first
encounter. Chat messages are the weakest channel and never the only one.

## 6. Feedback lives in the world

Vlambeer's "Art of Screenshake" and Jonasson/Purho's "Juice it or lose it"
make the case that feedback density is what makes a mechanic feel alive;
Minecraft's own vocabulary is sound, particles, block-state changes,
animation, and mob behavior. Create's tactility (visible motion, kinetic
stress) is this principle applied to a tech mod.

**Decision rule.** Every mechanic states what the world does on success
and on failure, in that vocabulary. "Taxes were collected" as a chat line
is a failure of this rule; emeralds visibly deposited in a chest with a
sound, a steward who walks to collect them, a village that looks richer,
are passes. Overdoing it costs immersion (Nijman's caution), so the test
is *legible*, not *loud*.

## 7. One strong core, and the courage to refuse

Keith Burgun: a design should have one strong core mechanism and remove
elements that conflict with it; "when adding 'more' to a game you
decrease the likelihood of being able to balance the game." The mods
people love enforce this at intake. Botania: "the bar for new features is
quite high"; Vazkii: "If you make something everyone likes, you make
something no one loves." Tinkers' Construct: come up with three use cases
for the idea or it does not go in. Feed the Factory is praised precisely
because "all gameplay elements not related to the tech premise are
removed."

**Decision rule.** A mod has a hook (one sentence) and three to five
pillars. A proposal must serve the hook, pass the three-use test, and
not be achievable in vanilla. Otherwise it goes to the long-tail list,
not the roadmap. Cutting is a design act, not a failure.

## 8. Grind is a cost, not content

Reviewers of modpacks repeatedly ask to "cut the grind" and call out thin
"ore-for-better-ore" loops. Vazkii's design essays argue for engagement
over ease-and-power and against passive generation that removes the
player from the loop. The FTB community's own framing: ore doubling and
grinders should be "signals for succeeding in mastering the mod's
mechanics, not the primary purpose."

**Decision rule.** Measure wall-clock time to first payoff and to full
capability, and compare with the nearest vanilla equivalent (first
diamond, first Nether trip). Anything slower than vanilla needs a reason
tied to a dynamic ("the wait is when the raid can hit you"), never
"balance." Where a degenerate optimal strategy exists (AFK farms, passive
income), either embrace it as the mastery signal or design it out, but
decide on purpose.

## 9. Playstyles coexist

mDiyo designing Tinkers' 3: "It needed to be 'Minecraft,' not a mod",
considering builders, explorers, speedrunners, and casuals at each tier.
YUNG builds structures "gameplay-first... ensuring that traversing the
structure is a fun experience", with multiple routes rewarded. A mod
played by a small group needs each member's style to feed the others:
the explorer surfaces locations, the grinder unlocks capability, the
builder gives the group a home.

**Decision rule.** Name the archetypes the mod serves (the bible does
this once). Each feature says which archetypes it serves and must not
make any of them worse off. Structures are designed as traversal
experiences first and as set dressing second.

## 10. Late-game collapse is the default outcome unless designed against

SevTech earns praise for its early game and reviews saying the last ages
are "not worth playing"; Vault Hunters is called "lacking a feeling of
progression" with "unnecessarily grindy" recipes. The pattern: legible
progression carries a pack until the novelty curve flattens, then nothing
re-presents the patterns and the pack ends with a shrug.

**Decision rule.** Schedule a long-session playtest, not just a first-hour
one, and log where novelty flattens. A roadmap that only adds early and
mid content while the end state is "you have everything" is incomplete.

---

## The failure modes, named

Use these words in reviews so the finding is recognizable:

| Name | What it looks like | Rule it breaks |
|---|---|---|
| **Menu play** | The interesting decisions happen in a GUI, the world is a backdrop | §4 HUD, §6 feedback |
| **Invisible mechanic** | It works, nobody could tell it exists | §3 competence, §5 discoverability |
| **Book-first teaching** | The guidebook is the first encounter | §5 |
| **Chat-only feedback** | A system message is the only sign something happened | §6 |
| **Grind as content** | Time cost with no decision inside it | §8 |
| **Treadmill** | Tier N+1 is tier N with bigger numbers | §1 |
| **Vanilla-redundant** | Vanilla already does this | §4, §7 |
| **Plays itself** | The player's presence is optional | §3 autonomy, §4 |
| **Scope creep** | Serves no pillar; "would be cool" | §7 |
| **Unbounded search** | The reward exists but nothing points at it | §4 finding vs searching |
| **Dead-space gating** | Progress blocked by waiting, not by a skill or a choice | §8 |
| **Late-game collapse** | Nothing re-presents patterns after mid-game | §1, §10 |
| **Archetype tax** | One playstyle pays for another's fun | §9 |

---

## Sources

Verified this session unless noted. The companion research report
(`docs/research/2026-10-31-mod-team-practice-and-game-design.md`) holds
the full extraction.

- Hunicke, LeBlanc, Zubek, *MDA: A Formal Approach to Game Design*, 2004. https://users.cs.northwestern.edu/~hunicke/MDA.pdf
- Rigby & Ryan, Player Experience of Need Satisfaction (PENS). https://selfdeterminationtheory.org/player-experience-of-needs-satisfaction-pens/
- Koster, *Theory of Fun, 10 Years Later*. https://www.raphkoster.com/wp-content/uploads/2026/07/Theory-of-Fun-10-Years-Later.pdf
- Jeb's design principles, secondary summary. https://gamedesignskills.com/game-design/minecraft/ (primary text not public)
- Agnes Larsson on creative joy and player goals, Linköping University profile.
- GMTK, Half-Life 2's invisible tutorial; George Fan, *How I Got My Mom to Play Through Plants vs. Zombies* (GDC 2012); Hayashida on kishōtenketsu (secondary, GMTK/MCV).
- Vlambeer, *The Art of Screenshake* (INDIGO 2013); Jonasson & Purho, *Juice It or Lose It* (secondary).
- Keith Burgun on single core mechanism and balance, Game Developer; "complex is hard to learn, deep is hard to master", Game Developer *Design 101*.
- Create mod listing and Ponder wiki. https://modrinth.com/mod/create , https://github.com/Creators-of-Create/Create/wiki/Internal---Ponder-UI
- Botania CONTRIBUTING; Vazkii interview. https://blog.curseforge.com/10-questions-with-vazkii/
- Tinkers' Construct FAQ and design docs. https://slimeknights.github.io/faq/ , https://slimeknights.github.io/docs/design/ ; mDiyo interview https://blog.curseforge.com/10-questions-with-mdiyo/
- AE2 CONTRIBUTING intake rules. https://github.com/AppliedEnergistics/Applied-Energistics-2
- YUNG interview. https://blog.curseforge.com/10-questions-with-yung/
- FTB forum, *Discussion on mod design / progression management*. https://forum.feed-the-beast.com/threads/discussion-on-mod-design-progression-management.148498/
- SevTech, Vault Hunters, Feed the Factory listings and third-party reviews (Moddex, UniversIO, MMC).
- Not verified: Soren Johnson's "players will optimize the fun out of a game" (attribution commonly given, primary not confirmed); Jonathan Blow's talks on clarity; Csikszentmihalyi's flow and Schell's lenses were not re-fetched and are cited from general knowledge.
