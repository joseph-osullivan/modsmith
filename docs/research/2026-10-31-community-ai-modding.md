# Community AI-assisted Minecraft modding: survey (2025 – Oct 2026)

Compiled 2026-10-31. Scope: everything *except* Blockbench MCP (jasonjgardner), Retro Diffusion, PixelLab, Mindcraft, Mineflayer MCPs, structura-render, deepslate-mcp, MineClient Bridge, HeadlessMc, hairyf's texture skill, and the AE2/Create AGENTS.md files. Dates are GitHub `pushed_at` / release dates pulled via the API on 2026-10-31 unless noted. "Conf." = confidence it works as described (H/M/L), based on README depth, commit volume, and whether anything independently exercised it.

Verdict key: **ADOPT** = worth wiring into the LotL toolchain now; **BORROW** = steal the idea/pattern, not the code; **WATCH** = re-check in a quarter; **IGNORE**.

---

## 1. Agent setups aimed at Minecraft modding

### 1a. MCP servers — source, mappings, docs

**MCDxAI/minecraft-dev-mcp** — https://github.com/MCDxAI/minecraft-dev-mcp
Decompiles/indexes vanilla for a given MC version, remaps across Yarn/Mojmap/Intermediary/obf, analyzes mod JARs, validates Mixins/AW/AT, diffs versions, and (via NeoFormRuntime) builds the **NeoForge-patched source** and diffs it against vanilla (`get_forge_source`, `compare_vanilla_vs_forge`). SQLite FTS5 full-text search. 26 tools. Driven via `npx -y @mcdxai/minecraft-dev-mcp` (stdio or Streamable HTTP) plus a `minecraft-dev-cli` binary with the same tools (so it works from a Bash-only builder too). Tested versions listed through 26.1 snapshots; 26.1+ is Mojmap-only (Yarn ended at 1.21.11). MIT, 47 stars, pushed 2026-10-21. Conf. M-H (first decompile ~5 min, ~450 MB/version cache). **ADOPT** — the NeoForge-patched-source diff is exactly the "what did the NeoForge patch wrap" question the GuardShieldDrain landmine needed.

**adhi-jp/minecraft-modding-mcp** — https://github.com/adhi-jp/minecraft-modding-mcp
Same problem space, broader: 41 tools (6 workflow + 35 expert), 4 mapping namespaces, NBT encode/decode, registry-data generation, `validate-project` over a whole mod repo, 9 MCP resources. Explicit 26.1+ handling (Yarn/Intermediary requests fall back to runtime names with a warning). `npx -y @adhisang/minecraft-modding-mcp`; Node 22.13+, Java 17+ (Java 21 for 1.21.x registry gen). MIT, 8 stars, **576 commits**, pushed 2026-10-28. README admits it is "entirely vibe-coded." No Parchment. Conf. M. **WATCH / trial** — more surface than minecraft-dev-mcp but no NeoForge-patched source and less adoption; pick one of the two, not both.

**OGMatrix/mcmodding-mcp** — https://github.com/OGMatrix/mcmodding-mcp
Docs-RAG server: indexes wiki.fabricmc.net, docs.fabricmc.net, docs.neoforged.net (512+ pages), an optional **Parchment** database (param names + javadocs, 180 MB), and a mod-examples corpus (Create, Botania, AE2). `npm i -g mcmodding-mcp`; ~520 MB docs DB auto-updates on start. MIT, 70 stars, pushed 2026-08-28. Conf. M (version pinning of the indexed docs is not exposed — risk of 1.21-era answers for 26.1 questions). **BORROW** — the "fetch current docs, don't trust weights" idea is right; the LotL "vanilla feature currency" rule already covers the discipline. Only adopt if you want Parchment javadoc lookup offline.

**vfyjxf/sourcescout** — https://github.com/vfyjxf/sourcescout
Asks Gradle what is on the classpath, then exposes the *actual resolved dependency sources* (sources jars read in place via zip FS, Vineflower fallback) through a CLI (`scout`) and a stdio MCP server. Explicitly "Minecraft/MDG aware" — detects sibling `-sources.jar` for merged ModDevGradle artifacts. JDK 21+, Gradle 8+. MIT, 0 stars, created and pushed 2026-10-17. Conf. M (tiny, but the design is sound and it's the only tool that reads *your* resolved NeoForge version instead of a cached generic one). **ADOPT (trial)** — this is the right answer to "agent greps `build/` or hallucinates a signature": it reads the exact jar ModDevGradle resolved.

**HelixCraft/MC-Mapping-Reference** — https://github.com/HelixCraft/MC-Mapping-Reference
Markdown rename changelogs (1.21 → 26.2) generated from `.tiny` mappings with a Kotlin CLI (takenaka) + Python scripts; V2 detects real `old → new` renames. Written for "a coding agent (or human) that ports code." For 26.1–26.2 only Mojang/Obf exist so renames show as remove+add. No MCP; files only. No license stated; 0 stars; pushed 2026-08-07. Conf. M. **BORROW** — a per-version rename digest dropped into the repo is a cheap port-day aid; the LotL landmine index already does this by hand for the hits that mattered.

**Mai-xiyu/1-21-1--Neo-Forge-Mod-mcp** — https://github.com/Mai-xiyu/1-21-1--Neo-Forge-Mod-mcp — 20 tools of Forge/NeoForge 1.21.1 doc search + scaffolding generators + `review_mod_code` (registration, event-bus, client/server mixing). Pinned to 21.1.x, listed "inactive" on Glama, pushed 2026-09-09, MIT, 1 star. **IGNORE** (wrong version, static knowledge).

**Hayremyt/mcp-minecraft-forge** (Forge 1.12–1.21 docs, AGPL, 3 stars, 2026-10-10), **spudmashmedia/neoforge-kb-mcp** (NeoForge doc ingest, MIT, 2 stars, 2026-06-14), **AnCarsenat/minecode-mcp** (https://github.com/AnCarsenat/minecode-mcp, PyPI 0.2.2 2026-08-16, GPL-3, ~30 tools: version-exact command grammar validation, Spyglass registries/schemas, Misode presets, Wiki search, Mojira search, local log tailing). minecode-mcp is **BORROW/WATCH** for datapack-heavy work (its "validate every command against the pinned command tree" tool is the one piece worth having); the other two **IGNORE**.

### 1b. Dev-loop MCPs (run the game, read logs, screenshot)

**InventivetalentDev/minecraft-mcp** — https://github.com/InventivetalentDev/minecraft-mcp — Node MCP ↔ WebSocket ↔ Java component. Paper side: tail/subscribe logs, console commands, install/hot-reload plugin, reflection calls, Javadoc search. Fabric client side (targets **MC 26.1.2 / Java 25 / loom 1.16**): chat, player state, move/look/break/place, nearby entities, base64 screenshots, client-side reflection. MIT, 14 stars, pushed 2026-05-07. Conf. M-H. **BORROW** — a client-side screenshot + log-subscribe tool is the one thing the LotL loop lacks for render/GUI work; everything else is already covered by runClient/GameTest.

**VladMineModDev/qwen-idea-mcp** — https://github.com/VladMineModDev/qwen-idea-mcp — 26 tools: file edit with backups, Gradle tasks, background `runClient` with status/stop, `latest.log`/crash-report regex reading, screenshots of MC/IDEA, window focus + keypress/click. NeoForge 1.21.1 primary; Windows-centric (tasklist/taskkill). MIT, 0 stars, created 2026-10-02. Conf. L-M. **IGNORE** (platform-locked), but note the hard rules in its README ("always run runClient in background; compileJava before launch") mirror ours.

**denfry/mcpfabric (MCPFabric)** — https://modrinth.com/mod/mcpfabric, https://github.com/Etoryx/mcpfabric (23 stars) / denfry fork (14) — 50+ tools over a local token-authed HTTP bridge: `run_command` with captured output, `screenshot`, `describe_scene`, `set_block/fill_blocks/get_blocks_region`, `poll_events` (damage/death/chat/spawn). **1.21.1–26.3**, Fabric documented, NeoForge jar listed; Java 25 on 26.x. MIT, 5.6K downloads, updated mid-Oct 2026. Conf. H for Fabric, M for NeoForge. **WATCH** — the only live-game bridge that already runs on 26.3. If a client-side NeoForge bridge is ever wanted, start here rather than writing one.

Also seen, all gameplay-agent oriented rather than dev-loop: ArchitektSpeer/mc-agent-mcp (1.21.11), s00d/minecraft-mcp, Aodaruma/mcmcp (client-only NeoForge, MPL-2), dev-willbird1936/Lodestone, Byntham/agents.mc (26.3, runs on Claude Code login), chapmanjw/minecraft-java-fabric-claude-plugin (28 build skills, 1.21.11–26.3, 8 stars, pushed 2026-10-30). **IGNORE** for mod development.

### 1c. Claude Code / Codex skills and plugins

**Jahrome907/minecraft-agent-skills** — https://github.com/Jahrome907/minecraft-agent-skills
13 skills, dual-target (`.agents/skills` for Codex, `.claude/skills` + plugin marketplace for Claude Code). MIT, **195 stars**, created 2026-03-08, release v2.5.4 **2026-10-30**, reviewed against 26.3/Java 25. Read in full: `minecraft-modding` is genuinely 26.x-aware — "Do not copy the 1.21.11 mapping, Loom plugin, remapping task, or Java 21 snippets into a 26.x project", Fabric 26.x key-before-object for properties, singular vs plural data paths, `Identifier` vs `ResourceLocation`, client-only rendering classes. `minecraft-testing` covers NeoForge 26.x **data-driven `test_instance` JSON + `BuiltInRegistries.TEST_FUNCTION`**, `runGameTestServer` exit codes, Fabric `src/gametest`, Java pinned per lane, "mocks don't prove runtime." Gaps: **no flake strategy at all**, no CI workflow file, Fabric 26.x not pinned, some "Codex should generate" leftovers. Conf. H (as prose). **BORROW** — it is a good generic baseline but strictly behind the LotL CLAUDE.md on the specific landmines (entity-section index lag, tickCount, placeAt, cold-cell createPath), and it has nothing on flake triage. Worth diffing its NeoForge gotcha list against ours once per quarter to catch anything new.

**AIKUSAN/minecraft-agent-skills-bundle** — https://github.com/AIKUSAN/minecraft-agent-skills-bundle — independent (not a fork), 8 stars, MIT, created 2026-05-22, pushed 2026-10-03; listed on skillsdirectory as "Minecraft Testing (Grade A)". Same shape as Jahrome907 with a server-admin/crossplay tilt. **IGNORE** in favour of Jahrome907.

**chouzz/minecraft-mod-dev** — https://github.com/chouzz/minecraft-mod-dev — Claude Code plugin (`/plugin marketplace add chouzz/minecraft-mod-dev`), NeoForge+Fabric, "fetches latest docs," JEI/AE2/Create integration guides, Data Components / datagen / convention tags. 24 stars, no license, pushed 2026-08-07, nothing on testing or mappings. **IGNORE** (superseded by Jahrome907).

**slashdaemon/minecraft-mod-expert** — https://github.com/slashdaemon/minecraft-mod-expert — one person's "source of truth" skill: per-version-band toolchain coordinates with **confidence ratings per fact** (official Maven / blog / community), MojMap vs Yarn vs Parchment, Loom non-remap mode on 26.x, ordered porting checklist, Mixin compat per band. 1 star, created 2026-09-10. **BORROW** the idea of tagging each pinned coordinate with its evidence tier — a cheap upgrade to the landmine index's "verified live for 26.1.x" line.

**rehan-remade/universal-modder** — https://github.com/rehan-remade/universal-modder — "Point Claude at any game." MIT, **9,266 stars**, created 2026-09-30, pushed 2026-10-31. Plugin with three subagents (`mod-orchestrator`, `mod-game-worker` — the only one allowed to touch the running game — and `mod-offline-worker`), a `um` CLI (install recon, fal asset generation, sprite processing, Windows input/screenshots, save backups, publish checks), and a knowledge base where each run writes a "field note for the next agent." Minecraft reference (`references/engines/minecraft.md`): dense on Forge/Fabric 1.20.1 gotchas (config TOML truncation, JOIN-event ordering, UseBlockCallback), recommends GameTests on a real server + scripted dev client + release-jar check, "gate self-tests behind a Gradle property", cites a Thaumcraft 4 port with 323 GameTests. 26.x content is thin (only GTA-passthrough render pitfalls). Conf. H as a framework, M for Minecraft specifics. **BORROW** — two ideas worth taking: (1) the game-worker / offline-worker split (only one agent type may launch the game), and (2) field notes as an append-only KB. Not a replacement for anything in the LotL setup.

Lower-signal skills (all 0–5 stars): Riloox/minecraft-mod-builder (scaffold + runClient walkthrough, no license), mrquentin/minecraft-skills (Forge/NeoForge/GTCEu + **Bedrock** GameTest, MIT, 2026-04-25), Extez61/minecraftdevelopment-skill (Fabric/NeoForge/Paper, 1.21.1–26.2, MIT, 2026-10-28, admits "exact API versions still require verification"), Just8it/minecraft-modding-skill, gate-guardian/skills, DarkSack/minecraft-models-skill (Python cube-spec → Java item models + `.bbmodel` + Bedrock, MIT, 2026-10-30 — **WATCH** as a code-first alternative to Blockbench for simple models), shrimpwagon/ai-minecraft-mobs-creator (NeoForge 1.21.1 scaffold with CLAUDE.md "landmines" + Blender-socket model pipeline + codex-CLI textures, MIT, 2026-09-15). **IGNORE** except as noted.

### 1d. Templates / AGENTS.md

**MCAgents-Mods/template** — https://github.com/MCAgents-Mods/template — multi-loader client-mod template where `AGENTS.md` sends the agent to a self-deleting `PROMPT.md` that renames placeholders. MIT, 0 stars, pushed 2026-10-31. **BORROW** the self-deleting bootstrap prompt if you ever template a new mod. No dedicated `.cursorrules` Minecraft template exists; Copilot now reads `AGENTS.md`/`CLAUDE.md` natively (GitHub changelog 2026-06-23), and Kiro has no Minecraft steering examples. Nothing found for Kiro/Codex specifically.

**Fabric's official position** — https://wiki.fabricmc.net/tutorial:using_llms (earthcomputer, last edited 2026-05-16): LLMs "often mix up Minecraft versions and modding platforms", fill gaps with invented choices, beginners should not generate code; experienced devs should feed APIs/examples and encode style in `AGENTS.md`. No tooling recommendations. Useful citation for policy, nothing to adopt.

---

## 2. AI inside established tools

**MCreator 2026.3 — built-in MCP server (confirmed in source).** https://github.com/MCreator/MCreator has `src/main/java/net/mcreator/io/mcp/{McpServer, HttpMcpTransport, tool/McpTool…}` with commits 2026-10-11 ("Minor MCP improvement"), 10-21 ("Fix typo in find references MCP tool"), 10-27 ("Broken references finder"). Pylo's announcement (x.com/PyloDEV/status/2099589083022454875): "optional local MCP server, allowing users to connect compatible agents for easier workspace troubleshooting, help, and debugging." First 2026.3 snapshot (~2026-09-20) lists tools for mod-element create/edit, workspace queries, templates, tags, variables, console troubleshooting, source reading, pack-maker. HTTP on localhost. Conf. H that it exists; M that it is stable (snapshot). Earlier community forerunners: modpotato/MCreatorMCP (MIT, 2025-09), Cmmdx256/MCreatorMCP_Extended (GPL-3, "170 low-level tools", 2026-08-20), erivgout/mcreator-mcp (2026-08-11, bearer-token bridge, read-only mode). **IGNORE** for LotL (no MCreator in the stack) but this is the single most significant "AI in an established tool" shipment of the year.

**Blockbench** — no first-party AI. Community MCPs besides jasonjgardner's: sosadly/blockbench-mcp (MIT, 53 stars, pushed 2026-10-28, Claude Code/Desktop/Cursor), vasyacullin/Blockbench-mcp (texture fill/import + render-for-review loop), enfp-dev-studio/blockbench-mcp (MIT, 33 stars, stale 2025-07). **IGNORE** (already covered by the known jasonjgardner server).

**KubeJS** — no official LLM helper. **KubeJS Studio** (CurseForge, Sept 2026) is an in-game pack-aware script editor, not AI. LLMjs (1.20.1, June 2025) connects scripts *to* LLMs. **MineClawd** (https://github.com/Zhou-Shilin/MineClawd, Apache-2, 67 stars, 1.20.1–1.21.1 Fabric/Forge/NeoForge, last push 2026-03-17) generates and executes KubeJS JS from chat — the nearest thing to "NL → KubeJS", runs generated code with OP. **IGNORE**.

**Axiom** — no AI feature in 6.1.x (26.3 builds, Oct 2026). Blueprints are searchable schematics only. **IGNORE**.

**Figura, WorldEdit/FAWE** — nothing first-party. Lucas-Buckley/mcp-worldedit-craftscript (MIT, 2026-08-08, NeoForge + WE 7.3: agent writes a CraftScript, `inject_craftscript`, `run_craftscript` as a verified player, undo) — one end-to-end test on record. **IGNORE**.

**Mojang** — Minecraft Live 2026-09-26 announced a "Creator Platform" (build/manage/share content); no AI tooling and no Java specifics. Mojang's earlier no-gen-AI-in-development stance stands. Platform policy that *does* matter: **Modrinth** (effective 2026-08-13, grace ended 2026-09-27): substantial AI code/assets require a "Contains AI-generated content" disclosure; primarily-AI projects are unlisted from search; AI images banned on project pages. Nexus added a tag. **Action item**: LotL's Modrinth listing needs the disclosure flag.

---

## 3. End-to-end mod / datapack generators

**stellarfeline/delvewright** — https://github.com/stellarfeline/delvewright — the one serious project. Claude Code plugin (`/delvewright:new-delve`) + Rust CLI `delvec`: story prompt → schema-checked staged JSON design docs → vanilla **1.21.11 datapack** with quests/NPCs + server image. Validation: every generated command parsed against the pinned command tree; quest-path walk; **PackTest "All 338 required tests passed"** on a real server; a Mineflayer bot plays the critical path; byte-identical deterministic builds checked in CI on Linux + macOS. GPL-3 code, CC-BY-SA campaigns. 13 stars, **2,658 commits**, pushed 2026-10-31. Conf. H. **BORROW** — the "LLM writes design docs, deterministic compiler emits artifacts, GameTest/PackTest + bot gate the output" architecture is the strongest pattern in the whole survey and maps directly onto Tier-2/Tier-3 in LotL.

**Zhoumy303/ModSmith** — https://github.com/Zhoumy303/ModSmith — NL → typed JSON blueprint → hand-written templates → `./gradlew build` with ≤3 LLM repair cycles → launch MC and parse logs for registration → zip+jar. Fabric only, items/food/tools only, web UI, Zhipu GLM. 0 stars, 20 commits, pushed 2026-10-04, no license. Conf. M (demo video, 12 test files). **BORROW** the runtime-log registration check as a cheap post-build smoke; otherwise IGNORE.

**hcyinnn/ai-mcmods-generator** — https://github.com/hcyinnn/ai-mcmods-generator — FastAPI web app, 17 versions 1.20.1–26.2 × Forge/NeoForge/Fabric, any OpenAI-compatible LLM; **versions resolved by a deterministic registry and injected as facts, `gradle.properties` placeholders filled by the backend** "so the AI never invents version numbers"; per-loader prompt ends in an anti-hallucination checklist. MIT, 0 stars, single commit 2026-09-01. **BORROW** the hard separation of version facts from the model.

**marcusgreenwood/vibecraft** — https://github.com/marcusgreenwood/vibecraft — Fabric 1.21.8 demo: `.cursorrules` TDD loop (tests in `TestCommand.java`, `./run-test.sh` drives the real client via `java.awt.Robot`, types `/runalltests`, parses logs). MIT, 29 stars, pushed 2026-06-28. Honest but primitive (hardcoded "4/4" success string; try/catch hides causes). **IGNORE** — GameTest already does this properly.

Commercial "AI mod maker" sites (CreativeMode — YC S24, Java+Bedrock jar output; player.games; EnderDevelopment/Kodari/StackNests for plugins; ModCrafter for datapacks; BlockGPT/Structmatic/Spaleforce/BlockArchitect for builds): all evidence is vendor blogs, Trustpilot, or one-prompt self-comparisons. No neutral benchmark exists. **IGNORE**.

**Academic**: no 2025–26 paper synthesizes Fabric/NeoForge mods or datapacks, and no LLM benchmark targets modding code. Nearest: *Agents in the Sandbox / BugCraft* (arXiv 2503.20036, ASE 2025) — LLM crash-report → S2R steps → vision agent reproduces crashes in vanilla, 30–35% end-to-end, with a curated BugCraft-Bench (useful shape for a "reproduce this bug report" eval); *GameASG-Bench* (2609.21293, Sept 2026) — browser games, pre-fixed evaluation interfaces, strict success 55%; PillagerBench (agents, not code). **Gap confirmed**: nobody has published compile/GameTest pass rates for LLM-written NeoForge code.

---

## 4. Community lessons (concrete, sourced)

- **maxleiter.com/blog/vibecoding-minecraft-mods** (2025-06-21; Cursor+o3, Claude Code, Codex CLI; 1.12.2, ~$8 total): targeting an old, mod-rich version was the main success factor because "LLMs are trained across all the versions"; o3 missed a client-only annotation and only fixed it after a real build; auto-injected rules files stopped agents grepping `build/`; wants errors that suggest fixes and version-pinned doc tooling.
- **cmdralph/Fabricated** (GPL-3, Fabric-on-NeoForge layer, 1.21.11 → 26.3, pushed 2026-10-31; PRs carry Claude co-author trailers; `docs/claude.md`, `docs/MIXINS.md`, `docs/progress.md`): NeoForge keeps old constructor signatures as deprecated delegates, so a `<init>` inject without a descriptor can land on the one the game never calls; name-only selectors pick wrong overloads → always use descriptors; find targets by the calls they make, not local names (differ per build); require `@Overwrite` in every mixin config or a same-signature merge silently replaces; keep a mixin inventory per version; **"passing tests don't prove a fix"** — recorded cases where tests never reached the failure; log every stage of a behaviour gate; keep an explicit "unverified on Windows/parallel" ledger.
- **Fabric wiki `using_llms`** (2026-05-16): version/platform confusion and gap-filling invention are the two canonical failures; encode preferences in `AGENTS.md`.
- **minecraft.how** review of Jahrome907 (2026-08-31, upd. 10-14): version lane must be explicit or the agent assumes latest; `minecraft-imagegen` silently produces placeholders on hosts without image tools; single-maintainer risk.
- **Jahrome907 testing skill**: the data-driven 26.x GameTest model is now the community-documented default; nobody documents flake classes.
- Reddit/HN/YouTube: no substantive first-person write-ups surfaced in 2026 beyond the above — the field's lessons live in repo docs and PR bodies, not posts.

## 5. Text/image → build

Confirmed and active: **AIbuilder** (CurseForge, Fabric, LGPL-3, files for 1.20.6 → **26.2**, updated 2026-08-11, multi-provider LLM, output lands as a **Litematica projection**); **BuildGPT** (Modrinth/CC0, Fabric/Quilt, versions through 26.2, updated ~Apr 2026, ChatGPT → bound/unbound placement, 15.7K downloads); **Fyzugx-Lab/Minecraft-AI-Build-Assistant** (Fabric 1.21.11, NL → Groovy build code → preview → `/fill`, CC0, 2026-07-17); **amenti-labs/vibecraft** (MIT, 105 stars, 1.20.1–1.21.4, agent → MCP → WebSocket → client mod, last push 2026-01-18); **CyniaAI/BuilderGPT** (Apache-2, 164 stars, .schem/.mcfunction out, paused 2026-02 in favour of MineClawd); hosted BlockGPT (.schem/.litematic/.mcstructure, $9–49/mo), Structmatic (.schem/.litematic/.nbt/.mcstructure, one-time packs), Kodari, Spaleforce — none state block-ID version or expose an API. For LotL's court/village NBT work, **IGNORE** all; structura-render + hand-built NBT remains better than any of these for jigsaw-compatible structures.

## 6. Agentic in-game testing beyond Mineflayer

Nothing public uses an LLM to *write* GameTests as a product. Closest: **delvewright** (PackTest + Mineflayer gate on generated datapacks); **zoyluoblue/mc_aiplayer / AIBot** (Fabric 1.21.3, MIT, 156 stars, 2026-09-02 — LLM plans, deterministic tasks execute; 3 GameTests in an isolated source set; opt-in billed "LLM story tests"); **Wurst-Imperium/neoforge-client-gametest-api** (unofficial NeoForge port of Fabric's **client** GameTest API, Gradle plugin `0.1.0+26.1.2` making `src/gametest` a separate jar with `runClientGameTest`, 1 star, 2026-06-17) — **WATCH**: the only route to client-side (screen/render) GameTests on NeoForge 26.x, which LotL has none of; **BugCraft** (above) for crash-report reproduction; kevinnie2003/playtest-agent (generic, found that scripted oracles did most of the work). Leebeargangman test-players (Paper 1.21.11 mannequins, Ollama-driven) is load testing only.

---

## (a) Adopt-now shortlist (ranked)

1. **MCDxAI/minecraft-dev-mcp** — NeoForge-patched-source diff + mapping lookup + CLI twin; wire into the builder/reviewer agents for "what does NeoForge actually wrap here" questions. Pin a cache dir; first decompile is slow.
2. **vfyjxf/sourcescout** — read the exact resolved ModDevGradle sources via CLI/MCP; kills the grep-`build/`-or-guess failure mode. Trial for one PR cycle; tiny project, so vendor the jar if it works.
3. **Modrinth AI disclosure** — policy, not a tool: add the "Contains AI-generated content" flag to the LotL listing (required since 2026-09-27).
4. **Wurst-Imperium/neoforge-client-gametest-api** — trial only if a client-side GameTest tier (Codex screens, renderers) is wanted; otherwise WATCH.

## (b) Borrow-the-idea list

- **delvewright**: LLM writes schema-validated design docs; a deterministic compiler emits artifacts; PackTest + bot gate; deterministic byte-identical builds checked in CI.
- **cmdralph/Fabricated**: mixin inventory per version; descriptor-qualified injection targets; "tests passed but never reached the failure" ledger with severities; log-every-stage behaviour gates.
- **slashdaemon/minecraft-mod-expert**: tag each pinned version fact with an evidence tier.
- **universal-modder**: only one agent type may touch the running game; append-only field notes per run.
- **hcyinnn / ModSmith**: version facts injected deterministically, never model-chosen; post-build runtime-log registration smoke.
- **HelixCraft**: per-version rename digest at port time.
- **InventivetalentDev**: client screenshot + log-subscribe tool for GUI/render PRs.
- **Jahrome907**: quarterly diff of its NeoForge gotcha list against the landmine index.

## (c) State of the art

Nobody surveyed is meaningfully ahead of a setup that already has a two-lane develop skill, GameTest CI with a flake ledger, a bug-traced landmine index, and worktree builders. The community's center of gravity in 2026 is (i) MCP servers that make *current* source, mappings and docs available so the model stops guessing — a real gap that minecraft-dev-mcp and sourcescout now fill well enough to adopt — and (ii) prose skill bundles (Jahrome907 at 195 stars is the de-facto standard) whose 26.x awareness is good but whose testing guidance stops at "run `runGameTestServer`"; none of them documents a single flake class, entity-section index lag, or cold-cell pathing, which the LotL index does. The only project with a tighter verification loop than LotL's is delvewright, and it achieves it by generating datapacks from a deterministic compiler rather than letting the model write Java — an architecture worth borrowing for data-driven content (court NBT, Codex pages, trade JSON) but not a replacement for agent-written mod code. MCreator shipping a first-party MCP server and Modrinth's disclosure regime mark the year's institutional shifts; academia has not touched mod-code synthesis at all, so a published NeoForge compile/GameTest-pass benchmark would be first of its kind.
