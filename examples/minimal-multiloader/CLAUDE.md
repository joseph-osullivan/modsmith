# Example Mod — project conventions

Scaffolded by modsmith. This file records the conventions AI dev workflows
(and humans) should follow in this repo. Keep it current as the project grows.

## Versions — single source of truth

All Minecraft / loader / tooling versions live in `gradle.properties`.
**Never** hardcode a version in a subproject build file.

Per-MC pins use the `<key>_1_21_1` suffix scheme for MC 1.21.1.

Per-MC pins use the `<key>_26_1_2` suffix scheme for MC 26.1.2.


## Build commands

- Full build (all subprojects — the pre-merge gate): `./gradlew build`
- Unit tests only: `./gradlew :common:test`


- Per target for MC 1.21.1: `./gradlew :versions:1.21.1:fabric:build` / `./gradlew :versions:1.21.1:neoforge:build`
- Dev client for MC 1.21.1: `./gradlew :versions:1.21.1:fabric:runClient` / `./gradlew :versions:1.21.1:neoforge:runClient`

- Per target for MC 26.1.2: `./gradlew :versions:26.1.2:fabric:build` / `./gradlew :versions:26.1.2:neoforge:build`
- Dev client for MC 26.1.2: `./gradlew :versions:26.1.2:fabric:runClient` / `./gradlew :versions:26.1.2:neoforge:runClient`


## Test tiers

- **Tier 1 — JUnit unit tests** (present): pure-JVM tests in
  `common/src/test/java/com/example/examplemod/unit/`, run via
  `./gradlew :common:test`. JUnit 5 wiring ships with the scaffold; a sample
  test exists at `ScaffoldSmokeTest.java` (delete it once real tests exist).
- **Tier 2 — GameTests** (not yet set up): in-game server tests. Add
  infrastructure before claiming runtime behavior is tested.
- **Tier 3 — manual dev-client verification** (ad hoc): `runClient` targets.

New behavior needs a failing Tier-1 test first whenever the logic is
JVM-testable; write the test, watch it fail, then implement.

## License

The SPDX id (`MIT`) is recorded in `gradle.properties` and both mod
manifests, but the scaffold does not generate license text. Add a `LICENSE`
file at the repo root — once present, the build stamps it into every jar.

## Version-bump rule

`mod_version` in `gradle.properties` is the mod's version. Bump it on every
user-visible change before merging: patch for fixes, minor for features.
Never ship two different builds under the same `mod_version`.

## Layout rules



- `common/` — pure Java only (no `net.minecraft.*`, `net.fabricmc.*`, or
  `net.neoforged.*` imports).


- `versions/1.21.1/common/` — MC-touching shared code for MC 1.21.1.
- `versions/1.21.1/{fabric,neoforge}/` — loader-specific code for MC 1.21.1,
  registered via `META-INF/services/`.

- `versions/26.1.2/common/` — MC-touching shared code for MC 26.1.2.
- `versions/26.1.2/{fabric,neoforge}/` — loader-specific code for MC 26.1.2,
  registered via `META-INF/services/`.

