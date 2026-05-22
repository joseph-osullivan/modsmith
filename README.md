# modsmith

**AI-first Minecraft mod development as a Claude Code plugin.**

Scaffolds multi-loader (Fabric + NeoForge) mods, orchestrates the full dev cycle from spec to PR, and hands the dev server to you for play-testing while gametest, log-watcher, and reviewer agents work in the background.

## Status

**v0.1.0 — pre-release.** All skills, agents, references, templates, and scripts are authored and committed. End-to-end proving-ground migration of a real mod is pending. Distribution via the official Claude Code marketplace will follow the proving-ground run.

## What it does

```
/modsmith:init shopkeeper --mc latest,lts --loaders fabric,neoforge
  ↳ scaffolds a green multi-loader repo with one canonical layout

/modsmith:develop "add a shopkeeper villager that gives Hero-tagged players a discount"
  ↳ architect → research → plan → builders (common + per-loader) → doctor
  ↳ dev server starts for you; gametest + log-watcher + reviewer run in background
  ↳ reviewer can kick changes back to the builder (cap 3 iterations) → PR

/modsmith:doctor
  ↳ audits multi-loader hygiene: 16 checks across platform impls, ServiceLoader
    registration, refmap config, version freshness, mods.toml naming, and more
```

## Install

**From GitHub (development):**

```bash
git clone https://github.com/joseph-osullivan/modsmith
claude plugin link ./modsmith
```

**Once published to the marketplace** (post-v0.1.0):

```
/plugin install joseph-osullivan/modsmith
```

## Skills

| Skill | Purpose |
|---|---|
| **`/modsmith:init <modid>`** | Scaffold a new multi-loader mod. Interactive: asks for mod ID, package, loaders, MC versions. Accepts `latest`, `lts`, `recommended`, `next`, partial pins (`1.21` → `1.21.X`), and exact pins. Renders 19 templates, runs `./gradlew :fabric:build :neoforge:build` as a green-build proof. |
| **`/modsmith:develop <task>`** | Run the full feature dev cycle. Phases: 0 bootstrap → 1 architect → 2 research → 3 plan → 4 build → 5 doctor → 6 handoff (dev server + background gametest/log-watcher/reviewer) → 7 kick-back loop → 8 PR. Detects single-loader vs multi-loader vs monolith repos. |
| **`/modsmith:doctor`** | Audit the current mod for multi-loader hygiene. Hard-fails on `common/` → loader imports, missing platform impls, missing `META-INF/services/` registrations, `mods.toml` (old name) presence, refmap/AT misconfigs, modid mismatches across loaders. Warns on stale pinned versions, missing `pack.mcmeta`, AT/AW parity drift. Runs as a phase gate inside `:develop`. |

## Architecture

```
modsmith/
├── .claude-plugin/plugin.json     ← plugin manifest
├── skills/
│   ├── develop/                   ← the orchestrator (8 phases)
│   ├── init/                      ← greenfield scaffolding
│   └── doctor/                    ← multi-loader audit
├── agents/                        ← 8 specialists
│   ├── architect.md               ← decomposes tasks; emits play-expectations.json
│   ├── builder.md                 ← writes common-first; ServiceLoader pattern
│   ├── gametest-author.md         ← 7 reliability rules baked in
│   ├── scenario-author.md         ← multi-tick test scripts
│   ├── scenario-runner.md         ← runs scenarios per target
│   ├── scenario-analyzer.md       ← diagnoses scenario failures
│   ├── log-watcher.md             ← background log observation
│   └── reviewer.md                ← final audit + kick-back decisions
├── references/                    ← read-only knowledge
│   ├── multiloader-layout.md      ← canonical project tree
│   ├── expect-actual-pattern.md   ← ServiceLoader pattern (copy-pasteable)
│   ├── landmines.md               ← MC API renames + multi-loader gotchas
│   ├── version-matrix.md          ← known-good MC × loader combos
│   ├── gametest-rules.md          ← non-flaky test rules
│   ├── log-watcher-rules.md       ← universal + per-loader log baselines
│   └── dev-server-playbook.md     ← Phase 6 handoff protocol
├── templates/                     ← 19 Mustache templates for /modsmith:init
├── scripts/                       ← deterministic shell primitives
│   ├── detect-targets.sh          ← emits the targets matrix JSON
│   ├── resolve-versions.sh        ← resolves symbolic MC/loader tokens
│   ├── expand-templates.sh        ← renders templates with Mustache vars
│   ├── doctor.sh                  ← runs all 16 audits, emits JSON
│   ├── log-watcher.sh             ← deterministic regex tail + finding emission
│   ├── start-dev-server.sh        ← spawns :<loader>:runClient with tee'd logs
│   ├── run-gametest.sh            ← --warmup + --subproject flags
│   ├── bootstrap-worktree.sh      ← parallel-builder worktrees
│   ├── merge-worktree.sh          ← worktree merge + conflict reporting
│   └── ... (preflight, kill-stuck-jvms, base-drift, hooks)
└── hooks/hooks.json               ← SessionStart, PreToolUse:Bash, SubagentStop
```

## What modsmith assumes

- **Layout:** MultiLoader-Template-style — `common/` + `fabric/` + `neoforge/` Gradle subprojects.
- **Toolchain:** Direct Fabric Loom + ModDevGradle. **No Architectury runtime dependency.**
- **Expect/actual:** Java `ServiceLoader` pattern — interface in `common/.../platform/`, impl per loader, `META-INF/services/<FQN>` registration. One canonical pattern, mechanically applied.
- **Versions:** Single source of truth in root `gradle.properties`. Subproject `build.gradle` files read via `findProperty`. Hardcoded versions in subprojects are a `doctor` hard-fail.
- **Tests:** Three tiers — Tier-1 JUnit (alongside code, in `common/`), Tier-2 GameTest (per loader, runs in background during dev-server handoff), Tier-3 scenarios (optional, multi-tick scripts).
- **Loaders:** Fabric and NeoForge (modern). Forge legacy is explicitly out of scope.

## Inspired by

- [`jaredlll08/MultiLoader-Template`](https://github.com/jaredlll08/MultiLoader-Template) — canonical multi-loader project layout (templates seeded from the `26.1.2` branch)
- [`Leclowndu93150/Prism`](https://github.com/Leclowndu93150/Prism) — design patterns adopted: single source of truth for versions, auto Java toolchain selection, mixin/AT/AW handling, build preconditions, config-time auditing

## Known limitations (v0.1.0)

- **Single MC version per scaffold.** The resolver accepts multiple MC tokens but `init` renders one `gradle.properties`. Multi-MC source forks are deferred to v0.2.0.
- **Gradle wrapper.** `init` bootstraps the wrapper via `gradle wrapper --gradle-version 9.2` if `gradle` is on `PATH`; otherwise warns and lets the user bootstrap manually. A shipped wrapper stub is a v0.2.0 follow-up.
- **No end-to-end migration validation yet.** v0.1.0 ships the plugin; full validation against a real-world multi-loader migration is pending.
- **No `/modsmith:publish` skill.** Modrinth + CurseForge per-loader uploads are v0.2.0.

## License

MIT — see [LICENSE](./LICENSE).

## Author

Joseph O'Sullivan — [github.com/joseph-osullivan](https://github.com/joseph-osullivan)
