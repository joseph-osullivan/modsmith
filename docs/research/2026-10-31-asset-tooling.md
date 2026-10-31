# Minecraft mod asset tooling for an autonomous agent — survey (2026-10-31)

Target: NeoForge 26.1.x, 16x16 textures, cuboid entity models, NBT structure templates. Agent runs on macOS with CLI/Python/Node/MCP. Each entry says how it is driven and whether it was confirmed. "Confirmed" = repo/PyPI/vendor page read this session; "unverified" = secondary sources only.

## A. Textures

### AI pixel-art generators

- **Retro Diffusion** — https://github.com/Retro-Diffusion/api-examples (confirmed alive, 2026 footer, 147 commits). The only generator with Minecraft-specific styles: `rd_plus__mc_texture`, `rd_plus__mc_item`, plus `rd_fast__*` and `rd_mini__*` variants. HTTP API at `https://api.retrodiffusion.ai/v2/inferences` (header `X-RD-Token`, async job + poll `GET /v2/inferences/tasks/{id}`), `tile_x`/`tile_y` booleans for seamless faces, batch up to 16, sizes 12–512 with per-style limits via `GET /v2/styles/selector`. Pricing: RD Fast $0.03, Plus/Mini $0.06, Pro $0.18 per image; `check_cost` is free. Hosted MCP server at `https://mcp.retrodiffusion.ai/mcp` (Authorization: Bearer, 33 tools). Paid service; API-examples license not stated. Also resold inside Scenario.com. Prompting rule from their docs: describe the subject, never write "pixel art".
- **PixelLab** — hosted MCP, already attached to this Claude Code session. Confirmed via its own help tool: `create_tiles_pro(tile_size=16, tile_type="square_topdown", palette=[...])` is the seamless-tile path and accepts a fixed hex palette; `create_image_pro_flash(width=16, height=16, no_background=true, palette=[...])` for items; `create_image_pixen` does 16x16 but no palette lock; `create_image_pixflux` rejects 16x16 (min 32x32). Free deterministic tools: `pixelart_workbench` (inspect/draw/edit pixels by command line), `reduce_colors` (quantize to N colors or a palette image), `correct_pixelart`, `image_to_pixelart`. No Minecraft style preset; subscription/credits. Setup page: pixellab.ai/vibe-coding. Community alternatives exist (PixelLabRat local app, PixelLab Forge MCP) but the official hosted server is enough.
- **Scenario.com** — hosts Retro Diffusion models including "Retro Diffusion Tile" (16x16–64x64 seamless), a tileable "Scenario Texture" PBR generator (help page updated June 2026), and a Pixelate tool with an API section. Not Minecraft-specific; API parameters unverified.
- **Open-weights LoRAs / finetunes** — `yuuki14202028/minecraft-item-16px` on Hugging Face (SD1.5 full finetune, items only, trained on 16x nearest-neighbour upscales, generate 256px then downscale; block textures deliberately excluded), `AnimeOverlord/flux2-klein-4b-mc-v3` (Flux2 klein LoRA, unverified), `yardenzo60/12` and `/25` DreamBooth LoRAs (stub model cards, trigger "Minecraft-style texture"). Driven locally via diffusers/ComfyUI. No Civitai results surfaced. Quality unverified; treat as experiments.
- **Vendor web tools** — Morgana "Nimue" texture generator, Deep-Pixels / AI MC Texture, SeaArt Minecraft texture generator. GUI/web, account-gated, no API found. Skip.

### Downscale / quantize / cleanup

- **ImageMagick** — `-colors N +dither -remap palette.png` recipes; mature, CLI, free. Caveat from the forums: `-remap` reorders/dedupes the palette and quantized colours may not exist in the source, so build the palette image explicitly and use `+dither` / `-dither none`.
- **Aseprite CLI** — `aseprite --batch in.png --color-mode indexed --save-as out.png`, `--scale`; paid but fully scriptable; an `aseprite-cli` npm wrapper and several Aseprite MCP servers exist. **MC Toolkit** (dev7432.itch.io/mc-toolkit) is an Aseprite extension adding 16x16 tiling check and colour-variant generation.
- **Pyxelate / Super Pyxelate** (Python, github.com/sedthh/pyxelate lineage) — edge-aware downscale with learned palette and palette transfer; slow; no CLI (trivial to wrap).
- **hairyf "minecraft-texture" skill** (skills.sh/hairyf/skills/minecraft-texture, 26 stars) — image model → `scripts/mc_texture.py pipeline --sizes 16,32` dominant-colour-per-cell sampling → white-to-alpha → `check` (stray near-white pixels, transparency ratio). No tiling check, no palette lock. Small but exactly the agent-shaped recipe.
- **Direct authoring** — at 16x16 the agent can write pixels itself (PIL script or PixelLab workbench) from a 3–5 step palette ramp. Underrated; no tool needed.

### Palette matching vanilla

- **Blockpedia** (Rust crate 0.1.9, 2026-05-13, MIT, docs.rs/crate/blockpedia) — per-block colours extracted from textures for 472 blocks (351 direct, 154 inherited), RGB/HSL/Oklab/Lab, gradients (linear RGB, HSL, Oklab, Bezier), GPL/ACO/CSS export. Data is **1.20.4**; CLI is an interactive TUI; no Python bindings.
- **Palettinator** (Fabric mod + palettinator.com), **Colorflow** (CIEDE2000 colour→block, gradient workspace), **Chroma Studio**, **Blockpalette Studio**, **BlockGradient** (PaletteBuilder plugin) — in-game or web block-gradient tools. GUI-driven; useful as reference, not automation. blockpalettes.com did not surface in results; unconfirmed.
- No tool extracts vanilla *texture* palettes per material family. A 30-line script over the 26.1 client jar `assets/minecraft/textures/block/*.png` (unique colours, cluster by hue, emit ramps) covers it.

### Most promising pipeline (A)

Retro Diffusion `mc_texture` / `mc_item` via its MCP (tiling on for block faces, batch 8–16 candidates) → ImageMagick `-remap` to a palette extracted from the vanilla textures the block sits beside → 3x3 tile montage → agent reads the PNG and picks/edits → PixelLab `correct_pixelart` / `pixelart_workbench` for pixel-level fixes. PixelLab `create_tiles_pro` is the fallback generator when the Retro Diffusion style drifts.

## B. Entity / block models

- **Blockbench 5.x** — 5.0 "The Element Update" (armatures, weight brush, splines, redesigned UI, partial TypeScript, **plugin API breaking changes**); 5.0.5 added a Java block/item format with no rotation limit; 5.0.6 added a default Java format-version setting; 5.2.0 is in beta. The `.bbmodel` format (blockbench.net/wiki/docs/bbmodel) is JSON but **officially has "no complete specification" and "may be subject to breaking changes"**; the wiki points at `js/formats/bbmodel.js`. 5.0 split group storage into `groups` + `outliner`; 4.10 made texture paths relative to the file; 4.9 added per-texture UV size; 5.0 fixed inverted keyframe X/Y. Writing `.bbmodel` directly is feasible (cube: `type`, `uuid`, `from`, `to`, `origin`, `faces[face].uv` as `[u1,v1,u2,v2]`, `texture` = index into textures array) but pin a `format_version` and verify by loading in the headless tool below.
- **jasonjgardner/blockbench-mcp-plugin** — https://github.com/jasonjgardner/blockbench-mcp-plugin (594 stars, GPL-3.0, 306 commits, confirmed). Two modes. (1) Desktop plugin, HTTP at `http://localhost:3000/bb-mcp`, needs Blockbench open; includes a `risky_eval` JS tool (disable it). (2) **Headless stdio server, shipped from v1.9 onward**: `npx -y github:jasonjgardner/blockbench-mcp-plugin --root ./models` (npx installs its own Bun), register with `claude mcp add`; `headless/call.ts` runs one tool call without an MCP client. Tools: model info/outline/search/node lookup; `bbmodel_create`, `bbmodel_edit` (atomic batch: groups, cubes, face UVs, textures, PBR materials, animations, keyframes, locators, particle keyframes), `bbmodel_add_texture`; mesh editing (Generic format only); Snowstorm particles; geometry validation, self-test, animation sampling for clipping/detached limbs; **exports: Bedrock geo + animation JSON, Java block/item JSON (with import), Java entity classes for Forge and Fabric**, legacy 4.x copy; single/multi-view PNG renders (needs GPU, Node ≥ 23.6 with npm, ~130 MB first-run download of three/three-blockbench/Dawn; PNG textures only). Concurrency via revision checks and lock files. Caveats: GeckoLib is only a validation rule, not a dedicated export; Blockbench does not hot-reload files edited on disk; non-cube/mesh/group/locator elements are preserved but not editable; writes AI-disclosure fields by default (can disable). Companion skills: github.com/jasonjgardner/blockbench-mcp-project (modeling, texturing, overview). This is the single most useful model tool found.
- **Other Blockbench MCPs** — sosadly/blockbench-mcp (Node bridge, plugin on port 8787), enfp-dev-studio/blockbench-mcp (Socket.IO, port 9999, README warns it can execute code inside Blockbench). Need the GUI; less mature.
- **No official headless Blockbench** — JannisX11/blockbench issue #1764 (headless bbmodel → geo.json/animation.json) remains open. The headless MCP above is the de facto answer.
- **GeckoLib** — GeckoLib 5.5.x targets NeoForge 26.1.2 (via MCreator "GeckoLib Reborn" plugin notes; 26.2 build 5.5.3 dated 2026-06-27 on a hosting mirror; mapping unverified from an official source) and requires the current "GeckoLib Models & Animations" Blockbench plugin. `.geo.json` is a stable, well-known format an agent can write directly. Vanilla `ModelPart` / `LayerDefinition` Java is equally hand-writable (this repo already does it) and the headless exporter emits it.
- **Blender route** — `ahujasid/blender-mcp` (PyPI `blender-mcp`; one vendor blog claims a 2026-09-16 rename to `ahujasid/mcp-for-blender` / `mcp-for-blender`, single competing-vendor source, unverified), **Mcblend** (Nusiq/mcblend, Bedrock-only cube/polymesh export, Blender 4.5, last push 2026-03-24), `jlampel/voxelize` add-on (objects → textured cubes), built-in Remesh "Blocks" modifier. Works but heavy and ends in Bedrock or mesh formats, not Java cuboids. Blockbench OBJ import is lossy; the Kinetic plugin adds drag-drop OBJ import but no voxelization; Voxel Importer handles `.vox` only.
- **Image/text → 3D → blocks** — Meshy has an official MCP (`@meshy-ai/meshy-mcp-server`, source meshy-dev/meshy-mcp-server, `meshy_image_to_3d`, multi-image, texture refine); Tripo via community `tripo-ai-mcp-server` (`image_to_3d`, needs API secret) or Go `trident-mcp`; Hunyuan3D locally via `hy3d-mcp` (Hunyuan3D-MLX on Apple Silicon, Tencent community license — check before commercial use). Civitai's orchestration docs default to Hunyuan3D as cheapest. All output GLB meshes; voxelizing to Minecraft blocks is `trimesh.voxelized()` in Python. **Nothing converts a mesh into a low-element Blockbench cuboid model with sane UVs**; that step is manual/agent-designed.

### Most promising pipeline (B)

Agent designs cuboid layout in text (box list in pixel units, pivots, parent groups) → headless Blockbench MCP `bbmodel_create` / `bbmodel_edit` → validation tool → export Java entity class (vanilla `ModelPart`) or Java block JSON → box-UV texture template → texture pipeline (A) → headless render PNG or in-game shot (D) for review. Skip image-to-3D for entities; it fights the cuboid style and vanilla proportions.

## C. Structures / builds

### Writing structure files programmatically

- **nbtlib** (Python) writing the vanilla structure template format directly: `size`, `palette` (list of block states), `blocks[{pos, state, nbt}]`, `entities`, `DataVersion`. Zero intermediate formats; loads via `/place template` or `StructureTemplateManager` in GameTest. Recommended. `StructureTemplate` constants in mappings.dev confirm the key names.
- **mcschematic 11.4.4** (PyPI, 2026-02-07, Apache-2.0, github.com/Sloimayyy/mcschematic) — `MCSchematic().setBlock((x,y,z), "minecraft:stone")`, `save(folder, name, Version.JE_x)`, `MCStructure` transforms (translate/scale/rotate/center). Sponge `.schem` only; the version enum covers Java releases since 1.9 — check it has 26.x constants before relying on it.
- **litemapy 0.11.0b0** (PyPI, 2025-06-14, GPLv3, github.com/SmylerMC/litemapy) — `.litematic` read/write via `Region` / `BlockState` / `Schematic`. Beta, GPL.
- **amulet-core 1.9.51** (PyPI, released 2026-10-30, Python ≥ 3.11, amuletmc.com) — confirmed alive: 1.9.47 "fixes the block format for Java 26.3", 1.9.46 updated Java format version, Sponge schem and mcstructure v2.1 support; 2.0 is still alpha (2.0.11a1, Oct 2026). Heavy dependency (NumPy, Amulet_NBT, PyMCTranslate) but the only Python lib tracking current Java formats.
- **nucleation 0.12.0** (Rust; `pip install nucleation`, wheels CPython 3.12+; `npm install nucleation`; 2026-10-23, MIT, github.com/Schem-at/Nucleation) — `Schematic.create/set_block/save_to_file/load_from_file`, `.schem` / `.litematic`, data-version migration, Java↔Bedrock translation; GLB/glTF/USDZ export; **GPU rendering excluded from the published wheel** (source build with `rendering` feature).
- **structura-core** (PyPI 0.3.0) — structure parsing used by structura-render; API for building structures not documented.
- **nbtschematic** (PyPI 0.2.0) — legacy MCEdit `.schematic` only; skip.
- **Axiom `.bp`** — proprietary, no public byte-level spec (axiomdocs.moulberry.com only describes it as metadata-rich blueprints in `.minecraft/config/axiom/blueprints`). Skip.

### Image / mesh → blocks

- **ObjToSchematic** — 2.0 is web-only (objtoschematic.com, no documented API); the GitHub 1.0 code (github.com/LucasDower/ObjToSchematic, frozen, last push 2025-04-28, "will no longer receive updates") had a headless launch option and exports `.nbt` / `.schem` / `.litematic` / `.schematic`. Usable from Node, but block palette data is 2023-era. AUR Electron package `objtoschematic-bin` (2025-04-08).
- **Pixel-art converters** — CraftMC pixel-art generator (free, writes minimal Sponge v2 `.schem`, 1.13+ IDs), BlocksItems map-art generator (OKLAB matching, `.schem`, mentions Litematica/structure block targets), mapartcraft, Img2MC. All web; none scriptable. **Spritecraft is dead** (2014-era, articles about it are SEO spam).
- **Python DIY** — `trimesh.voxelized()` → nearest-block lookup (Blockpedia colours or own extraction from the 26.1 jar) → nbtlib. Must be built, ~200 lines. SteliosLL/3D-Model-to-Minecraft-Converter relies on `binvox.exe` (Windows).

### LLM / ML builders

- **Mindcraft** — https://github.com/mindcraft-bots/mindcraft (~6.0k stars, MIT, 1,673 commits; original kolbytn repo archived 2026-05-27). Mineflayer bot with Anthropic/OpenAI/Gemini/Ollama/etc backends, tasks with "blueprint to construct" goals, CLI `node main.js --task_path --task_id --profiles`, Docker. Supports Java **up to 1.21.11** (recommends 1.21.6; ViaProxy for newer). Code-writing disabled by default. Not 26.1.
- **Research code** — APT (arXiv 2411.17255, LLM text→blueprint with CoT/memory/reflection, Python code output, code on GitHub), T2BM "3D Building Generation in Minecraft via LLMs" (arXiv 2406.08751, IEEE CoG), `mmmfrieddough/minecraft-schematic-generator` (decoder-only transformer that *completes* schematics by predicting missing blocks, "Iron" ~10M / "Diamond" ~110M params, **no text conditioning**), `santaklaussus2004/MinecraftML` (dataset prep, architecture "still experimental"), Scaffold Diffusion (arXiv 2509.00062, discrete diffusion over sparse multi-category voxels), MineCEraft benchmark (arXiv 2608.28884, 2026), VoxelCodeBench (arXiv 2604.02580), Madge "LLMs as Minecraft Agents" (2402.08392, IGLU). Dataset: `Hack337/Minecraft-Schematics` on Hugging Face (.schem/.litematic/.schematic, 1,338-row fine-tune split). None is a drop-in text→vanilla-quality `.nbt`; the strongest practical approach remains an LLM writing parametric build code.
- **Mineflayer MCP servers** — yuniko-software/minecraft-mcp-server and the soumyadeo fork (adds `build-schematic` that reads `.schem` and places via `/setblock` in creative), nathangamache/minecraft-mcp-server (pnpm monorepo with a parametric build-engine package; targets 1.21.11), risnake (creative setblock/fill tools, needs op), mc-mcp. All pre-26.x.

### Rendering blocks → image (verification)

- **structura-render 0.8.3** (PyPI, 2026-09-12, Python ≥ 3.9, github.com/kirimba1024/structura-render, 0 stars, 76 commits, license unstated) — reads `.nbt` / `.snbt`, `.litematic` v5–7, `.schem` v1–3 (v1 without DataVersion needs core normalization), `.mcstructure` `[bedrock]`, legacy `.schematic` `[legacy]`. CLI: `projections` (six-view technical PNG/WebP — **no game assets or graphics backend needed**), `svg` (plan / cross-section), `png` hero perspective/orthographic via `[hero]` (PyVista/VTK), `usdz` / `gltf` / `obj` / `stl` / `vox`, `doctor --render-test`. Python API: `render_projection`, `render_svg`, `render_hero` return Pillow images; `export_structure`; all accept in-memory `structura_core.Structure`. Textures auto-detected from a launcher-installed **1.21.1** client or `STRUCTURA_MINECRAFT_ASSETS=<jar or assets/minecraft dir>` (point it at the 26.1 jar); repo has a "block-render-audit-26.2" doc. Best fit despite tiny community. Whether the hero render runs offscreen on macOS is unverified.
- **deepslate-mcp** (github.com/Philogag/deepslate-mcp, 1 star, 11 commits, MIT, no release yet) — misode/deepslate renderer via headless-gl, tools `render_structure`, `render_blocks` (programmatic block list), `inspect_structure` (size/palette/count), `render_item`; camera angle / background / size / zoom; textures from Mojang client.jar via `DEEPSLATE_JAR_PATH`; Node ≥ 20; Linux needs Mesa + Xvfb; Hermes Agent is the documented client. Promising design, very immature.
- **In-game isometric renderers** — **Isometry** (modrinth.com/mod/isometry, Fabric, MC **26.2**, MIT, requires Fabric API + oWo lib, `/isometry item|block|entity|area|namespace`, Region Wand, batch hundreds, transparent PNG at custom resolution; fork of glisco's Isometric Renders which stopped at 1.21.4) and **Isometric Renders – Forked** (NeoForge **1.21.1** only; blocks/items/entities/areas with NBT, no batch, "odd shadows" caveat). Neither matches NeoForge 26.1.
- **craftmatic** (npm, `.schem` toolkit with isometric renders) — unverified. Chunky / Mineways / Overviewer / mcrender render *worlds*, not templates; skip.
- Vanilla `/place template <id> [pos] [rotation] [mirror] [integrity] [seed] [strict]` exists and is the in-game load path; templates live in a data pack or `generated/<ns>/structures/`.

### Most promising pipeline (C)

Agent writes a parametric Python builder (palette dict + geometry functions) → nbtlib `.nbt` → structura-render `projections` for a cheap six-view sanity check → load in a GameTest (template manager) for block-state validity and jigsaw fit → in-game screenshot (D) for aesthetics.

## D. In-game screenshot / verification

- **Fabric client gametest API** — `fabric-client-gametest` entrypoint, `FabricClientGameTest`, `ClientGameTestContext.takeScreenshot(name)`, `waitTicks`, `fabric.noGui=true` for CI; projects (WI-Zoom, LiquidBounce) do screenshot comparison in CI. **Fabric only.** NeoForge: JEI's 26.2 changelogs prove NeoForge client gametests run in CI (JUnit XML, muted by default, native transport disabled on Linux), but no documented screenshot helper and no NeoForge docs page for client gametests was found.
- **HeadlessMc** — https://github.com/headlesshq/headlessmc (MIT, 423 stars, 782 commits): CLI launcher, README example `headlessmc launch fabric 26.3`; `headlessmc-lwjgl` module or Xvfb for headless; offline accounts allowed only for CI. **mc-runtime-test** GitHub Action v5.0.0 (github.com/marketplace/actions/mc-runtime-test): compatibility table **1.7.10 → 26.3, NeoForge 1.20.1 → 26.3**, runs under Xvfb, companion mod joins a world then `/test runall`; on 26.3 runs client gametests on Forge/NeoForge via `McRuntimeGameTest`, with a minimum expected test count. No screenshot support in either. Xvfb is Linux-only; on macOS use a visible window.
- **MineClient Bridge** — curseforge.com/minecraft/mc-mods/mineclient-bridge, source github.com/Campione01/MineClient-Bridge (MIT, v1.1.3 on 2026-09-10). Client-side **NeoForge 1.21.1 only** (21.1.197+, Java 21). Loopback-only server on `127.0.0.1:38121` with generated 256-bit bearer token; captures the presented framebuffer as PNG; reads player/world/inventory/GUI/entity state; presses named key mappings, view/mouse/scroll/text input; submits commands via the normal client path; graceful shutdown; bundled MCP server and a Codex acceptance skill. Exactly the right shape; wrong MC version. Port candidate.
- **prismarine-viewer headless** — official `headless()` streams frames to mp4/TCP; version support 1.8–1.18.1 (GenerelSchwerz fork to 1.20.1). Dead for 26.x. Mineflayer bots in general stop at ~1.21.x.
- **Voyager** (github.com/MineDojo/Voyager, 2023, MC 1.19 via Mineflayer, unmaintained), **STEVE-1** (MineRL/1.16), **JARVIS-1** (stale), **Project Sid** (Altera, closed). Not usable as harnesses.
- **Carpet / scarpet** — Fabric only; not searched further.
- **macOS practical path** — `./gradlew runClient` with the vanilla `--quickPlaySingleplayer <world>` argument → a dev-only client command set in the `gametest` source set (`/lotl_shot <name> [yaw] [pitch]` calling `Screenshot.grab`, plus `/tp`, `/place template`, `/summon`, `/time set`, `/weather`) → agent reads the PNG. `screencapture -l <windowid>` is a zero-code fallback for whole-window capture.

### Most promising pipeline (D)

Small dev-only client command set (shot / pose camera / place template / summon / set time) in the `gametest` source set, driven by a script that launches `runClient` with quick-play and feeds commands over a loopback socket or a polled command file. Nothing off the shelf does this for NeoForge 26.1; MineClient Bridge is the closest design to copy.

## E. Style references (codifiable)

- **Blockbench "Minecraft Style Guide"** (blockbench.net/wiki/guides/minecraft-style-guide) — the most concrete written ruleset. Textures: 1 px = 1 unit, never mix resolutions, drop detail that does not fit 16x16; restricted palette built midtone → one shadow → one highlight before more shades, shift hue + saturation + value per step (value-only ramps read dull); pencil/fill only, no soft brushes; anti-aliasing sparingly; no banding, no pillow shading, no pancake shading; checkered dithering sparingly and consistently; no noise; items lit from top-left with outline much darker than midtone; no jaggies. Blocks must read alone and tiled: check a 3x3 wall before heavy shading and keep checking. Entities: box UV, top and front brighter than bottom and back; workflow template → colour sketch with shadow/highlight → shades → material → remove banding. Models: minimal element count, single element for spheres/cylinders, rotate elements for slants (never stair-step, never curves from adjacent rotated elements), planes with transparent pixels for small details, no mixels, recognisability over scale, account for the player's bulky proportions.
- **Faithful CF32 / F32 texturing guidelines** (docs.faithfulpack.net/pages/textures/cf32-texturing-guidelines and f32-texturing-guidelines) — Jappa-style discipline: "could Jappa have drawn it on a 16x canvas?", match vanilla contrast, limited colour count (index your colours), one-pixel outlines, never change existing vanilla colours (only add), define the material's surface quality before shading, avoid flat two-pixel lines; glossary of pixel-art terms; "programmer art" = pre-1.14 style.
- No official Mojang Java texture guide and no Jappa-authored written guide exists (Microsoft Learn Bedrock docs did not surface a style guide either); the two above are the canonical community substitutes.
- **Building** — consistent advice across sources but no authoritative doc: 3–5 block palette (primary / secondary / accent, or one hue with light/dark shades), depth via stairs / slabs / trapdoors / recessed windows with sills, order shape → palette → depth → roof → detail, roof has outsized impact, never a plain cuboid, landscaping and paths are part of the build. No codified "Grian style" checklist exists; sources only name his channel.

## Gaps (what we would have to build)

1. **NeoForge 26.1 screenshot / scene-driver mod** — no client-gametest screenshot API on NeoForge; MineClient Bridge is 1.21.1-only. Build a dev-only command set (~1 day) or port MineClient Bridge.
2. **NeoForge 26.1 isometric renderer** — Isometry is Fabric 26.2, Isometric Renders Forked is 1.21.1. Port Isometry, or rely on structura-render projections plus screenshots.
3. **Vanilla palette extractor** — nothing turns the 26.1 client jar into per-material palette ramps (Blockpedia is 1.20.4 and block-average only). Trivial script.
4. **Mesh → cuboid Blockbench model** — no tool produces low-element Java cuboid models with sane UVs from a mesh. Agent-designed box layouts instead.
5. **Text → vanilla-quality structure template** — research only (completion transformers, benchmarks, LLM blueprint papers); production path is LLM-written parametric builders plus a render loop.
6. **Scriptable image / voxel → `.nbt` converter for current block IDs** — web tools only; ~200 lines of Python over trimesh / PIL + nbtlib.
7. **Mineflayer-based anything for 26.x** — ecosystem stops at 1.21.x; do not plan on bots or prismarine-viewer.
8. **.bbmodel stability** — no spec, breaking changes allowed. Mitigate by round-tripping every generated file through the headless Blockbench MCP validator.

## Caveats

structura-render and deepslate-mcp are single-maintainer with ~0 stars. Retro Diffusion and PixelLab are paid. The blender-mcp rename and the GeckoLib ↔ 26.1 version mapping come from single secondary sources. Whether structura-render's hero render works offscreen on macOS was not tested. All GitHub star counts and dates are as read on 2026-10-31.

## Key URLs

- Retro Diffusion API examples: https://github.com/Retro-Diffusion/api-examples ; MCP: https://mcp.retrodiffusion.ai/mcp
- PixelLab vibe-coding setup: https://pixellab.ai/vibe-coding
- Blockbench MCP plugin (headless): https://github.com/jasonjgardner/blockbench-mcp-plugin ; skills: https://github.com/jasonjgardner/blockbench-mcp-project
- .bbmodel docs: https://blockbench.net/wiki/docs/bbmodel ; style guide: https://blockbench.net/wiki/guides/minecraft-style-guide
- Blockbench headless issue: https://github.com/JannisX11/blockbench/issues/1764
- structura-render: https://pypi.org/project/structura-render/ ; https://github.com/kirimba1024/structura-render
- deepslate-mcp: https://github.com/Philogag/deepslate-mcp
- mcschematic: https://github.com/Sloimayyy/mcschematic ; litemapy: https://github.com/SmylerMC/litemapy ; amulet-core: https://pypi.org/project/amulet-core/ ; nucleation: https://github.com/Schem-at/Nucleation
- Blockpedia: https://docs.rs/crate/blockpedia/latest
- Mindcraft: https://github.com/mindcraft-bots/mindcraft
- Schematic completion transformer: https://github.com/mmmfrieddough/minecraft-schematic-generator ; dataset: https://huggingface.co/datasets/Hack337/Minecraft-Schematics
- HeadlessMc: https://github.com/headlesshq/headlessmc ; mc-runtime-test: https://github.com/marketplace/actions/mc-runtime-test
- MineClient Bridge: https://github.com/Campione01/MineClient-Bridge
- Isometry: https://modrinth.com/mod/isometry ; Isometric Renders Forked: https://www.curseforge.com/minecraft/mc-mods/isometric-renders-forked
- Faithful guidelines: https://docs.faithfulpack.net/pages/textures/cf32-texturing-guidelines
- Meshy MCP: https://docs.meshy.ai/api/ai ; Tripo MCP: https://glama.ai/mcp/servers/@pasie15/tripo-ai-mcp-server ; Hunyuan3D local MCP: https://glama.ai/mcp/servers/JimCline/hy3d-mcp
- Blender MCP: https://glama.ai/mcp/servers/ahujasid/blender-mcp ; Mcblend: https://mcblend.readthedocs.io/
- hairyf minecraft-texture skill: https://www.skills.sh/hairyf/skills/minecraft-texture
