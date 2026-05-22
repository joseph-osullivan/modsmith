# Canonical multi-loader project layout

`modsmith` assumes a **MultiLoader-Template-style** layout: three Gradle
subprojects (`common`, `fabric`, `neoforge`) sharing a single root build. This
is the layout seeded by [`jaredlll08/MultiLoader-Template`](https://github.com/jaredlll08/MultiLoader-Template)
(branch `26.1.2`) and the one every modsmith skill, agent, and template was
written against.

## The directory tree

```
mymod/
├─ build.gradle                    # root - subprojects {} block; the only file authoring shared config
├─ settings.gradle                 # includes :common, :fabric, :neoforge; pluginManagement {} for Loom + MDG
├─ gradle.properties               # single source of truth for ALL versions
├─ gradle/
│  ├─ wrapper/
│  │  ├─ gradle-wrapper.jar
│  │  └─ gradle-wrapper.properties
│  └─ libs.versions.toml           # optional, version catalog
├─ gradlew
├─ gradlew.bat
│
├─ common/                         # vanilla Minecraft only - Mojmap mappings
│  ├─ build.gradle                 # minimal: applies common plugin, declares MC dep
│  └─ src/
│     └─ main/
│        ├─ java/
│        │  └─ com/example/mymod/
│        │     ├─ ModInit.java                       # parameterless init() called by both loaders
│        │     ├─ ModBlocks.java                     # vanilla block declarations (no DeferredRegister)
│        │     ├─ ModItems.java
│        │     └─ platform/
│        │        ├─ IPlatformHelper.java            # expect/actual interface
│        │        ├─ Services.java                   # ServiceLoader wrapper
│        │        └─ IRegistryHelper.java            # other expect/actual interfaces here
│        └─ resources/
│           ├─ assets/mymod/                         # textures, models, lang
│           ├─ data/mymod/                           # tags, recipes, loot tables
│           ├─ pack.mcmeta                           # required if assets/ or data/ non-empty
│           ├─ mymod.mixins.json                     # mixin config shared by both loaders (refmap toggled per-loader)
│           └─ META-INF/
│              └─ accesstransformer.cfg              # single-source AT; NeoForge reads directly, Fabric AW generated from it at build time
│
├─ fabric/                         # Fabric-specific code + service registrations
│  ├─ build.gradle                 # applies fabric-loom; depends on :common
│  └─ src/
│     └─ main/
│        ├─ java/
│        │  └─ com/example/mymod/fabric/
│        │     ├─ FabricModInit.java                 # implements net.fabricmc.api.ModInitializer
│        │     └─ platform/
│        │        ├─ FabricPlatformHelper.java       # impl of IPlatformHelper
│        │        └─ FabricRegistryHelper.java
│        └─ resources/
│           ├─ fabric.mod.json                       # Fabric manifest
│           ├─ mymod.accesswidener                   # generated at build time from common's AT
│           └─ META-INF/
│              └─ services/
│                 ├─ com.example.mymod.platform.IPlatformHelper        # one line: FQN of impl
│                 └─ com.example.mymod.platform.IRegistryHelper
│
└─ neoforge/                       # NeoForge-specific code + service registrations
   ├─ build.gradle                 # applies net.neoforged.moddev; depends on :common
   └─ src/
      └─ main/
         ├─ java/
         │  └─ com/example/mymod/neoforge/
         │     ├─ NeoForgeModInit.java               # @Mod-annotated class with (IEventBus) ctor
         │     └─ platform/
         │        ├─ NeoForgePlatformHelper.java     # impl of IPlatformHelper
         │        └─ NeoForgeRegistryHelper.java
         └─ resources/
            └─ META-INF/
               ├─ neoforge.mods.toml                 # NeoForge manifest (NOT mods.toml)
               └─ services/
                  ├─ com.example.mymod.platform.IPlatformHelper
                  └─ com.example.mymod.platform.IRegistryHelper
```

## What goes where

### `common/`

- **Only vanilla Minecraft APIs.** Mojmap mappings. Pure Java 21 / 25.
- **No loader imports.** No `net.fabricmc.*`, no `net.neoforged.*`.
  `/modsmith:doctor` hard-fails on any such import.
- **Interfaces, not implementations,** for anything loader-specific
  (registries, events, network, config). The contract is in `common`; impls
  live in loader subprojects.
- **Vanilla MC declarations** that don't need a loader-specific registration
  primitive: `Block`/`Item` instance fields, recipe codecs, codec-backed
  data, gametest template logic, etc.
- **Tier-1 JUnit tests** alongside production code in `common/src/test/`.
  Pure Java — no MC bootstrap required for these.

### `fabric/`

- **Fabric-specific implementations** of every interface declared in `common/.../platform/`.
- **`ModInitializer` / `ClientModInitializer`** entrypoints. These are
  parameterless. They call `ModInit.init()` from `common`.
- **Fabric API usage** (registries via `Registry.register`, events via
  `ServerLifecycleEvents.SERVER_STARTED.register(...)`, etc.).
- **`META-INF/services/` registration** for every interface in `common`.
  Without these, `ServiceLoader.load(...).findFirst()` throws.

### `neoforge/`

- **NeoForge-specific implementations** of every interface declared in `common/.../platform/`.
- **`@Mod`-annotated entrypoint** with a constructor taking `IEventBus modEventBus`
  (and optionally `ModContainer`, `Dist`). It calls `ModInit.init()` from `common`.
- **`@SubscribeEvent` handlers** on the appropriate bus (mod-bus for
  lifecycle/registry, game-bus for gameplay — see `landmines.md`).
- **`META-INF/services/` registration** for every interface in `common`.

## How the subprojects depend on each other

```
        ┌──────────┐
        │  common  │  ← pure Java + vanilla MC; no loader deps
        └────┬─────┘
             │ depended on by both
        ┌────┴────┐
        ▼         ▼
   ┌────────┐ ┌──────────┐
   │ fabric │ │ neoforge │  ← each adds its loader + the loader-specific runtime
   └────────┘ └──────────┘
```

Both `fabric` and `neoforge` `implementation project(":common")` (or, in
Loom, `modImplementation` if `common` is configured for loader-publishing —
but the modsmith templates use a straight `project(":common")` dependency
because `common` has no loader runtime). Neither `fabric` nor `neoforge`
depends on the other.

## Why this layout (and not Architectury)

- **AI training data is dense** on this layout. `jaredlll08/MultiLoader-Template`
  is the canonical seed; thousands of mods follow it.
- **No third version axis.** Architectury adds "which Architectury supports
  which MC + loader version" — a recurring source of agent hallucination.
  This layout has only MC version × loader version.
- **Plain Java SDK only.** `ServiceLoader` (the expect/actual mechanism) is
  in `java.util` — no runtime library to bump, no API to mis-remember.
- **Doctor can verify it.** The layout is structurally checkable; `/modsmith:doctor`
  asserts every `common` interface has impls in both loader subprojects.

## Seed reference

`modsmith init` renders templates that match this layout exactly. The
templates were derived from [`jaredlll08/MultiLoader-Template`](https://github.com/jaredlll08/MultiLoader-Template)
(branch `26.1.2`); when in doubt about gradle build-file shape or
`settings.gradle` conventions, that repository is the source of truth.

## Multi-MC layout

When `modsmith init` is invoked with **2+ MC versions**, the renderer
switches from the flat single-MC layout above to an overlay layout that
isolates each MC line's MC-touching code from the others. Inspired by
[`Leclowndu93150/Prism`](https://github.com/Leclowndu93150/Prism), but
without taking a runtime dependency on Prism — modsmith just renders
the canonical files directly.

### When this layout is used

- The user picked 2 or more MC versions during `/modsmith:init` (e.g.
  `--mc latest,lts` resolves to two concrete pins).
- The `vars.json` passed to `scripts/expand-templates.sh` contains an
  `mc_versions` array with ≥ 2 entries. With 0 or 1 entries, the
  renderer falls back to single-MC mode.

A single-MC scaffold should NOT be retroactively reshaped into a
multi-MC scaffold by hand — re-run `/modsmith:init` into a fresh dir.

### Full directory tree

```
mymod/
├─ build.gradle                    # root: subprojects {} block, common config
├─ settings.gradle                 # includes :common + :versions:<mc>:* per MC
├─ gradle.properties               # per-MC pins with <key>_<mc_suffix> scheme
├─ gradle/wrapper/...
├─ gradlew, gradlew.bat
│
├─ common/                         # PURE JAVA — MC-agnostic shared code
│  ├─ build.gradle                 # plain java-library; NO MC, NO Loom, NO MDG
│  └─ src/main/java/<pkg>/         # algorithms, codecs, math, state machines
│
└─ versions/
   ├─ 1.21.1/
   │  ├─ common/                   # MC-touching shared code FOR 1.21.1
   │  │  ├─ build.gradle           # MDG with neoFormVersion=<1.21.1 neoform>
   │  │  └─ src/main/java/<pkg>/
   │  │     ├─ ModInit.java
   │  │     └─ platform/{IPlatformHelper,Services}.java
   │  │  └─ src/main/resources/
   │  │     ├─ META-INF/accesstransformer.cfg
   │  │     └─ <modid>.mixins.json   # compatibilityLevel = JAVA_21
   │  ├─ fabric/                   # Loom for MC 1.21.1
   │  │  ├─ build.gradle
   │  │  └─ src/main/java/<pkg>/fabric/
   │  │     ├─ FabricModInit.java
   │  │     └─ platform/FabricPlatformHelper.java
   │  │  └─ src/main/resources/
   │  │     ├─ fabric.mod.json
   │  │     └─ META-INF/services/<pkg>.platform.IPlatformHelper
   │  └─ neoforge/                 # MDG (full NeoForge runtime) for 1.21.1
   │     ├─ build.gradle
   │     └─ src/main/java/<pkg>/neoforge/
   │        ├─ NeoForgeModInit.java
   │        └─ platform/NeoForgePlatformHelper.java
   │     └─ src/main/resources/
   │        ├─ META-INF/neoforge.mods.toml
   │        └─ META-INF/services/<pkg>.platform.IPlatformHelper
   └─ 26.1.2/
      ├─ common/                   # MC-touching shared code FOR 26.1.2
      ├─ fabric/                   # Loom for MC 26.1.2
      └─ neoforge/                 # MDG for NeoForge 26.1.2
```

Both MC lines are independent overlays; nothing in `versions/1.21.1/`
references `versions/26.1.2/`. They only share the top-level `:common`.

### Layer responsibilities

- **Top-level `common/`** — pure Java only. NO `net.minecraft.*`, NO
  `net.fabricmc.*`, NO `net.neoforged.*` imports. Shared utility code
  (math, codecs, data structures, business logic) that doesn't need
  MC. Compiles against the **highest** Java toolchain among the
  targeted MC versions, so its bytecode is forward-compatible with
  every targeted MC line's JVM. `/modsmith:doctor` hard-fails on any
  MC or loader import in this module.

- **`versions/<mc>/common/`** — shared code that **does** touch
  `net.minecraft.*` APIs for that specific MC version. Each MC line
  has its own copy because MC APIs diverge across versions (class
  renames, method removals, package relocations). NO loader imports
  here — that goes one level deeper.

- **`versions/<mc>/fabric/`** — Fabric Loader + Fabric API
  ServiceLoader impls + `fabric.mod.json` for that MC. Depends on
  `:versions:<mc>:common` and (transitively) `:common`.

- **`versions/<mc>/neoforge/`** — NeoForge runtime + ServiceLoader
  impls + `neoforge.mods.toml` for that MC. Depends on
  `:versions:<mc>:common` and (transitively) `:common`.

### Dependency graph

```
                  ┌─────────┐
                  │ :common │  pure Java; no MC, no loader
                  └────┬────┘
                       │ depended on by every subproject below
        ┌──────────────┴──────────────┐
        ▼                             ▼
  ┌────────────────┐            ┌────────────────┐
  │ :versions      │            │ :versions      │
  │ :1.21.1:common │            │ :26.1.2:common │
  └───┬──────────┬─┘            └───┬──────────┬─┘
      │          │                  │          │
      ▼          ▼                  ▼          ▼
  ┌──────┐  ┌────────┐          ┌──────┐  ┌────────┐
  │:1.21 │  │:1.21   │          │:26.1 │  │:26.1   │
  │.1:   │  │.1:     │          │.2:   │  │.2:     │
  │fabric│  │neoforge│          │fabric│  │neoforge│
  └──────┘  └────────┘          └──────┘  └────────┘
```

Concretely, each leaf subproject declares
`implementation project(':common')` plus a configurations-based
source pull-in from its MC's common (`mcCommonJava` / `mcCommonResources`)
matching the single-MC pattern.

### `gradle.properties` key-suffix scheme

All versions live in one root `gradle.properties`. To avoid collisions
between MC lines, every per-MC pin is suffixed with the MC version
where dots become underscores:

```
# Shared (top-level common)
java_version_shared=25

# MC 1.21.1 line
mc_version_1_21_1=1.21.1
java_version_1_21_1=21
neoform_version_1_21_1=1.21.1-20240808.144430
neoforge_version_1_21_1=21.1.230
fabric_loader_version_1_21_1=0.16.10
fabric_api_version_1_21_1=0.111.0+1.21.1
parchment_mc_version_1_21_1=1.21.1
parchment_version_1_21_1=2024.11.17

# MC 26.1.2 line
mc_version_26_1_2=26.1.2
java_version_26_1_2=25
neoform_version_26_1_2=26.1.2-20251001.123456
neoforge_version_26_1_2=26.1.2.64-beta
fabric_loader_version_26_1_2=0.18.6
fabric_api_version_26_1_2=0.145.4+26.1.2
```

Each subproject reads its own row via `findProperty`:

```groovy
// versions/1.21.1/neoforge/build.gradle
def mcVersion = project.findProperty('mc_version_1_21_1')
def neoVer    = project.findProperty('neoforge_version_1_21_1')
```

The MC-suffixed names are baked into the templates at scaffold time, so
the renderer takes care of computing the suffix (`1.21.1 → 1_21_1`,
`26.1.2 → 26_1_2`). Add new MC lines by re-running `/modsmith:init`
or by hand-extending `gradle.properties` + adding the corresponding
`versions/<new-mc>/` overlay.

### Why this layout (and not just one big common per MC)

MC APIs diverge across versions in ways that defeat a single shared
source set:

- **Class renames.** `net.minecraft.world.entity.monster.Zombie`
  (pre-26.1) moved to `monster.zombie.Zombie` in MC 26.1.
- **Method removals / signature changes.** `BlockEntity.saveAdditional`
  takes `(CompoundTag, HolderLookup.Provider)` in 1.21 but
  `(ValueOutput)` in 26.1.
- **Event re-routing.** `@EventBusSubscriber(modid=..., bus=...)` lost
  its `bus` attribute in NeoForge 26.1.
- **Registry handle changes.** `Block.Properties` requires its registry
  id BEFORE construction in 26.1; pre-26.1 patterns crash at registry
  time.

A single common source set can't accommodate these. The choices are:
either an Architectury-style polyfill layer (a third version axis, AI
gets it wrong), or per-MC source overlays (this layout). Pure-Java
shared code stays in top-level `:common` where it's truly portable.

### Forking a class between MC versions

When an MC API change forces a class to diverge, the canonical move is:

1. Identify the divergent class in `versions/<old>/common/.../Foo.java`.
2. Copy it to `versions/<new>/common/.../Foo.java`, **keeping the same
   FQN**.
3. Adapt the `<new>` copy to the `<new>` MC API.

Both copies have the same FQN; each loader subproject sees the
version-appropriate copy because it depends on its own MC's
`:versions:<mc>:common`. The Fabric `:versions:1.21.1:fabric`
subproject pulls sources from `:versions:1.21.1:common` only — it
never sees the `26.1.2` copy of `Foo.java`, so there's no FQN
collision.

If the divergence is small (a couple of lines), an alternative is to
keep the class in top-level `:common` and use a per-MC accessor in
`:versions:<mc>:common` to bridge the API gap — but only if the
class itself doesn't import MC. Once MC types are involved, the
class belongs in `versions/<mc>/common/` by definition.

### Source-of-truth rule

A file lives at top-level `:common/` **iff** it never imports anything
from `net.minecraft.*`, `net.fabricmc.*`, or `net.neoforged.*`. The
**moment** a top-level common file needs any MC type — even just
`net.minecraft.resources.ResourceLocation` — it must move to
`versions/<mc>/common/` (one copy per MC line, since the MC type may
or may not exist or look the same across versions).

`/modsmith:doctor` enforces this via import scanning of top-level
`common/`. If you see a doctor failure of the form *"net.minecraft.*
import in :common — move to versions/<mc>/common/"* that's exactly
the rule firing.

### Multi-MC scaffold output (templates → files)

The render flow for multi-MC mode:

| Source template | Output path | Rendered |
| --- | --- | --- |
| `templates/multimc/settings.gradle.mustache` | `settings.gradle` | once |
| `templates/multimc/root.build.gradle.mustache` | `build.gradle` | once |
| `templates/multimc/gradle.properties.mustache` | `gradle.properties` | once |
| `templates/multimc/common.build.gradle.mustache` | `common/build.gradle` | once |
| `templates/multimc/versions.common.build.gradle.mustache` | `versions/<mc>/common/build.gradle` | per MC |
| `templates/multimc/versions.fabric.build.gradle.mustache` | `versions/<mc>/fabric/build.gradle` | per MC × Fabric |
| `templates/multimc/versions.neoforge.build.gradle.mustache` | `versions/<mc>/neoforge/build.gradle` | per MC × NeoForge |
| `templates/ModInit.java.mustache` | `versions/<mc>/common/.../ModInit.java` | per MC |
| `templates/PlatformHelper.java.mustache` | `versions/<mc>/common/.../platform/IPlatformHelper.java` | per MC |
| `templates/Services.java.mustache` | `versions/<mc>/common/.../platform/Services.java` | per MC |
| `templates/accesstransformer.cfg.mustache` | `versions/<mc>/common/.../accesstransformer.cfg` | per MC |
| `templates/mixins.json.mustache` | `versions/<mc>/common/.../<modid>.mixins.json` | per MC |
| `templates/FabricModInit.java.mustache` | `versions/<mc>/fabric/.../FabricModInit.java` | per MC × Fabric |
| `templates/FabricPlatformHelper.java.mustache` | `versions/<mc>/fabric/.../platform/FabricPlatformHelper.java` | per MC × Fabric |
| `templates/fabric.mod.json.mustache` | `versions/<mc>/fabric/.../fabric.mod.json` | per MC × Fabric |
| `templates/fabric-services.txt.mustache` | `versions/<mc>/fabric/.../META-INF/services/<fqn>` | per MC × Fabric |
| `templates/NeoForgeModInit.java.mustache` | `versions/<mc>/neoforge/.../NeoForgeModInit.java` | per MC × NeoForge |
| `templates/NeoForgePlatformHelper.java.mustache` | `versions/<mc>/neoforge/.../platform/NeoForgePlatformHelper.java` | per MC × NeoForge |
| `templates/neoforge.mods.toml.mustache` | `versions/<mc>/neoforge/.../neoforge.mods.toml` | per MC × NeoForge |
| `templates/neoforge-services.txt.mustache` | `versions/<mc>/neoforge/.../META-INF/services/<fqn>` | per MC × NeoForge |

The seven `multimc/` templates are genuinely new; the rest are
**reused** from the single-MC template set. The renderer flattens the
per-MC context (e.g. `mc_version_26_1_2` → `mc_version`) before
handing the template to the Mustache pass, so the Java + manifest
templates that reference `{{mc_version}}` / `{{neoforge_version}}` /
`{{java_version}}` resolve cleanly without needing separate per-MC
copies.
