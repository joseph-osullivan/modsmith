# Cross-run Minecraft + multi-loader landmine index

Shared knowledge across modsmith runs so a builder hitting a known API
rename or loader-config landmine doesn't grind on it. Every entry in the
MC-API section traces to a real burn; the multi-loader section codifies
gotchas that the planning docs and the modding community discover
repeatedly.

**Read protocol:** when a builder hits a "cannot find symbol" /
class-not-found error in vendor MC code, OR when a build/run fails with a
multi-loader-flavored error (mods.toml not found, mixin refmap mismatch,
ClassNotFoundException at runtime in prod), grep this file by the missing
symbol / error fragment BEFORE spawning a researcher. If it's listed,
apply the fix; if not, escalate as usual and *append the answer here*
once resolved.

**Verify protocol — entries are leads, not gospel.** Every entry was true
when written; nothing here re-verifies itself. Before building on an
entry from a different MC version than the host project's (check
`gradle.properties` first), or on any entry whose claim is
load-bearing for your change, probe it: `scripts/symbol-check.sh
[--subproject :name] <project> < probe.java` compiles a throwaway class
against the real classpath — the only trustworthy oracle. Entries can rot
*within* a version too (NeoForge patches change between loader builds);
when you find a stale entry, correct it IN PLACE with a dated note rather
than deleting — the correction teaches the file's fallibility. If you
find a second within-version stale entry, that's the pre-agreed trigger
to build a sweep mode into symbol-check that re-probes every entry
carrying a verify expression.

**Compile-clean ≠ correct.** A symbol probe verifies existence and
signature, not behavior. Entries tagged *(runtime-semantic)* describe
code that compiles fine and misbehaves — those need a GameTest through
the real trigger path or a decompiled-source read, not a probe.

**Format:** one heading per affected MC version OR landmine category, one
bullet per rename/removal/gotcha. Keep entries to ≤2 lines where
possible. Note how it was verified (probe / decompile / field bug).

---

## Multi-loader landmines (toolchain, not MC API)

These are the highest-frequency gotchas when running modsmith across
Fabric + NeoForge.

### NeoForge ↔ MC version mapping (THE biggest hallucination risk)

- **NeoForge 26.1.x targets Minecraft 26.1.x, NOT 1.21.x.** This is the
  number-one mistake an LLM makes when writing release notes, gradle
  versions, or upgrade guides. NeoForge dropped the `1.` prefix in step
  with Mojang's MC 26.1 (the Mojang versioning change in late 2025).
  Earlier line: NeoForge 21.1.x targets MC 1.21.1 (the current LTS). MC
  1.21 (no patch) does NOT have a NeoForge line — neoforged.net jumped
  straight to 21.1.
- **Always read `gradle.properties` first** for `minecraft_version` and
  `neoforge_version` before writing anything that mentions a version.
  Never derive one from the other.
- **Source of truth:** [`https://versions.neoforged.net`](https://versions.neoforged.net)
  serves the canonical map. The `index.json` lists every active line; each
  line lists `latest`/`recommended`. Use it to verify before committing
  any version-y prose.

### `mods.toml` → `neoforge.mods.toml`

- **The manifest file is `neoforge.mods.toml` in current NeoForge** (renamed
  some time around MC 1.20.5 / NeoForge 20.5). Most online tutorials, blog
  posts, and Stack Overflow answers still say `mods.toml` — they lag the
  rename by 6–12 months.
- The file lives at `neoforge/src/main/resources/META-INF/neoforge.mods.toml`.
  `/modsmith:doctor` hard-fails if it sees `mods.toml` at that path in a
  modsmith project.
- The file's TOML schema is identical to the old `mods.toml`; only the
  filename changed.

### Mixin refmap: Fabric requires it, NeoForge forbids it

- **Fabric (via fabric-loom) generates a `mixin.refmap.json`** for each
  mixin config at build time, and the `fabric.mod.json` references it via
  the mixin's `refmap` field. Loom does this automatically.
- **NeoForge (since NeoForge 20.x with ModDevGradle 2 and native mixin
  support) does NOT use refmaps** and will reject a mixin config that
  declares one (or silently fail to apply mixins, depending on version).
- **A single mixin JSON naively shared between loaders breaks one of them.**
  modsmith's templates generate the Fabric refmap at build time and emit a
  pruned NeoForge-side mixin JSON without the `refmap` field. If you author
  `common/src/main/resources/mymod.mixins.json`, do NOT add a `refmap`
  field — the build task adds it only for the Fabric output.

### Access transformer (NeoForge) vs Access widener (Fabric)

- **NeoForge uses `accesstransformer.cfg`** (Forge syntax — `public-f
  net.minecraft.world.entity.LivingEntity field_6224 someField`) at
  `neoforge/src/main/resources/META-INF/accesstransformer.cfg`.
- **Fabric uses `*.accesswidener`** (Fabric syntax — `accessible field
  net/minecraft/world/entity/LivingEntity someField Lnet/minecraft/world/entity/AttributeMap;`)
  at `fabric/src/main/resources/<modid>.accesswidener`, referenced from
  `fabric.mod.json`.
- **modsmith convention: author once in NeoForge's
  `accesstransformer.cfg` and generate the Fabric `accesswidener` at
  build time.** The templates include a Gradle task `generateAccessWidener`
  that does the rewrite. Hand-editing the generated file is a landmine —
  it will be overwritten on the next build.

### `modImplementation` vs `implementation` in Fabric Loom *(runtime-semantic)*

- **On obfuscated MC (< 26), Fabric mod dependencies MUST use
  `modImplementation` (not `implementation`).** `implementation` includes
  the JAR on the classpath but does NOT run it through Loom's remapper. In
  dev it appears to work; at runtime in a production JAR the remapped names
  don't resolve and you get `ClassNotFoundException` / `NoSuchMethodError`.
  Applies to ALL Fabric API modules, Fabric Loader, and any other mod jar
  (e.g. Trinkets, Cloth Config).
- **Corrected 2026-07 — the rule INVERTS on unobfuscated MC 26.x+.** MC 26
  ships unobfuscated; under Loom's new plugin id (`net.fabricmc.fabric-loom`,
  no-remap mode) the remap configurations are never registered, so
  `modImplementation` does not exist ("Could not find method
  modImplementation()") and plain `implementation` is the ONLY buildable
  form — and the correct one, since there is nothing to remap.
  Build-verified 2026-07 on fresh MC 26.2 scaffolds (v0.2.0 gate). Match
  the dependency form to the plugin id: legacy `fabric-loom` →
  `modImplementation`; `net.fabricmc.fabric-loom` → `implementation`.
- `/modsmith:doctor`'s dependency-form check applies to **obfuscated MC
  lines only**; a flag on raw `implementation` in a 26.x+ no-remap
  subproject is a false positive — verify against the plugin id before
  acting on it.
- NeoForge under MDG uses regular `implementation`/`runtimeOnly` on every
  MC version — ModDevGradle handles the userdev transform at the plugin
  level, not the dependency configuration level. The Fabric rule above
  never applies to NeoForge subprojects.

### Java toolchain by MC version

- **MC 1.21.x ⇒ Java 21.**
- **MC 26.x ⇒ Java 25.**
- modsmith templates always declare:
  ```gradle
  java {
      toolchain.languageVersion = JavaLanguageVersion.of(${java_version})
  }
  ```
  in the root `subprojects {}` block. The Foojay resolver
  (`org.gradle.toolchains.foojay-resolver-convention`) auto-downloads
  the toolchain if not present — so **compile/test** tasks pick the
  right JDK regardless of `JAVA_HOME`.
- **Toolchains do NOT cover the JVM that runs Gradle itself.** The
  buildscript classpath (the fabric-loom / ModDevGradle plugin jars)
  carries a module-metadata constraint requiring a **Java 21+ launch
  JVM**, and foojay provisioning cannot satisfy it. Running `./gradlew`
  under an older `JAVA_HOME` (e.g. a Java 17 default) fails during
  configuration with:
  `Could not resolve net.fabricmc:fabric-loom:... Dependency requires
  at least JVM runtime version 21. This build uses a Java 17 JVM.`
  modsmith scaffolds render `gradle/gradle-daemon-jvm.properties`
  (daemon JVM criteria) so Gradle auto-selects a matching installed
  JDK for the build JVM; in repos without that file, export
  `JAVA_HOME` to a JDK 21+ before building.
- `/modsmith:doctor` reads the MC version from `gradle.properties` and
  hard-fails if the toolchain doesn't match the rule.

### NeoForge mod-bus vs game-bus events

- **NeoForge has two event buses** and subscribing on the wrong one means
  your handler silently never fires.
- **Mod-bus:** lifecycle + registration events. Examples:
  `FMLClientSetupEvent`, `FMLCommonSetupEvent`, `RegisterClientReloadListenersEvent`,
  `RegisterRenderersEvent`, `RegisterEvent`, `DataPackRegistryEvent.NewRegistry`,
  `BuildCreativeModeTabContentsEvent`. Get it from the `@Mod`
  constructor's `IEventBus modEventBus` parameter, or via
  `@EventBusSubscriber(modid="mymod", bus=Bus.MOD)`.
- **Game-bus:** gameplay events. Examples: `PlayerTickEvent`,
  `LivingHurtEvent`, `BreakBlockEvent`, `ServerStartedEvent`,
  `EntityJoinLevelEvent`. Get it from `NeoForge.EVENT_BUS`, or via
  `@EventBusSubscriber(modid="mymod")` (default bus is `GAME`).
- **Subscribing in the wrong place silently no-ops.** No warning, no
  error. The handler is registered to a bus that the event never fires
  on.
- Reference table:

  | Symptom | Likely cause |
  | --- | --- |
  | `RegisterRenderersEvent` handler never fires | registered on game-bus instead of mod-bus |
  | `PlayerTickEvent` handler never fires | registered on mod-bus instead of game-bus |
  | `@EventBusSubscriber` class with mixed handlers | one of them is on the wrong bus |

### Bootstrap entrypoint parameters differ between loaders

- **NeoForge `@Mod` class** is constructed by FML with `(IEventBus modEventBus,
  ModContainer container, Dist dist)` — the first parameter is always
  `IEventBus`; the others can be omitted (FML picks the matching ctor).
  ```java
  @Mod("mymod")
  public final class NeoForgeModInit {
      public NeoForgeModInit(IEventBus modEventBus) {
          ModInit.init();                                      // call into common
          modEventBus.addListener(this::onCommonSetup);        // mod-bus subscriptions
          NeoForge.EVENT_BUS.register(this);                   // game-bus subscriptions
      }
      private void onCommonSetup(FMLCommonSetupEvent event) { ... }
  }
  ```
- **Fabric `ModInitializer.onInitialize()` takes nothing.** All Fabric
  registration is global / static (`Registry.register(...)`,
  `ServerLifecycleEvents.SERVER_STARTED.register(...)`, etc.).
  ```java
  public final class FabricModInit implements ModInitializer {
      @Override public void onInitialize() {
          ModInit.init();                                      // call into common
          ServerLifecycleEvents.SERVER_STARTED.register(server -> { ... });
      }
  }
  ```
- **Common `ModInit.init()` must be parameterless** because it is called
  from both. Anything bus-specific (registering an `@SubscribeEvent`,
  scheduling an MDG mod-bus listener) happens in the loader subproject
  AFTER `ModInit.init()` returns.

### `@ExpectPlatform` is not used

- modsmith uses **`java.util.ServiceLoader`** for expect/actual (see
  `expect-actual-pattern.md`). It does NOT use Architectury, and
  `@ExpectPlatform` annotations will not work — they require the
  Architectury Loom variant and runtime, which modsmith deliberately does
  not depend on.
- **Anyone migrating from an Architectury project** must rewrite every
  `@ExpectPlatform` static method as an interface on a
  `common/.../platform/I*Helper.java` and provide one impl per loader
  subproject, registered via `META-INF/services/`.

---

## Minecraft 26.1 (NeoForge 26.1.x)

- **`ChunkPos` is a `Record` in 26.1.x — the `x`/`z` FIELDS are private.** Use
  the record accessors `x()`/`z()`; `new ChunkPos(long)` is GONE — use
  `ChunkPos.unpack(long)` (statics `ChunkPos.getX(long)`/`getZ(long)` decode a
  packed long directly, `pack(int,int)`/`pack(BlockPos)` encode). Verified via
  `javap` against `minecraft-patched-26.1.2.76-merged.jar` (class extends
  `java.lang.Record`). Discovered in the #201 approach-experience fix — code
  written from 1.21-era memory (`center.x - r`) fails compile with
  "x has private access in ChunkPos".

- **`JigsawPlacement.generateJigsaw(ServerLevel, Holder<StructureTemplatePool>,
  Identifier startJigsawName, int maxDepth, BlockPos, boolean keepJigsaws)
  → boolean`** — the `/place jigsaw` code path for runtime structure gen. Two
  traps: (1) `startJigsawName` is wrapped `Optional.of(...)` and MUST match a
  jigsaw block name in a start-pool piece or it logs "No starting jigsaw ..."
  and returns false (no place-at-pos escape via this public method). For vanilla
  village town-center pools the anchor jigsaw is `minecraft:bottom` (verified in
  `plains_fountain_01.nbt`; there is NO `minecraft:empty` jigsaw in them) — same
  value `/place jigsaw ... minecraft:bottom` uses. (2) javap on the neoform
  `compiledWithNeoForge_*` intermediate shows the 3rd param as `ResourceLocation`
  — a pre-`Identifier`-rename LIE; the final `recompile_*`/real classpath uses
  `Identifier`. Discovered building the #153 PR-3 runtime court fallback.

- **`StructureTemplate.save(CompoundTag)` STAMPS `DataVersion` itself in 26.1.x —
  you do NOT need to add it (a saved template `.nbt` is DFU-safe by default).**
  Its bytecode ends `773: aload_1 / 774: invokestatic NbtUtils.addCurrentDataVersion
  / 777: areturn` (verified `javap -c` against
  `minecraft-patched-26.1.2.76-merged.jar` — the mapped compile classpath — and
  the 26.1.1/26.2 recompile jars). The static
  `StructureTemplateManager.save(Path, StructureTemplate, boolean)` inherits the
  stamp via that same `template.save(...)` call (its `boolean` is
  `DEBUG_SAVE_STRUCTURES_AS_SNBT`, `false`=binary). So the result is DataVersion
  4790 on MC 26.1.2. An explicit `NbtUtils.addCurrentDataVersion` is redundant
  (harmless/idempotent). Accessors: `ServerLevel#getStructureManager()` →
  `get(Identifier)`/`getOrCreate(Identifier)`; capture via
  `StructureTemplate#fillFromWorld(Level, BlockPos, Vec3i, boolean, List<Block>)`.
  NB: 26.1.2 `JigsawBlockEntity` serializes `placement_priority`/`selection_priority`
  even at 0 (older vanilla NBTs like `plains_fountain_01` omit them).
  **METHOD-LESSON (the real landmine):** an EARLIER draft of this entry claimed
  the opposite ("save omits DataVersion") — a FALSE NEGATIVE from a truncated
  `javap` read, NOT a wrong jar. Two traps that produced it: (1) piping `javap -c`
  through `... | grep // Method | head -30` cut the disasm off at ~offset 313,
  hundreds of instructions before the `addCurrentDataVersion` at 774; (2) an awk
  range `/sig/,/^  [a-zA-Z].*(.*);$/` collapsed to a single line because the
  method-signature start line ALSO matches the terminator regex. When probing for
  the ABSENCE of a call, dump the WHOLE method (to a blank-line delimiter) and
  grep the full body — never conclude "not called" from a head-limited or
  range-collapsed view. Discovered building the W5 piece exporter.

- **`ResourceLocation` → `Identifier`, and `ResourceKey.location()` →
  `ResourceKey.identifier()`.** The 26.1 `ResourceLocation`→`Identifier`
  rename cascaded to the accessor: `key.location()` no longer exists —
  `cannot find symbol method location()` on `ResourceKey<T>`. Use
  `key.identifier()` (returns `net.minecraft.resources.Identifier`). Build
  ids with `Identifier.fromNamespaceAndPath(ns, path)`. Caught compiling the
  #153 court-structure locator, LotL court-settlements v2.

- **Zombie family moved to `net.minecraft.world.entity.monster.zombie` in 26.1.**
  `Zombie`, `ZombieVillager`, and — the non-obvious one — **`ZombifiedPiglin`**
  all live in `net.minecraft.world.entity.monster.zombie.*`, NOT the flat
  `monster` package. Decompiled caches lie here: the fabric-loom ng_execute
  decompile (26.3-snapshot) still shows `package net.minecraft.world.entity.monster;`
  for `ZombifiedPiglin`, but the neoformruntime intermediate_results this project
  actually compiles against has `.../monster/zombie/ZombifiedPiglin.class`.
  `AbstractPiglin`/`PiglinBrute` stay in `monster.piglin`, `Hoglin` in
  `monster.hoglin`. Part of a broader 26.1 monster-package reorg into per-family
  subpackages: **`Skeleton`/`AbstractSkeleton`/`WitherSkeleton`/`Stray` →
  `monster.skeleton`**, zombies → `monster.zombie`. When a flat
  `net.minecraft.world.entity.monster.X` import "cannot find symbol", try
  `monster.<family>.X` before anything else. Caught compiling the LotL EMBER-court
  non-aggression filter + its GameTests (issue #193 item 4), Wave 4.
  **Exception — `EnderMan` did NOT move:** it is still the flat
  `net.minecraft.world.entity.monster.EnderMan` in 26.1.2, despite piglin / hoglin
  / skeleton / zombie all moving to subpackages. Don't reflexively try
  `monster.enderman.EnderMan` — it doesn't exist. Confirmed via `symbol-check.sh`
  compiling the LotL HOLLOW-court enderman-tolerance filter (issue #201 W5-3),
  Wave 5 (session_01Sr6AQc4WA2wEBMbpNWkKCM).

- **`minecraft:chain` item/block id is GONE in 26.1 — renamed `iron_chain`**
  (a `copper_chain` sibling was added with the copper-materials pass).
  A recipe/loot JSON referencing `minecraft:chain` fails datapack load with
  `Unknown registry key ... minecraft:item: minecraft:chain` — the mod still
  BUILDS green (data JSONs aren't compile-checked) and the recipe silently
  never exists. Verified via `Blocks.java` in the 26.1.2.76 sources jar
  (`iron_chain`/`copper_chain`). Caught red-first by the #150 recipe pin,
  LotL v0.10.39. Data-id renames are landmines too, not just symbols.

- **`FarmBlock` → `FarmlandBlock`** (same package,
  `net.minecraft.world.level.block`). `MOISTURE` property unchanged. The
  mergeWithSources cache jar still shows `FarmBlock` (pre-mapping lie);
  javap of the recompile output has `FarmlandBlock`. LotL PR 7 of Living
  Kingdoms (FARM template), issue #125.

- **`BannerBlockEntity` has NO public pattern setter in 26.1** — no
  `setPatterns`, and the cache jar's `fromItem(ItemStack, DyeColor)` does
  not exist on the real classpath. To stamp layers on a placed banner
  block: build an ItemStack with `DataComponents.BANNER_PATTERNS`
  (`new BannerPatternLayers.Builder().addIfRegistered(holderGetter,
  BannerPatterns.X, DyeColor.Y).build()`) and call
  `be.applyComponentsFromItemStack(stack)`. Probe:
  `be.applyComponentsFromItemStack(stack)`. LotL PR 7 (court banners),
  issue #125.

- **Standing-banner rotation lives in `RotationSegment`, which is at
  `net.minecraft.world.level.block.state.properties.RotationSegment` in
  26.1.2 (NOT `net.minecraft.util`).** `BannerBlock.ROTATION` is the
  16-step `IntegerProperty` (`BlockStateProperties.ROTATION_16`); set the
  facing with `state.setValue(BannerBlock.ROTATION,
  RotationSegment.convertToSegment(Direction.SOUTH))` (package verified by
  symbol-check against the real classpath). Facts that bite: (1) in **26.1.2
  the vanilla `BannerBlock` default is `ROTATION = 8`, which FACES NORTH**
  (`BannerBlock.java:38 setValue(ROTATION, 8)`, in the decompile with
  WORLD_VERSION 4903 / protocol 776). The renderer sets
  `front-yaw = convertToDegrees(ROTATION)` (`BannerRenderer:246,250`) and
  `SOUTH.toYRot() == 0`, so `convertToSegment(SOUTH) == 0` renders SOUTH —
  meaning ROTATION=0 **DOES flip a defaulted banner from north to south** (a
  real behavioral fix, not a no-op). (2) `RotationSegment` ships TWO
  inconsistent maps — `convertToSegment(Direction)` / `fromDirection` give
  SOUTH→0, WEST→4, NORTH→8, EAST→12 (the render-true one, `data2d << 2`),
  while `convertToDirection(int)` gives 0→NORTH, 8→SOUTH (a different
  convention). Use `convertToSegment(Direction)` for "make the front face D".
  **VERSION TRAP (this caused a wrong review-round claim):** the
  neoformruntime cache holds decompiled jars for MULTIPLE MC versions — a
  `sourcesAndCompiledWithNeoForge_*.jar` there was MC **1.21.1**
  (VERSION_STRING "1.21.1" / WORLD_VERSION 3955), where the banner default
  is `ROTATION = 0`. The default changed 0→8 between 1.21.1 and 26.1.2.
  ALWAYS grep the jar's `SharedConstants.java` (WORLD_VERSION / protocol)
  before trusting a decompiled default: the 26.1.2 source is the
  `decompile_*_output.jar` at WORLD_VERSION 4903, not the "1.21.1"-stamped
  one. LotL wave-4 court banner facing, issue #193.

- **`ServerLevel.getEntitiesOfClass` (any AABB entity query) reads the
  entity-section index and can miss entities `addFreshEntity` just
  accepted.** `PersistentEntitySectionManager.addEntityWithoutEvent`
  stores into the section unconditionally but calls `startTracking` only
  when the section status `isAccessible()`; `EntitySectionStorage
  .getEntities` walks accessible sections only (decompiled 26.1.2,
  PersistentEntitySectionManager.java:84–98, EntitySectionStorage.java:
  114–119). On a cold GameTest cell whose chunk hasn't promoted, a tick-0
  query counts 0 entities that provably exist; direct references work
  fine. Assert via references; poll index-backed queries (LotL #103
  sanctioned class). Root-caused from CI run 28730928599, LotL PR #124
  fix round (2026-07-05).

- **`PlayerList.placeNewPlayer` on a mock connection trips NeoForge's
  negotiated-channel check for any mod that syncs a custom payload at
  login** (`NetworkRegistry`: "Payload … may not be sent to the client!",
  NetworkRegistry.java:436 — modonomicon's `sync_book_data` in the LotL
  dev modset). `GameTestHelper.makeMockServerPlayerInLevel` is therefore
  unusable in a modded dev env; mint the ServerPlayer directly
  (`new ServerPlayer(...)` + `Connection(SERVERBOUND)` + `EmbeddedChannel`
  + `new ServerGamePacketListenerImpl(...)`, which assigns
  `player.connection`) and skip the player list — vanilla packets
  (container close, system chat) bypass the check. LotL PR #124 fix round.

- **`EventHooks.onResourceReload` gained a 3rd parameter between NeoForge
  `.43-beta` and `.76` (same 26.1 line).** `.43-beta`:
  `(ReloadableServerResources, RegistryAccess)`; `.76`:
  `(ReloadableServerResources, RegistryAccess, Map<ListenerKey<?>,
  PreparableReloadListener>)`. The call sits in NeoForge's
  `ReloadableServerResources` patch and runs during `GameTestServer.create`,
  so a caller compiled against the old signature dies at datapack reload
  with `NoSuchMethodError`, before any test runs. Patch-level NeoForge
  bumps within one MC line CAN change patched-API signatures — re-verify
  documented API-shape assumptions on every bump, not just major ones.
  Cited from `patches/.../ReloadableServerResources.java.patch` + javap,
  LotL PR #105 (2026-07-03).

- **(build-infra) CI cache restores NFRT output across NeoForge versions →
  stale patched-MC jar → `NoSuchMethodError` at server boot.**
  `gradle/actions/setup-gradle` restores `~/.gradle/caches/neoformruntime`
  wholesale with no NeoForge-version-scoped key, so after a
  `neoforge_version` bump CI can link against the OLD recompiled MC while
  local builds (fresh cache entry) look green. Detection: `NoSuchMethodError`
  on a NeoForge `EventHooks`/patched-MC symbol only on CI, both flake-retry
  attempts, right after a version bump. Fix: `neoFormRuntime { enableCache =
  false }` (safe, slower) or version-scope the CI cache key. LotL PR #105.

- **26.1 reworked gamerules: `net.minecraft.world.level.GameRules` is GONE**
  → `net.minecraft.world.level.gamerules.GameRules`, keys renamed to
  registry ids (`RULE_DAYLIGHT`/doDaylightCycle → `ADVANCE_TIME`
  ("advance_time"), `RULE_WEATHER_CYCLE` → `ADVANCE_WEATHER`,
  `RULE_MOBGRIEFING` → `MOB_GRIEFING`), accessors are generic
  `rules.get(GameRule<T>)` / `rules.set(rule, value, @Nullable server)` —
  no `getBoolean`/`getRule`. Day/night now rides a per-dimension
  `WorldClock` (`ServerClockManager`): ALL clock advancement is gated on
  `ADVANCE_TIME` (ServerClockManager.java:67, mapped sources), and there
  is a NEW per-clock freeze lever — `/time <clock> pause|resume`
  (TimeCommand.java:90–91) — that no gamerule read can see (the paused
  flag has no public query; only `packState()`). Game time
  (`getGameTime`) still advances under every freeze — only the day
  clocks stop — so time-bounded fallbacks should measure game time.
  Cited from `minecraft-patched-26.1.2.76-sources.jar` + symbol-check,
  LotL PR #121 (2026-07-05).

- **26.1 replaced the villager day-time `Schedule` with the
  `EnvironmentAttribute` system.** `Level.getDayTime()` and
  `ServerLevel.setDayTime(long)` are GONE (symbol-check: both "cannot find
  symbol" on 26.1.2.76); the clock is `getOverworldClockTime()` +
  `Level.environmentAttributes()` (`EnvironmentAttributeSystem`, package
  `net.minecraft.world.attribute`). `Brain.setSchedule` now takes an
  `EnvironmentAttribute<Activity>`, not a `Schedule`: an adult villager gets
  `EnvironmentAttributes.VILLAGER_ACTIVITY` (`Villager.java:215`, 26.1.2 source
  WORLD_VERSION 4903), mapping the dimension clock → `Activity`. The only free
  idle stroll (`VillageBoundRandomStroll`) still lives ONLY in `Activity.IDLE`
  (`VillagerGoalPackages.getIdlePackage`, line 194), forced each tick by the
  priority-99 CORE `UpdateActivityFromSchedule`. GameTest implication: an
  unemployed villager strolls ONLY when the uncontrolled, freely-advancing
  test-world clock happens to sit in the IDLE window — there is NO static-safe
  hook to drive it into that window, so a "villager wanders" GameTest is
  irreducibly nondeterministic (on top of the cold-cell `createPath` flake
  class). Assert the STRUCTURAL un-freeze (a plain `Villager` carries the stock
  brain — `setSchedule(VILLAGER_ACTIVITY)` + the IDLE package — with no custom
  overrides), never emergent wander. Panic-on-hurt, HOWEVER, IS
  schedule-independent: `VillagerPanicTrigger` is priority-0 in the always-on
  CORE package (`VillagerGoalPackages.getCorePackage`) and its `start` calls
  `setActiveActivityIfPossible(Activity.PANIC)` whenever the brain holds
  `MemoryModuleType.HURT_BY` (`VillagerPanicTrigger.java:20-33, 45-47`), so a real
  `hurtServer(mobAttack)` → assert `HURT_BY` +
  `getBrain().isActive(Activity.PANIC)` is a DETERMINISTIC "responds to being hit"
  pin (brain-state reads, no `createPath`) — BUT `HURT_BY` reaches the brain via a
  SENSOR + a GAME-TIME retention window, so DRIVE THE BRAIN SYNCHRONOUSLY, do not
  world-tick-poll. Two traps: (1) `HURT_BY` is not written on damage — `HurtBySensor
  .doTick` writes it from `getLastDamageSource()` (`HurtBySensor.java:18-24`), and
  `Sensor` scans at `DEFAULT_SCAN_RATE = 20` with a RANDOM phase (`Sensor.java:41`), so
  a fixed `runAfterDelay(10)` flakes ~½ the time (LotL run 1 @456c4ce). (2)
  `getLastDamageSource()` EXPIRES 40 GAME ticks after the hit (`LivingEntity.java:1419-
  1425`, via `getGameTime()`) and then `HurtBySensor` ERASES `HURT_BY`
  (`HurtBySensor.java:26-28`); combined with the #103 "dead cell never world-ticks the
  entity / never evaluates poll callbacks" class, a 100-tick poll can see `HURT_BY`
  NEVER appear (LotL run 2 @8dd7cb0). Robust fix: `for(i<40) entity.tick();` at tick 0
  (GuardShield/StewardTether idiom) — reaches `customServerAiStep`→`brain.tick` every
  iteration (`serverAiStep` `(tickCount+id)%2` gate is bypassed while `tickCount<=1`,
  `Mob.java:720-721`), AND freezes `getGameTime()` (driven ticks don't advance it) so
  the 40-tick retention never lapses mid-drive. Then assert synchronously. LotL W5-5
  (#201, serial-gate runs 1+2 red → synchronous drive).
  NB: the neoform cache also holds a STALE 1.21.1 decompile (WORLD_VERSION 3955,
  no `world/attribute/`); the real 26.1.2 source is the `decompile_*_output.jar`
  at WORLD_VERSION 4903.

- **`/time add N` interprets `N` as DAYS, not ticks in 26.1.** `/time add 24000`
  jumps ~24,000 MC days (576M ticks), not one day. Use `/time set N` (still
  ticks) or `/time add 1d`-style syntax if you want a day-grained jump. Day-tick
  handlers that gate on `getOverworldClockTime() % 24000 == 0` will silently
  miss any time-jump that overshoots the boundary — trigger on day-index
  *change* (`current/24000 != last/24000`) instead. Discovered in
  animal-weights run-001 manual playtest.

- **`@EventBusSubscriber(value = Dist.DEDICATED_SERVER)` silently breaks
  single-player.** In SP the integrated server runs inside the client
  (`Dist.CLIENT`), so DEDICATED_SERVER-restricted handlers never register.
  `runGameTestServer` is a real dedicated server so tests pass while the
  mod is inert in `runClient`. Don't use a `Dist` value on server-side
  handlers — register on all dists and gate work with runtime
  `isClientSide()` / `instanceof ServerLevel` checks. Discovered in
  animal-weights run-001 manual playtest.

- **`MushroomCow` is NOT a subclass of `Cow` in 26.1.** Both extend the new
  `net.minecraft.world.entity.animal.cow.AbstractCow`. Pre-26.1 the Mooshroom
  was `MushroomCow extends Cow`; now they are siblings under `AbstractCow`.
  Species checks that want "all bovines including Mooshroom" must use
  `instanceof AbstractCow`. `MushroomCow` itself lives at
  `net.minecraft.world.entity.animal.cow.MushroomCow`. `Rabbit` lives at
  `net.minecraft.world.entity.animal.rabbit.Rabbit` (same 26.1 subpackage
  reshuffle). Discovered in animal-weights run-003.

- **`Level#getDayTime()` is gone.** Replaced by `Level#getOverworldClockTime()`
  (returns the canonical overworld clock in ticks regardless of dimension)
  and `Level#getDefaultClockTime()`. Backed by the new
  `net.minecraft.world.clock.ClockManager` / `WorldClock` subsystem in
  MC 26.1.2. Use `getOverworldClockTime() % 24000L == 0L` for dawn boundary
  detection. Discovered in animal-weights run-001 task-2.

- **`Cow`, `Pig`, `Sheep`, `Chicken` moved into species subpackages.**
  `net.minecraft.world.entity.animal.{Cow,Pig,Sheep,Chicken}` →
  `animal.cow.Cow`, `animal.pig.Pig`, `animal.sheep.Sheep`,
  `animal.chicken.Chicken`. `Animal` base class stays at
  `world.entity.animal.Animal`. Same 26.1 reshuffle that moved
  `Zombie → monster.zombie.Zombie`. Discovered in animal-weights run-001
  task-2.

- **`Entity#moveTo(...)` → `Entity#snapTo(...)`** (all overloads). Also gained
  `absSnapTo(...)` for absolute positioning. The earlier "decompiled-with-NeoForge"
  cache jar still shows `moveTo` (it's pre-mapping), but the actual compileClasspath
  uses the client/server jar where it's `snapTo`. Discovered in animal-weights
  run-002 (cost: 210k tokens to gametest-author).

- **`MobEffects` vocabulary rename in MC 26.1.** `MOVEMENT_SLOWDOWN → SLOWNESS`,
  `MOVEMENT_SPEED → SPEED`, `DIG_SLOWDOWN → MINING_FATIGUE`, `JUMP → JUMP_BOOST`,
  `CONFUSION → NAUSEA`, `DAMAGE_BOOST → STRENGTH`, `DAMAGE_RESISTANCE → RESISTANCE`.
  Discovered in animal-weights run-001 task-4.

- **`@GameTestHolder` / `@PrefixGameTestTemplate` annotation-based GameTest
  discovery is gone from the main compileClasspath.** The annotations exist
  in the userdev jar but are not exported to consuming mods. Use the
  `DeferredRegister<TestFunction>` + `data/<modid>/test_instance/<name>.json`
  pattern instead (see lord-of-lands `ModGameTests.java` for a reference).
  Discovered in animal-weights run-001 (cost: 122k tokens before resolution).

- **`ServerLevel#getSharedSpawnPos()` → `getLevelData().getRespawnData().pos()`.**
  `RespawnData` is a new top-level record bundling pos + angle + dim. Discovered
  in run-024 task-4 (cost: 121 tool calls / 150k tokens before resolution).

- **`BlockEvent.BreakEvent` → `BreakBlockEvent`.** Top-level event, not nested
  under BlockEvent anymore. Discovered in run-026 (PR #82).

- **`Tier`, `ArmorItem`, `SwordItem`, `TieredItem` deleted.** Use the project's
  `TierHelper` registry-key map. Modded gear that isn't in the map is ignored
  by guard tier checks until someone adds data-component-based generalization.

- **`LivingEntity#hurtCurrentlyUsedShield` is REMOVED in 26.1** — blocking is
  generalized through `LivingEntity#applyItemBlocking` driven by the
  `blocks_attacks` data component (`item_damage` factor, default 1.5).
  *Correction (Fable review, 2026-07-02):* this entry previously claimed the
  method "no longer reaches non-Player subclasses" — it does not exist at
  all, and since `applyItemBlocking` lives on LivingEntity, entity shields
  may already drain durability with no mod code. Verify with a GameTest
  before writing any shield-drain workaround (LotL proposal 01 has the
  verify-first plan).

- **`ComponentSerialization.STREAM_CODEC.encode(buf, component)`**, not
  `buf.writeComponent(...)` (latter doesn't exist). Requires a
  `RegistryFriendlyByteBuf`.

- **`Block.Properties` requires registry ID before construction.** Use
  `DeferredRegister.Blocks.registerBlock(name, Ctor::new, () -> Properties.of()...)`,
  not `register(name, () -> new MyBlock(...))` — the latter mod-load-NPEs.

- **`IMenuTypeExtension.create(...)`** (from `net.neoforged.neoforge.common.extensions`)
  is the menu-type factory. `new MenuType<>(...)` directly does not work.

- **`RenderLivingEvent.Pre` is now state-based, not entity-based, in
  NeoForge 26.1.2.43+.** Event signature is
  `Pre<T extends LivingEntity, S extends LivingEntityRenderState,
  M extends EntityModel<? super S>>`. Exposes `getRenderState()`, NOT
  `getEntity()`. Hands you a `SubmitNodeCollector`, NOT
  `MultiBufferSource` — no per-vertex consumer wrap. Body tint is
  computed inside `LivingEntityRenderer.submit(...)` from the
  **protected** `getModelTint(S state)` method (default `-1`) — no event
  setter exposes it. To apply a tint you must either (a) subclass each
  species renderer and override `getModelTint`, re-registered via
  `EntityRenderersEvent.RegisterRenderers`, or (b) mixin into
  `LivingEntityRenderer#getModelTint` with `@Inject(at = HEAD,
  cancellable = true)` and `cir.setReturnValue(tint)`. Discovered in
  animal-weights run-005 task-4 (first attempt burned 134k tokens
  before recognising the architectural blocker).

- **`RegisterRenderStateModifiersEvent`** (NeoForge mod-bus) is the
  entry point for stashing per-entity data on the render state. Use
  `ContextKey<T>` (from `net.minecraft.util.context.ContextKey`) as the
  key type and `event.registerEntityModifier(typeToken,
  BiConsumer<Entity, RenderState>)`. The raw
  `Class<LivingEntityRenderer>` overload doesn't bind generics cleanly;
  use `TypeToken<LivingEntityRenderer<LivingEntity,
  LivingEntityRenderState, ?>>` to pin wildcards. **Note**: this only
  stashes data — it does NOT apply a tint. See the
  `RenderLivingEvent.Pre` entry above for the tint primitive.
  Discovered in animal-weights run-005 task-4.

- **NeoForge 26.1 ships Mixin natively — no `build.gradle` plugin block
  required.** Drop a mixins JSON into `src/main/resources/`, reference
  it from `META-INF/neoforge.mods.toml` with `[[mixins]] config =
  "yourmod.mixins.json"`, and the ModDevGradle 2 build picks it up. No
  `apply plugin: 'org.spongepowered.mixin'`, no `mixin { config ... }`
  block, no Loom-style configuration. Discovered in animal-weights
  run-005 task-4 attempt-2. The mixin compatibility level
  (`JAVA_25` etc.) is a string constant on
  `MixinEnvironment.CompatibilityLevel` — confirm a value is valid by
  `javap`-ing the bundled `sponge-mixin-*.jar` in the NeoForge cache if
  uncertain.

- **`Entity#getTags()` → `Entity#entityTags()`.** Returns the same
  `Set<String>`. `addTag(String)` / `removeTag(String)` /
  `hasTag(String)` are unchanged. Discovered in animal-weights run-005
  task-5 (researcher initially missed this rename and claimed
  `getTags()` was still public; builder corrected on its own).

- **`Component.Serializer` (the inner class on `Component`) is gone.**
  Replaced by `net.minecraft.network.chat.ComponentSerialization`. To
  encode a `Component` to NBT or JSON in 26.1, use
  `ComponentSerialization.CODEC.encodeStart(NbtOps.INSTANCE,
  component).getOrThrow(...)` → `Tag`. Discovered in animal-weights
  run-005 task-5.

- **`Entity#load(CompoundTag)` → `Entity#load(ValueInput)`.** The
  `ValueInput` / `ValueOutput` interfaces (in
  `net.minecraft.world.level.storage`) wrap NBT for entity save/load.
  To call `load` from mod code with a hand-built `CompoundTag`, wrap
  via `TagValueInput.create(ProblemReporter.DISCARDING,
  entity.registryAccess(), tag)`. `Entity#saveAdditional` likewise
  takes `ValueOutput`. Discovered in animal-weights run-005 task-5.

- **`EntityType#create(Level)` → `EntityType#create(Level,
  EntitySpawnReason)`.** All four create overloads in 26.1 require an
  `EntitySpawnReason` enum (e.g. `EntitySpawnReason.LOAD`,
  `COMMAND`, `MOB_SUMMONED`). Was `MobSpawnType` pre-26.1. For
  mod-spawned utility entities (Display, etc.), `EntitySpawnReason.LOAD`
  is the most neutral choice — bypasses spawn-event side-effects.
  Discovered in animal-weights run-005 task-5.

- **`Display.TextDisplay#setText(Component)` is private in MC 26.1** —
  the field-setter you'd expect doesn't exist publicly. The canonical
  approach is the NBT roundtrip via `Entity#load(ValueInput)`: build a
  `CompoundTag` with key `"text"` whose value is the JSON-encoded
  Component (via `ComponentSerialization.CODEC`), wrap as `ValueInput`,
  call `display.load(valueInput)`. Vanilla's `readAdditionalSaveData`
  then routes the resolved text into the data-watcher slot.
  Discovered in animal-weights run-005 task-5.

- **`LandRandomPos.getPos(PathfinderMob, int, int)` returns
  `@Nullable Vec3`.** Standard random-pos sampling for ground animals;
  filters water destinations via `GoalUtils.isWater`. Use over
  `DefaultRandomPos` when the mob must land on solid ground.
  Confirmed in animal-weights run-005 task-6.

- **`GameTestHelper.makeMockPlayer(GameType)` returns `Player`, NOT
  `ServerPlayer`** (`makeMockServerPlayer` doesn't exist). For a ServerPlayer
  in a GameTest use NeoForge `FakePlayerFactory.get(ServerLevel, GameProfile)`
  — but `FakePlayer` overrides `openMenu(MenuProvider, Consumer)` as a NO-OP,
  so menu-open assertions need a recording subclass. Fable review, LotL
  batch A (both burned a red run each).

- **GameTest batching is keyed on the test_environment holder**
  (`GameTestBatchFactory.divideIntoBatches` → groupingBy, ≤50/batch). Distinct
  `data/<ns>/test_environment/<name>.json` files ⇒ separate sequential
  batches — the isolation primitive for tests that fight over global state.
  Types: `minecraft:all_of {definitions:[]}` (default's shape) and
  `minecraft:function {setup, teardown}` (mcfunction hooks per batch). Fable
  review, LotL PR #94 rider 2.

- **The GameTest framework NEVER clears finished tests' entities or
  structures** — the arena accumulates across batches, and anything with
  global reach (POI scans, entity sweeps, vanilla `AcquirePoi`'s 48-block
  bed scan) crosses cell boundaries. Kill-sweep via a function-type
  environment setup + in-test cleanup on success is the working pattern
  (LotL `clear_lingering_npcs.mcfunction`). Fable review, LotL PR #94.

- **NeoForge 26.1 GLMs have NO `global_loot_modifiers.json` index.**
  `LootModifierManager` is a `SimpleJsonResourceReloadListener` over
  `data/*/loot_modifiers` — every JSON in the folder auto-registers. A rule
  requiring the old index file would be WRONG for 26.1 (and its absence is
  not a bug). Verified in the 26.1.2.43 universal jar; Fable review, T&F
  batch F.

- **`Player.PERSISTED_NBT_TAG` ("PlayerPersisted") clone-copy survives in
  26.1** — patched `ServerPlayer.restoreFrom` copies that subtag of
  `getPersistentData()` to the respawned player (verified in patched
  bytecode). It rides normal playerdata saves, so it's the restart-safe home
  for cross-death mod state. Clear it after consuming — a stale tag
  re-applies on the next death. Fable review, T&F batch B.

- **`CompoundTag.getCompound(String)` returns `Optional<CompoundTag>` in
  26.1**; the legacy empty-if-absent behavior is `getCompoundOrEmpty`. Same
  Optional-ification across `getList`/`getString`/etc. — `getXxxOr(key,
  default)` is the other escape hatch. Fable review, T&F batch B.

- **`RegistryOps` come from
  `registryAccess().createSerializationContext(NbtOps.INSTANCE)`** for
  codec-encoding registry-dependent data (ItemStack NBT etc.). Fable
  review, T&F batch B.

- **`getOrThrow` inside `Optional.map` throws PAST a downstream
  `orElse(null)`** — not an API rename, a recurring crash pattern:
  `access.lookup(REG).map(r -> r.getOrThrow(key)).orElse(null)` crashes on
  datapack drift instead of degrading. Null-safe shape:
  `.flatMap(r -> r.get(key)).orElse(null)`. Two independent copies found in
  T&F (Fable review, batch B).

- **`LivingDeathEvent` is cancellable in 26.1** and fires post-mitigation,
  AFTER vanilla's in-hand totem check — the correct hook for
  totem-like death prevention (cancel + `setHealth(1)`).
  `LivingIncomingDamageEvent` fires PRE-armor; lethality math there
  overcounts. Fable review, T&F batch B.

- **`MinecraftServer#getProfileCache()` is gone in 26.1.** For
  UUID→name resolution: online players via
  `getPlayerList().getPlayer(uuid)`, offline via your own persisted name
  map — there is no vanilla offline cache accessor anymore. Fable review,
  LotL batch A.

- **`Mob#setNoAi(true)` does NOT gate `aiStep()` in 26.1** — noAi gates
  the brain/goal tick, but `aiStep`/`customServerAiStep` logic still runs
  (e.g. `tickShieldBlock` lowered a manually-raised shield on a noAi mob).
  Stage test entities via the production path instead of assuming noAi
  freezes them. Fable review, LotL PR #98.

- **GameTest run totals include vanilla `always_pass`** — every run's
  reported count is your test count +1, so derived-count assertions must
  use `≥`, not `==`. Corollary: GameTestServer exits 0 printing "All 0
  required tests passed" when discovery silently breaks — pair any
  source-set/discovery change with a tests-run ≥ manifest-count assert.
  Fable review, LotL PR #97.

- **Two listeners on the same NeoForge event (e.g. `ServerTickEvent.Post`)
  have NO defined relative order** unless explicit priorities are set.
  Never read state that another same-event listener writes in the same
  tick and assume it ran first — keep your own cursor (LotL PR #95's
  renown gate read another listener's `lastUpkeepDay` and could silently
  never update). Fable review, LotL batch C.

- **Zombify-cure trade discounts can't be zeroed entity-side — zero them
  in the trade DATA (`reputation_discount: 0`).** The cure writes gossip
  onto the cured villager (`Villager.onReputationEventFrom`,
  ZOMBIE_VILLAGER_CURED → MAJOR_POSITIVE +20 / MINOR_POSITIVE +25), but
  (a) gossip SPREADS between villagers (`Villager.gossip` →
  `GossipContainer.transferFrom`), and (b) curing a custom Villager
  subclass yields a PLAIN `Villager` that keeps the profession — and with
  26.1's data-driven trades, the profession's offers too — so overrides
  on your entity class never see the discount path. The discount itself
  is `reputation × offer.getPriceMultiplier()`
  (`Villager.updateSpecialPrices`), and the multiplier is the per-trade
  JSON's `reputation_discount` (default 0 in 26.1!) — shipping every
  trade with an explicit `reputation_discount: 0` kills the exploit for
  ANY holder of those offers. Pair with a Tier-1 JSON walk so future
  trades keep the zero. LotL PR 2 of Living Kingdoms (miner trades),
  issue #113.

- **`displayClientMessage` is gone from `Player` in 26.1** — use
  `sendSystemMessage(Component)` (chat line); there is no actionbar
  one-liner on Player anymore. LotL Living Kingdoms PR 2.

- **`GameTestHelper.placeAt`/`useBlock` build their `UseOnContext` from
  the player's HELD item** (`UseOnContext(player, hand, hit)` reads
  `player.getItemInHand(hand)`), and `makeMockPlayer`'s hands are empty —
  in LotL's suite an empty-hand `placeAt` placed nothing. Put the stack
  in the mock player's `MAIN_HAND` (then `stack.useOn(context)` yourself
  if you want the `InteractionResult`). Also remember
  `ServerLevel.updatePOIOnBlockStateChange` routes PoiManager add/remove
  through `server.execute` — POI-index visibility after any in-test
  `setBlock` is NEXT-cycle, never same-call (bounded-poll class per the
  LotL flake ledger). LotL Living Kingdoms PR 2, issue #113.

- **Modonomicon `parents` entries take `{ "entry": "<category>/<entry>" }`
  with a BOOK-RELATIVE path — an `entry_id` key or a namespaced id
  (`lordoflands:...`) is silently dropped**: the book loads, the entry
  renders, but the parent link/arrow vanishes and gating breaks. No build
  error, no log line. Caught at the PR-11 integration gate (LotL Living
  Kingdoms); executable check landed as verifyMod rule 18 (2026-07-09).

- **`@EventBusSubscriber` has NO `bus =` attribute in NeoForge 26.1** —
  the attribute is gone; events auto-route to the right bus per their type.
  `modid =` (and the optional `value = Dist` — see the DEDICATED_SERVER
  entry above for its own trap) remain. Relocated 2026-07-09 from the
  mc-mod-builder inline snapshot (originally verified 2026-05).

- **`BlockEntity.saveAdditional`/`loadAdditional` take `ValueOutput`/
  `ValueInput` in 26.1** (NeoForge patched the parent) — the old
  `(CompoundTag, HolderLookup.Provider)` signatures are gone. Same
  ValueInput/ValueOutput family as the `Entity#load` entry above.
  Relocated 2026-07-09 from the mc-mod-builder inline snapshot
  (originally verified 2026-05).

- **`ShowTradesToPlayer` brain behavior clears `EquipmentSlot.MAINHAND`
  when a player stands near any Villager.** A Villager subclass with no
  trades still runs it — override `setItemSlot` to reject MAINHAND+EMPTY
  if the subclass must keep a held item. Relocated 2026-07-09 from the
  mc-mod-builder inline snapshot (originally verified 2026-05).

- **`PoiManager.release(pos)` throws `IllegalStateException` when the POI
  doesn't exist** — always wrap in try/catch when releasing a ticket you
  didn't provably acquire. Relocated 2026-07-09 from the mc-mod-builder
  inline snapshot (originally verified 2026-05).

- **`LivingChangeTargetEvent` accessors are `getNewAboutToBeSetTarget()` /
  `getOriginalAboutToBeSetTarget()` / `setNewAboutToBeSetTarget(...)` in
  NeoForge 26.1 — NOT the Forge-era `getNewTarget()` / `getOriginalTarget()`
  (those do not exist and won't compile). `getTargetType()` returns
  `ILivingTargetType` (the interface), not the `LivingTargetType` enum.
  Cancel with `setCanceled(true)` (`ICancellableEvent`; `isCanceled()`, not
  `isCancelable()`). The event IS the goal-agnostic target-veto chokepoint:
  the 26.1.2.76 patched `Mob.setTarget(LivingEntity)` fires it via
  `CommonHooks.onLivingChangeTarget(...)`, and on `isCanceled()` skips the
  `putfield target` entirely (verified by `javap -c` on the
  neoformruntime `compiledWithNeoForge` output jar — the neoform *cache*
  jar's `Mob.setTarget` is pre-patch and just does `putfield`, so it lies).
  So a cancelled event leaves the target unchanged — assert `getTarget()`
  stays null in a test that calls `setTarget(x)`. Found #143 leg 2 (court
  zombie target veto), verified via symbol-check + bytecode 2026-07-10.

### Runtime-semantic entries recovered from the run-archive record

These were stranded in old commit messages / build logs (runs 006–023,
mined 2026-07-03). All bit once in production paths; per the verify
protocol, probe before building on any of them cross-version. The common
shape: **they all compile clean** — symbol probes can't catch them.

- **`finalizeSpawn` does NOT run on `addFreshEntity`** — mobs spawn
  without their equipment/AI init (Archers that never shoot, inert raid
  mobs). Trigger the production spawn path or call the init explicitly.
  Runs 008/012.
- **`Container#slotsChanged` never fires for `ItemStackHandler`-backed
  slots** — capability-based inventories bypass it. Run 006.
- **`ServerLevel.sendParticles` (7-arg) silently drops particles beyond
  ~32 blocks of each player** unless the overrideLimiter arg is set.
  Run 017.
- **Vanilla brain activities (e.g. REST) override `goalSelector` goals on
  Villager subclasses** — a goal that "compiles but won't fight." Run 019.
- **`findNearestMapStructure` returns y=0 positions and takes a
  CHUNKS-denominated radius**; `getHeight` on unloaded chunks returns
  `minBuildHeight`. Three stacked bugs in run 012.
- **`StructureManager.getStructureWithPieceAt` has NO `ResourceKey<Structure>`
  overload in 26.1.2** — the overloads are `(BlockPos, TagKey<Structure>)` and
  `(BlockPos, HolderSet<Structure>)` (both return a `StructureStart` with
  `.isValid()`). To test "is this pos inside ONE specific structure", wrap the
  key's holder: `HolderSet.direct(registryAccess().lookupOrThrow(Registries.STRUCTURE)
  .get(key).get())` then pass that HolderSet. Symbol-checked 26.1.2.76 (Wave-4
  Lane H court-shell discovery). Corollary: **`BuiltInStructures` does NOT
  resolve** at `net.minecraft.world.level.levelgen.structure.BuiltInStructures`
  (import fails) — reference vanilla structure keys by identifier instead:
  `ResourceKey.create(Registries.STRUCTURE, Identifier.fromNamespaceAndPath("minecraft","end_city"))`.
- **`helper.getBlockEntity(pos)` can return null in GameTests where
  `getLevel().getBlockEntity(pos)` works.** Run-archive record.
- **Item GUI canvas is 256×256 and there is no `generic_27.png`** —
  container screens need the vanilla "transformation" wrapper for icons.
  Runs 014/016.
- **Trust the universal jar, not `ng_execute` caches, for vanilla asset
  questions** — `jar tf` + inspect the actual patched jar. Run 014.
- **`Heightmap.Types.WORLD_SURFACE_WG` is worldgen-only: pruned at FULL
  chunk status, and an on-demand runtime query re-primes it with the
  NOT_AIR predicate** — it counts tree canopy AND goes stale on block
  changes. `WORLD_SURFACE` also counts leaves. Runtime "ground" is
  `MOTION_BLOCKING_NO_LEAVES`, and NO surface heightmap is trustworthy
  in a roofed/voided realm (Nether answers the bedrock roof, deep dark
  the meadow above, End void world-min) — column-march or keep the
  caller's Y there. Bit as v0.10.58's floating-courts playtest defect;
  fixed in LotL PR #190 (CourtGroundSnap javadoc has the full story).

- **`JigsawStructure` is `final` in 26.1.2** (javac: "cannot inherit from
  final JigsawStructure") — you CANNOT subclass it to add a siting gate,
  despite `findGenerationPoint(GenerationContext)` being `public` non-final.
  A custom jigsaw structure that only wants an extra spawn predicate must
  extend `Structure` and REPLICATE `JigsawStructure.findGenerationPoint`
  verbatim: build `startPos` from `startHeight.sample(random,
  WorldGenerationContext)` at `chunkPos.getMinBlockX/Z`, then
  `return JigsawPlacement.addPieces(context, startPool, startJigsawName,
  size, startPos, useExpansionHack, projectStartToHeightmap,
  maxDistanceFromCenter, PoolAliasLookup.create(poolAliases, startPos,
  context.seed()), dimensionPadding, liquidSettings)` (11-arg, all public).
  Mirror `JigsawStructure.CODEC`'s field set (start_pool, start_jigsaw_name,
  size, start_height, use_expansion_hack, project_start_to_heightmap,
  max_distance_from_center via `JigsawStructure.MaxDistance.CODEC`,
  pool_aliases, dimension_padding, liquid_settings) and return your own
  `StructureType`. Do NOT reach for RS's `GenericJigsawStructure` fallback —
  it drags in RS's `PieceLimitedJigsawManager` reimplementation; vanilla
  `JigsawPlacement.addPieces` is the un-forked path. Verified building the
  LotL Ember lava-lake court, Wave 5 (session_01Sr6AQc4WA2wEBMbpNWkKCM).

- **`ChunkGeneratorStructureState.hasStructureChunkInRange(Holder<StructureSet>,
  int x, int z, int chunkRange) → boolean`** is the seed-deterministic
  "is another structure set placed near here" query — NO chunk is loaded or
  generated. Use it in a custom `StructurePlacement` for cross-set exclusion
  (avoid) OR anchoring (require, e.g. the Silent court seating near
  `minecraft:ancient_cities`). It calls the OTHER set's `placement().
  isStructureChunk(...)` (javap -c verified), so recursion happens ONLY when
  two sets reference each other; referencing a vanilla set that never
  references back is safe. `RandomSpreadStructurePlacement` super-ctor is
  `(Vec3i, StructurePlacement.FrequencyReductionMethod, float, int salt,
  Optional<ExclusionZone>, int spacing, int separation, RandomSpreadType)`;
  `isStructureChunk` is `public`, `isPlacementChunk` `protected` — both
  overridable. The RS `AdvancedRandomSpread` port compiles clean on
  26.1.2.76. Wave 5 (session_01Sr6AQc4WA2wEBMbpNWkKCM).

- **`StructurePlacement` getters `locateOffset()/frequencyReductionMethod()/
  frequency()/salt()/exclusionZone()` are `protected`** — a subclass codec
  built with `RecordCodecBuilder` must reference them through the SUBCLASS
  type (`YourPlacement::locateOffset`), never `StructurePlacement::locateOffset`
  (javac: "locateOffset() has protected access in StructurePlacement",
  surfacing as "cannot infer type-variable O"). Also: the no-padding
  `DimensionPadding` constant is **`DimensionPadding.ZERO`**, not `NONE`
  (`JigsawStructure.DEFAULT_DIMENSION_PADDING == DimensionPadding.ZERO`).
  Wave 5 (session_01Sr6AQc4WA2wEBMbpNWkKCM).

---

### Entries ported from the lord-of-lands CLAUDE.md (2026-10-31; each traces to a shipped or playtest-caught bug there)

- **Custom Villager renderers must add `ItemInHandLayer`** —
  `addLayer(new ItemInHandLayer<>(this, ctx.getItemInHandRenderer()))`.
  Vanilla `VillagerRenderer` doesn't, so equipped weapons on a villager
  subclass are invisible without it. *(runtime-semantic, render)*
- **26.1 screen API renames**: `Screen.keyPressed(KeyEvent)`,
  `mouseClicked(MouseButtonEvent, boolean)`, `extractBackground` instead of
  `renderBg`, `GuiGraphicsExtractor` instead of `GuiGraphics`. Old
  signatures compile as unrelated overloads and never fire. *(probe)*
- **`ZombieVillager.finishConversion` recreates a plain `EntityType.VILLAGER`**,
  preserving VillagerData (profession + level), XP, gossips, and offers —
  every field and override on a Villager *subclass* dies with it, and a
  profession's data-driven trade map applies to ANY holder. Gates that must
  survive zombify-and-cure need a cure-side re-conversion on
  `LivingConversionEvent.Post`, deferred one server task — the event fires
  before `Mob.convertTo` adds the new entity. *(runtime-semantic, field bug)*
- **BlockItems must go through `registerSimpleBlockItem`** (or another
  `useBlockDescriptionPrefix`-flipping path) so tooltips look up
  `block.<ns>.<id>`, not `item.<ns>.<id>`. *(field bug)*
- **Server-side menu open is
  `player.openMenu(new SimpleMenuProvider(factory, title), buf -> buf.writeX(...))`**
  — the third-arg callback populates the payload the client-side menu
  constructor reads; omit it and the client constructor sees an empty buf.
  Factory is `IMenuTypeExtension.create(...)` from
  `net.neoforged.neoforge.common.extensions`, not `new MenuType<>`. *(field bug)*

### Entries recorded from modsmith field runs (not in the lord-of-lands index)

- **Patch-level NeoForge bumps can change patched-API signatures within
  one MC line.** Field case: `EventHooks.onResourceReload` went from
  `(ReloadableServerResources, RegistryAccess)` in 26.1.2.43-beta to a
  3-arg form (`+ Map<ListenerKey<?>, PreparableReloadListener>`) in
  26.1.2.76. The call sits in NeoForge's `ReloadableServerResources`
  patch and runs during `GameTestServer.create` — a caller compiled
  against the old shape dies at datapack reload with `NoSuchMethodError`
  before any test runs. Re-verify documented API-shape assumptions on
  EVERY NeoForge bump, not just MC-line jumps. Cited from the .76
  `ReloadableServerResources.java.patch` + javap, field-verified 2026-07.
  *(runtime-semantic)*

- **(build-infra) Cross-version NFRT cache restores in CI produce stale
  patched-MC jars after a NeoForge bump.** `gradle/actions/setup-gradle`
  restores `~/.gradle/caches/neoformruntime` with no NeoForge-version-
  scoped key, so CI can link against the OLD recompiled Minecraft while
  fresh local builds look green. Detection signature: `NoSuchMethodError`
  on a patched-MC/`EventHooks` symbol only on CI, surviving a flake
  retry, immediately after a `neoforge_version` bump. Fix:
  `neoFormRuntime { enableCache = false }` (safe, slower) or a
  version-scoped CI cache key. Field-verified 2026-07.

- **`Player.PERSISTED_NBT_TAG` ("PlayerPersisted") is clone-copied by the
  patched `ServerPlayer.restoreFrom`** — the supported place to stash data
  that must survive death. Verified in 26.1.2 bytecode. If you both write
  it on death and read-clear it on clone, clear BOTH sides or you get
  dupes.

- **`MinecraftServer#getProfileCache()` is gone in 26.1.** Online players:
  `getPlayerList().getPlayer(uuid)`; offline: keep your own persisted
  name map — there is no vanilla offline cache accessor anymore.

- **GameTest run totals include vanilla `always_pass`** — reported count
  is your test count +1; derived-count assertions must use `≥`, not
  `==`. Corollary: GameTestServer exits 0 printing "All 0 required tests
  passed" when discovery silently breaks — pair discovery/source-set
  changes with a tests-run ≥ manifest-count assert. *(runtime-semantic)*

- **`Mob#setNoAi(true)` does NOT gate `aiStep()`** — noAi gates the
  brain/goal tick, but `aiStep`/`customServerAiStep` logic still runs
  (e.g. shield-lowering). Stage test entities via the production path
  instead of assuming noAi freezes them. Field bug, 2026-07.
  *(runtime-semantic)*

- **Two listeners on the same NeoForge event have NO defined relative
  order** unless explicit priorities are set. Never read state another
  same-event listener writes in the same tick and assume it ran first —
  keep your own cursor. Field bug. *(runtime-semantic)*

## Minecraft 1.21.1 (NeoForge 21.1.x LTS)

Populate as new burns are discovered.

- **`Tier.getLevel()` does NOT exist in 1.21.1.** Compare a `Tier` by
  identity against the `Tiers` enum constants
  (`tier == Tiers.IRON`, etc.). There is no numeric level accessor; the
  enum-comparison pattern is canonical pre-26.

---

## How to add an entry

When a builder or researcher resolves an API change:

1. One bullet at the top of the relevant section, in the format
   `**Old.symbol → New.symbol.** One-line note.`
2. If the change is large (a whole subsystem refactor), link to a longer
   write-up in the relevant `docs/workflow-runs/NNN-slug/research.md` rather
   than inlining the explanation.
3. If the rename has cross-cutting impact (touches >5 call sites), also add
   to the host project's `CLAUDE.md` "Active landmines" section. This file
   is the cross-run index; CLAUDE.md is the per-project rule sheet.
4. **Multi-loader landmines** (toolchain, gradle, manifest, mixin/AT/AW)
   go in the "Multi-loader landmines" section at the top, not the
   per-MC-version sections.
