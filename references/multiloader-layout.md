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
