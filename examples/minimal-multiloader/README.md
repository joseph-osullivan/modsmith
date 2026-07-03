# examplemod — minimal multi-MC modsmith scaffold

This directory is a **rendered modsmith scaffold**, checked in for documentation and smoke-testing. It's the output you'd get from running:

```bash
/modsmith:init examplemod --mc 1.21.1,26.1.2 --loaders fabric,neoforge
```

It targets:

| MC version | Fabric | NeoForge | Java |
|---|---|---|---|
| 1.21.1 | Loader 0.19.2 + API 0.116.12 | 21.1.230 | 21 |
| 26.1.2 | Loader 0.19.2 + API 0.149.1 | 26.1.2.64-beta | 25 |

## What this demonstrates

- **Multi-MC overlay layout** — `common/` for pure Java + `versions/<mc>/{common,fabric,neoforge}/` for MC-touching code per MC line
- **ServiceLoader expect/actual pattern** — `IPlatformHelper` interface in top-level common, impls in each loader subproject + `META-INF/services/` registrations
- **Single source of truth for versions** — every version lives in root `gradle.properties` under the `<key>_<mc_suffix>` scheme
- **Auto Java toolchain per MC** — Java 21 for the 1.21.1 line, Java 25 for the 26.1.2 line
- **AT/AW parity** — `accesstransformer.cfg` authored once in `versions/<mc>/common/META-INF/`; the Fabric build generates the corresponding `.accesswidener` at build time
- **GitHub Actions CI** — matrix workflow over all `(MC × loader)` combinations
- **Pinned Gradle wrapper** — Gradle 9.2, no host `gradle` install required

## Trying it

From this directory:

```bash
./gradlew :common:build                          # top-level pure-Java common
./gradlew :versions:1.21.1:fabric:build          # one matrix cell
./gradlew :versions:26.1.2:neoforge:build        # another
./gradlew build                                  # everything
```

## Auditing it

From this directory, run modsmith's audit:

```bash
/modsmith:doctor
```

It should report all 16 multi-loader checks and 5 multi-MC checks as either `pass` or `skip` (no `hard_fail`).

## Not included

- No actual mod code beyond the `ModInit` smoke-test entry point
- No mixins, blocks, items, entities — pure scaffold
- No tests (`common/src/test/` is empty; add Tier-1 JUnit there as you build features)
- No Modrinth/CurseForge publish wiring (deferred to `/modsmith:publish`, v0.2.0)

## Regenerating this example

To re-render from the current templates (after editing modsmith):

```bash
# From the modsmith repo root:
rm -rf examples/minimal-multiloader
bash scripts/expand-templates.sh \
  --vars examples/minimal-multiloader.vars.json \
  --out examples/minimal-multiloader
```

(The vars file used to generate this scaffold is described in `examples/minimal-multiloader.vars.json` if you want to tweak it.)
