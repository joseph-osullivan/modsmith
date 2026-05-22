# modsmith

AI-first Minecraft mod development as a Claude Code plugin. Scaffolds multi-loader (Fabric + NeoForge) mods across multiple MC versions, orchestrates the full dev cycle from spec to PR, and hands the dev server to you for play-testing while gametest, log-watcher, and reviewer agents work in the background.

## Status

Pre-release (v0.1.0). Under active development.

## Install

```
/plugin install joseph-osullivan/modsmith
```

Or for local development:

```
git clone https://github.com/joseph-osullivan/modsmith
claude plugin link ./modsmith
```

## Skills

- **`/modsmith:init <modid>`** — Scaffold a new multi-loader mod. Interactive: asks for mod ID, package, loaders, MC versions. Accepts `latest`, `lts`, `recommended`, and exact pins.
- **`/modsmith:develop <task>`** — Run the full dev cycle for one feature: architect → research → plan → build → doctor → handoff (dev server + background gametest/review) → kick-back loop → PR.
- **`/modsmith:doctor`** — Audit the current mod's multi-loader hygiene. Catches missing ServiceLoader registrations, loader API leaks into `common/`, mixin/refmap misconfigs, stale versions, and more.

## What modsmith assumes

- **Layout:** MultiLoader-Template-style — `common/` + `fabric/` + `neoforge/` Gradle subprojects.
- **Toolchain:** Direct Fabric Loom + ModDevGradle. No Architectury runtime dependency.
- **Expect/actual:** Java `ServiceLoader` pattern (interface in common, impl per loader, `META-INF/services/` registration).
- **Tests:** Three tiers — Tier-1 JUnit (alongside code), Tier-2 GameTest (background, per loader), Tier-3 scenarios (optional, multi-tick scripts).

## Inspired by

- [`jaredlll08/MultiLoader-Template`](https://github.com/jaredlll08/MultiLoader-Template) — canonical multi-loader project layout
- [`Leclowndu93150/Prism`](https://github.com/Leclowndu93150/Prism) — design patterns adopted: single source of truth for versions, auto Java toolchain selection, mixin/AT/AW handling, build preconditions, config-time auditing

## License

MIT — see [LICENSE](./LICENSE).
