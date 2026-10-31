# modsmith v0.4 roadmap: from dev loop to AI-run mod studio

Status: DRAFT, 2026-10-31. Written with Joseph in the lord-of-lands session
that kicked this off. Research behind it lives in `docs/research/`.

## Why

modsmith v0.3 is a good *engineering* loop: two-lane develop, GameTest CI,
landmine index, worktree builders, engage. It has no opinion about whether a
feature is fun, no way to make or check art, no way to see the game, and the
LotL-specific knowledge it grew from still lives in that repo's CLAUDE.md
and in `~/.claude/skills/mc-mod-develop`, which has drifted from the plugin.

v0.4 turns modsmith into the single home for AI-driven Minecraft mod
development: design judgement, asset pipelines, visual verification, and
long-running autonomy, all reusable across mods. The pilot is a fresh start
on Rust and Rune.

## Decisions already made (2026-10-31)

| Topic | Decision |
|---|---|
| Audience | Joseph plus one or two brothers. Solo play is the primary target; systems should extend to multiplayer (court/king interactions) without redesign. |
| Home | modsmith. Extract everything generic out of lord-of-lands CLAUDE.md, `~/.claude/skills/mc-mod-develop`, `~/.claude/agents/mc-*`, and `~/.claude/workflows/*.js` into the plugin. Local repos consume the plugin and keep only truly project-specific notes. |
| Orchestration | One lead agent with subagents. Agent teams only for review debates or competing-hypothesis debugging, enabled per session. `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0` set by Joseph 2026-10-31. |
| Spend | Paid APIs are fine. Start at ~$20/month on a privacy.com card. Retro Diffusion account approved. |
| Art approval | Joseph approves *concept art* that sets the look (style bible anchors, major mobs, major structures). The agent creates small assets on its own against the style bible. Revisit if drift appears. |
| Distribution | Modrinth as a private project for the brothers. Modrinth's Sep 2026 policy requires an AI-content disclosure for any substantial AI assets and bans primarily AI-generated projects, so Rust and Rune (intentionally AI-generated) should ship via GitHub Releases + packwiz like lotl-modpack, with Modrinth only if the disclosure is acceptable. Record AI involvement per asset so disclosure is mechanical either way. |
| LotL design doc | Rewrite later (Phase 6). Feature cuts are on the table but each needs a stated reason against the design gate. |
| Pilot | Rust and Rune, from scratch; existing scaffold code is disposable. Joseph wants to discover the mod as a player, so autonomy is the point, not a nice-to-have. |

Name confirmed 2026-10-31: **Rust and Rune**.

## What the research changed

Full reports in `docs/research/`. The load-bearing facts:

- **Claude Code now has harness-level self-correction**: `/goal` (a separate model checks a done-condition every turn), `Stop` hooks that refuse to end a turn on red, `/verify` (build and run the app), `.claude/rules/` with `paths:` scoping, `/doctor prompt-audit`. None are in our setup. Skills replace commands; `agent-memory` is undocumented.
- **No published mod-design rubric exists**, but the raw material does: Jeb's internal design rules (no HUD, the game must not play itself, finding is fun but searching is not, items serve a purpose), Tinkers' three-use test, AE2's "already possible in vanilla" rejection, Create's "leave decisions to the player, teach by Ponder", plus MDA, PENS, Koster's mastery curve, kishōtenketsu first encounters, Fan's eight-word rule.
- **Pro teams test about as much as LotL does and art far more.** What they have that we lack: one or two human style owners with veto, datagen with a CI drift check so no JSON is hand-written, gameplay-first structure design, automated multi-platform publish.
- **Asset tooling is mostly ready; verification is not.** Retro Diffusion (Minecraft-specific texture styles, HTTP + MCP), PixelLab (attached; palette-locked 16x16 tiles, free pixel workbench), headless Blockbench MCP (create/validate/export `.bbmodel` and Java entity classes without the GUI), nbtlib for structure NBT, structura-render for six-view PNG sheets. The hole: **no in-game screenshot or isometric render path exists for NeoForge 26.1**. Fabric has one; MineClient Bridge is 1.21.1-only; Mineflayer and prismarine-viewer stop at 1.21.x, so the Rust and Rune spike harness cannot be revived.
- **Image-to-3D is a dead end for entities.** Nothing turns a mesh into a clean cuboid model with sane UVs. Entities stay agent-designed box layouts from approved concept art.
- **Nobody surveyed is ahead of this setup**, but the community has closed one real gap: MCP servers that give the model *current* source, mappings, and NeoForge-patched code so it stops guessing signatures. Adopt `MCDxAI/minecraft-dev-mcp` (patched-source diff, mapping lookup, CLI twin) and trial `vfyjxf/sourcescout` (reads the exact ModDevGradle-resolved sources jar). The 195-star `Jahrome907/minecraft-agent-skills` bundle is the de-facto community baseline and is 26.x-aware, but documents zero flake classes; diff its gotcha list against our landmines quarterly. `delvewright` is the only project with a tighter verification loop, achieved by having the LLM write schema-checked design docs that a deterministic compiler turns into artifacts, which is the right architecture for data-driven content (structure NBT, Codex pages, trade JSON) even though agent-written Java stays. MCreator 2026.3 ships a first-party MCP server; a `Wurst-Imperium` port of Fabric's client GameTest API to NeoForge 26.1 exists and is the only route to screen/render GameTests. Full report: `docs/research/2026-10-31-community-ai-modding.md`.

## Phases

Order is deliberate: design judgement and the eye come before more
generation capacity, because the complaint driving this is "technically
right, not fun, not discoverable, not pretty", not "too slow".

### Phase 0: re-baseline (1 to 2 sessions) — DONE 2026-10-31 (modsmith #10, lord-of-lands #215, tweaks-and-fixes #8)

Goal: one source of truth, current Claude Code idioms, nothing LotL-specific
left in the generic layer.

- Diff `~/.claude/skills/mc-mod-develop` against `skills/develop`; merge every post-July improvement into the plugin; retire the skill with a stub that says "use modsmith".
- Move the generic halves of lord-of-lands CLAUDE.md (GameTest harness rules, persistence, registration, wire-format, client/server isolation, logging, testing tiers, PR hygiene) into `references/` and `.claude/rules/`-style path-scoped rule templates. Leave LotL with commands, project-only landmines, and pointers.
- Port `~/.claude/workflows/{flake-hunt,mc-pr-pipeline,repo-health,release-preflight}.js` and `~/.claude/agents/mc-*.md` into the plugin where they are generic.
- Convert `~/.claude/commands/gradle-reset.md` to a skill. Make the global `bd prime` hook conditional on a beads database. Move the lotl-modpack routing line out of global CLAUDE.md.
- Add the self-correction layer as an **opt-in** `skills/guards` setup skill, never a requirement: it offers a `Stop` hook running the project's fast gate (so the harness refuses to end a turn on red), `/goal` guidance for unattended runs (a separate model checks the done-condition every turn), and `/verify` in the Lane 1 step order. Projects choose which to enable.
- Run `/doctor prompt-audit` on both repos' instruction files and act on it.
- Community adopt-now list: wire `minecraft-dev-mcp` (pinned cache dir; first decompile ~5 min) into the builder and reviewer agents as the oracle for "what does the NeoForge patch actually do here"; trial `sourcescout` for one PR cycle as the resolved-classpath source reader; add the "Contains AI-generated content" flag to the LotL Modrinth listing (required since 2026-09-27).
- Borrowed ideas to fold into references: tag each pinned version fact with an evidence tier (official Maven / blog / community); per-version rename digest at port time; "tests passed but never reached the failure" ledger entries; only one agent type may touch the running game; append-only field notes per run; version facts injected by script, never chosen by the model.

Done when: lord-of-lands CLAUDE.md is under ~200 lines, `./gradlew integrationCheck` still green, modsmith `validate.yml` green, and a fresh session in LotL invokes `/modsmith:develop` by routing alone.

### Phase 1: design layer (2 to 3 sessions) — DONE 2026-10-31 (modsmith #11; Rust and Rune bible signed, rust-and-rune #2)

Goal: the agent can tell good from bad gameplay decisions and prove it.

- `references/game-design.md`: the general fun reference. Loops at three timescales, LeBlanc aesthetics, PENS needs, Koster mastery curve, Jeb's rules as a parity check, discoverability patterns (kishōtenketsu first encounter, Ponder-style scenes, advancements as tutorial), feedback-through-the-world rule, named failure modes (menu play, invisible mechanic, book-first teaching, chat-only feedback, grind as content, late-game collapse, vanilla-redundant). Every rule cites its source.
- `references/design-gate.md`: the nine-point pre-build gate and post-build review checklist from the practice research, written as questions a builder must answer in the PR body and the reviewer must verify.
- `skills/design`: interview-driven. Produces a mod's **design bible** (`docs/design/bible.md`: player fantasy, hook, the three loops, pillars, scope gate, non-goals, discoverability plan) and per-feature **design briefs**. Includes an "orient" mode: given a proposed change, re-read the bible and answer the gate.
- Wire the gate into `agents/architect.md` (refuses features that fail it), `agents/reviewer.md` (checks the gate answers), and develop Lane 1 step 1.
- Pilot artefact: run `/modsmith:design` on Rust and Rune using the kickoff doc and the brothers' three playstyles as input. Joseph signs the bible. This is the first concept-approval moment.

Done when: Rust and Rune has a signed design bible and a backlog of design briefs, and a deliberately bad feature proposal ("add a village stats HUD") is rejected by the gate with the right citations.

### Phase 2: the eye (2 to 4 sessions) — IN PROGRESS 2026-10-31

Goal: the agent can see what it built. Everything visual depends on this,
and nothing off the shelf does it for NeoForge 26.1.

- **Evaluate first**: MCPFabric (`denfry/mcpfabric`, Modrinth) lists a NeoForge jar for 1.21.1 to 26.3 with `screenshot`, `run_command`, `set_block`, `poll_events` over a token-authed local HTTP bridge. Test it on NeoForge 26.1 before building anything. Build only what it lacks (camera pose, template place, orthographic capture).
- **Scene-driver mod**: a small, standalone, dev-only NeoForge mod in **its own repo**, built through modsmith as the first dogfooding run and consumed by projects as a dev-only dependency. It adds client commands: `/ms_shot <name> [yaw] [pitch] [fov]`, `/ms_pose <x y z yaw pitch>`, `/ms_place <template> [rot]`, `/ms_summon <entity> [pose]`, `/ms_iso <target>` (orthographic multi-angle capture), plus a loopback command socket so a script can drive `runClient --quickPlaySingleplayer`. Screenshots land in a known dir the agent reads with the Read tool. Design borrowed from MineClient Bridge; never ships to players (same `gametest` source-set discipline as LotL).
- **Palette extractor**: script over the 26.1 client jar producing per-material palette ramps (hue-clustered) as PNG strips and hex lists, for texture prompts and ImageMagick `-remap`.
- **structura-render** wiring: six-view sheet of any `.nbt` in the repo, no game boot, for cheap first-pass structure review.
- **Visual evidence rule**: any PR that adds or changes a texture, model, or structure attaches the rendered PNG(s) next to the approved concept image, and the reviewer compares them.
- Datagen plus drift-check CI template (AE2 pattern), since generated models/blockstates are where asset wiring breaks.

Done when: from a cold shell, one script boots the dev client, places a structure, captures four angles and an isometric, and the agent correctly spots a planted defect (a missing face, a floating block).

### Phase 3: asset pipelines (3 to 5 sessions)

Goal: textures, structures, and entity models from concept to in-game, with
Joseph approving only the concepts.

- `skills/style-bible`: per-mod style bible (palette hex ramps, texture philosophy, 5 to 10 anchor images, prompt fragments, negative prompts, Blockbench style-guide checklist, building order shape→palette→depth→roof→detail). Absorbs the Rust and Rune asset plan's Step 1.
- `skills/texture`: Retro Diffusion or PixelLab batch of candidates → `-remap` to the extracted palette → 3x3 tile montage → agent picks and pixel-fixes with the PixelLab workbench → in-game shot via Phase 2. Style-guide lint (ramp size, light direction, outline, banding) as a script where it can be mechanical.
- `skills/structure`: parametric Python builder → nbtlib `.nbt` → structura-render check → GameTest template load → in-game multi-angle shots → iterate. Gameplay-first brief (traversal, routes, reward placement) before any blocks. Delvewright pattern: the agent writes a schema-checked structure design doc (rooms, routes, palette roles, loot slots) and a deterministic script compiles it; the model never hand-places blocks.
- Client-side render checks: evaluate the `neoforge-client-gametest-api` port for screen and renderer GameTests alongside the scene-driver mod; the two are complementary (automated assertions vs. agent eyeballing).
- `skills/model`: agent-authored box layout from approved concept art → headless Blockbench MCP create/validate → export Java entity class or block JSON → UV template → texture skill → in-game shots from all sides. Animation intent stated in the brief and checked in motion.
- **Concept approval flow**: one decision-menu per batch of concepts, with Joseph's picks recorded in the style bible. Small assets reference an approved anchor and skip the menu.
- **Disclosure ledger**: `assets/AI-DISCLOSURE.md` (or JSON) auto-appended per generated asset: tool, prompt hash, approval status.

Done when: Rust and Rune's first block set, one structure, and one mob go concept → in-game with Joseph approving only concept art, and the in-game captures match the approved concepts to the reviewer's satisfaction.

### Phase 4: autonomy (2 to 3 sessions)

Goal: hours-long unattended runs that stay on-goal and self-correct.

- **modsmith stays project-agnostic.** The Rust and Rune autonomous-loop design (state directory, task schema, review queue, morning standup) lives in the rust-and-rune repo. `skills/engage` gains only the generic contract: it looks for a project's design bible, style bible, and state directory at conventional paths, consumes them when present, and tells the developer to create them (pointing at `skills/design` and `skills/style-bible`) when absent. The task schema's *shape* (machine-checkable validation steps per task) may be documented as a reference; the content is always the project's.
- Orchestrator contract: lead holds the bible and the backlog; every subtask prompt carries the design-gate answers and the style bible pointer; subagents return files not chat; the lead re-reads the bible at each phase boundary (the "orient" mode from Phase 1).
- Harness guards: `/goal` set to the milestone's done-condition, `Stop` hook on the fast gate, `--max-turns`/budget caps for headless runs, PR-is-the-checkpoint, never push default branch.
- Scheduled cloud task or `/loop` driver for overnight runs, with the morning standup as the human entry point.

Done when: an eight-hour unattended run on Rust and Rune ships a batch of greenlit tasks as PRs, produces a standup, and the review queue holds exactly the taste and balance decisions, nothing the gate could have answered.

### Phase 5: pilot, Rust and Rune (ongoing)

- `/modsmith:init` fresh (NeoForge, latest MC), old scaffold archived.
- Design bible (Phase 1) → style bible and first concept menu (Phase 3) → MVP milestone chosen through the gate, not by instinct.
- Joseph plays each milestone build and logs where novelty flattens, where mechanics were invisible, where UI was needed; those become gate refinements.

### Phase 6: Lords of the Lands retrofit (lowest priority)

- Run `/modsmith:design` in orient mode over the shipped v0.10.80 feature set; produce the keep/fix/cut list with gate citations; rewrite the v0.1 PDF as `docs/design/bible.md`.
- Apply the texture and structure skills to the worst-looking existing assets as a regression test of the pipeline on a mature codebase.

## Risks and how we will know

- **Instructing-form rot** (the v0.3 design principle still holds): references decay silently. Each reference gets a dated "verified against" line and the design gate is exercised by a fixture proposal in CI.
- **Taste cannot be fully automated.** The gate catches the "not a bad decision" cases; the "is it fun" cases go to Joseph via the review queue and playtests. The metric is review-queue quality, not size.
- **Vendor churn.** Retro Diffusion, PixelLab, structura-render, and the Blockbench MCP are single-vendor or single-maintainer. Every skill names its tool behind a thin script so a swap is one file.
- **Version drift.** Everything targets latest stable MC by policy; the scene-driver mod must be rebuilt on each MC bump and its CI should prove it.

## Not doing

- Teams-by-default, Mineflayer bots, image-to-3D for entities, text-to-structure models, Bedrock, Forge legacy, public Modrinth listing for an AI-generated mod without disclosure.
