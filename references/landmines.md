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

### `modImplementation` vs `implementation` in Fabric Loom

- **In Fabric Loom, mod dependencies MUST use `modImplementation`
  (not `implementation`).** `implementation` includes the JAR on the
  classpath but does NOT run it through Loom's remapper. In dev it
  appears to work; at runtime in a production JAR the remapped names
  don't resolve and you get `ClassNotFoundException` / `NoSuchMethodError`.
- This applies to ALL Fabric API modules, Fabric Loader, and any other
  mod jar (e.g. Trinkets, Cloth Config).
- `/modsmith:doctor` greps loader subproject build files and hard-fails on
  raw `implementation 'net.fabricmc:fabric-api'` or `implementation
  'net.neoforged:neoforge'`.
- NeoForge under MDG uses regular `implementation`/`runtimeOnly` —
  ModDevGradle handles the userdev transform at the plugin level, not the
  dependency configuration level. The rule here is **Fabric only**.

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
  the toolchain if not present. Users should not be running mismatched
  JDKs locally — Gradle picks the toolchain regardless of
  `JAVA_HOME`.
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

- **`CompoundTag.getCompound(String)` returns `Optional<CompoundTag>` in
  26.1.** Use `getCompoundOrEmpty` for the old always-a-tag behavior.
  Probe-verified 2026-07.

- **`getOrThrow` inside `Optional.map` throws PAST a downstream
  `.orElse(null)`.** A missing registry entry crashes every call site
  despite the null-default. Use `flatMap(reg -> reg.get(key))` chains
  that stay in Optional-land. Probe-verified 2026-07. *(runtime-semantic)*

- **`LivingDeathEvent` is cancellable in 26.1** and fires post-mitigation,
  AFTER vanilla's in-hand totem check — the correct hook for totem-like
  death prevention (cancel + `setHealth`). `LivingIncomingDamageEvent`
  fires PRE-armor; lethality math there overcounts. Probe + field bug,
  2026-07. *(runtime-semantic)*

- **`Player.PERSISTED_NBT_TAG` ("PlayerPersisted") is clone-copied by the
  patched `ServerPlayer.restoreFrom`** — the supported place to stash data
  that must survive death. Verified in 26.1.2 bytecode. If you both write
  it on death and read-clear it on clone, clear BOTH sides or you get
  dupes.

- **`RegistryOps` come from
  `registryAccess().createSerializationContext(NbtOps.INSTANCE)`** in
  26.1 — not from a static `RegistryOps.create` recipe you may remember.
  Probe-verified 2026-07.

- **`MinecraftServer#getProfileCache()` is gone in 26.1.** Online players:
  `getPlayerList().getPlayer(uuid)`; offline: keep your own persisted
  name map — there is no vanilla offline cache accessor anymore.

- **`GameTestHelper.makeMockPlayer(GameType)` returns `Player`, NOT
  `ServerPlayer`** — don't cast; use a real connected fake player helper
  when server-player-only surfaces are needed. Probe-verified 2026-07.

- **GameTest batching is keyed on the test_environment holder** —
  distinct `data/<ns>/test_environment/<name>.json` = a sequential, solo
  batch (≤50 tests per batch otherwise). This is the isolation primitive
  for tests contesting global state — and an anti-pattern for cold-start
  (see `references/gametest-rules.md`). Decompile-verified.

- **The GameTest framework NEVER clears finished tests' entities or
  structures** — the arena accumulates across the whole server run;
  batch grids pack cells within ~12–40 blocks; vanilla `AcquirePoi`
  scans to 48 blocks. See the arena-isolation rules in
  `references/gametest-rules.md`. Field bug, root-caused 2026-07.
  *(runtime-semantic)*

- **GameTest run totals include vanilla `always_pass`** — reported count
  is your test count +1; derived-count assertions must use `≥`, not
  `==`. Corollary: GameTestServer exits 0 printing "All 0 required tests
  passed" when discovery silently breaks — pair discovery/source-set
  changes with a tests-run ≥ manifest-count assert. *(runtime-semantic)*

- **NeoForge 26.1 GLMs have NO `global_loot_modifiers.json` index.** The
  loot-modifier manager auto-discovers each modifier from its own JSON
  under `data/<ns>/loot_modifiers/`. Shipping the old index file makes
  26.1 try to parse it as a modifier and reject it, which can block ALL
  modifiers from loading. Field bug.

- **`Mob#setNoAi(true)` does NOT gate `aiStep()`** — noAi gates the
  brain/goal tick, but `aiStep`/`customServerAiStep` logic still runs
  (e.g. shield-lowering). Stage test entities via the production path
  instead of assuming noAi freezes them. Field bug, 2026-07.
  *(runtime-semantic)*

- **Two listeners on the same NeoForge event have NO defined relative
  order** unless explicit priorities are set. Never read state another
  same-event listener writes in the same tick and assume it ran first —
  keep your own cursor. Field bug. *(runtime-semantic)*

- **`finalizeSpawn` does NOT run on `addFreshEntity`** — mobs spawn
  without their equipment/AI init. Trigger the production spawn path or
  call the init explicitly. Field bug. *(runtime-semantic)*

- **`Container#slotsChanged` never fires for `ItemStackHandler`-backed
  slots** — capability-based inventories bypass it. Field bug.
  *(runtime-semantic)*

- **`ServerLevel.sendParticles` (7-arg) silently drops particles beyond
  ~32 blocks of each player** unless the overrideLimiter arg is set.
  Field bug. *(runtime-semantic)*

- **Vanilla brain activities (e.g. REST) override `goalSelector` goals on
  Villager subclasses** — a goal that compiles but won't run. Field bug.
  *(runtime-semantic)*

- **`findNearestMapStructure` returns y=0 positions and takes a
  CHUNKS-denominated radius**; `getHeight` on unloaded chunks returns
  `minBuildHeight`. Field bug (three stacked). *(runtime-semantic)*

- **`/time add N` interprets `N` as DAYS, not ticks in 26.1.** `/time add 24000`
  jumps ~24,000 MC days (576M ticks), not one day. Use `/time set N` (still
  ticks) or `/time add 1d`-style syntax if you want a day-grained jump. Day-tick
  handlers that gate on `getOverworldClockTime() % 24000 == 0` will silently
  miss any time-jump that overshoots the boundary — trigger on day-index
  *change* (`current/24000 != last/24000`) instead.

- **`@EventBusSubscriber(value = Dist.DEDICATED_SERVER)` silently breaks
  single-player.** In SP the integrated server runs inside the client
  (`Dist.CLIENT`), so DEDICATED_SERVER-restricted handlers never register.
  `runGameTestServer` is a real dedicated server so tests pass while the
  mod is inert in `runClient`. Don't use a `Dist` value on server-side
  handlers — register on all dists and gate work with runtime
  `isClientSide()` / `instanceof ServerLevel` checks.

- **`MushroomCow` is NOT a subclass of `Cow` in 26.1.** Both extend the new
  `net.minecraft.world.entity.animal.cow.AbstractCow`. Pre-26.1 the Mooshroom
  was `MushroomCow extends Cow`; now they are siblings under `AbstractCow`.
  Species checks that want "all bovines including Mooshroom" must use
  `instanceof AbstractCow`. `MushroomCow` itself lives at
  `net.minecraft.world.entity.animal.cow.MushroomCow`. `Rabbit` lives at
  `net.minecraft.world.entity.animal.rabbit.Rabbit` (same 26.1 subpackage
  reshuffle).

- **`Level#getDayTime()` is gone.** Replaced by `Level#getOverworldClockTime()`
  (returns the canonical overworld clock in ticks regardless of dimension)
  and `Level#getDefaultClockTime()`. Backed by the new
  `net.minecraft.world.clock.ClockManager` / `WorldClock` subsystem in
  MC 26.1.2. Use `getOverworldClockTime() % 24000L == 0L` for dawn boundary
  detection.

- **`Cow`, `Pig`, `Sheep`, `Chicken` moved into species subpackages.**
  `net.minecraft.world.entity.animal.{Cow,Pig,Sheep,Chicken}` →
  `animal.cow.Cow`, `animal.pig.Pig`, `animal.sheep.Sheep`,
  `animal.chicken.Chicken`. `Animal` base class stays at
  `world.entity.animal.Animal`. Same 26.1 reshuffle that moved
  `Zombie → monster.zombie.Zombie`.

- **`Entity#moveTo(...)` → `Entity#snapTo(...)`** (all overloads). Also gained
  `absSnapTo(...)` for absolute positioning. The earlier "decompiled-with-NeoForge"
  cache jar still shows `moveTo` (it's pre-mapping), but the actual compileClasspath
  uses the client/server jar where it's `snapTo`.

- **`MobEffects` vocabulary rename in MC 26.1.** `MOVEMENT_SLOWDOWN → SLOWNESS`,
  `MOVEMENT_SPEED → SPEED`, `DIG_SLOWDOWN → MINING_FATIGUE`, `JUMP → JUMP_BOOST`,
  `CONFUSION → NAUSEA`, `DAMAGE_BOOST → STRENGTH`, `DAMAGE_RESISTANCE → RESISTANCE`.

- **`@GameTestHolder` / `@PrefixGameTestTemplate` annotation-based GameTest
  discovery is gone from the main compileClasspath.** The annotations exist
  in the userdev jar but are not exported to consuming mods. Use the
  `DeferredRegister<TestFunction>` + `data/<modid>/test_instance/<name>.json`
  pattern instead.

- **`ServerLevel#getSharedSpawnPos()` → `getLevelData().getRespawnData().pos()`.**
  `RespawnData` is a new top-level record bundling pos + angle + dim.

- **`BlockEvent.BreakEvent` → `BreakBlockEvent`.** Top-level event, not nested
  under BlockEvent anymore.

- **`Tier`, `ArmorItem`, `SwordItem`, `TieredItem` deleted.** If the mod
  classifies gear by tier, it needs its own registry-key map (or
  data-component-based generalization); modded gear absent from the map
  won't be recognized by tier checks.

- **`LivingEntity#hurtCurrentlyUsedShield` is REMOVED in 26.1.** Blocking
  runs through the `blocks_attacks` data component +
  `LivingEntity#applyItemBlocking` (component `item_damage`, default 1.5).
  Note the NeoForge patch gates the durability-drain path behind
  `instanceof Player` — non-player entities don't drain shields, and
  `LivingShieldBlockEvent.setShieldDamage` is consumed inside that gate
  (a no-op for mobs). Verified against patched 26.1.2 sources.

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
  cancellable = true)` and `cir.setReturnValue(tint)`.

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

- **NeoForge 26.1 ships Mixin natively — no `build.gradle` plugin block
  required.** Drop a mixins JSON into `src/main/resources/`, reference
  it from `META-INF/neoforge.mods.toml` with `[[mixins]] config =
  "yourmod.mixins.json"`, and the ModDevGradle 2 build picks it up. No
  `apply plugin: 'org.spongepowered.mixin'`, no `mixin { config ... }`
  block, no Loom-style configuration. The mixin compatibility level
  (`JAVA_25` etc.) is a string constant on
  `MixinEnvironment.CompatibilityLevel` — confirm a value is valid by
  `javap`-ing the bundled `sponge-mixin-*.jar` in the NeoForge cache if
  uncertain.

- **`Entity#getTags()` → `Entity#entityTags()`.** Returns the same
  `Set<String>`. `addTag(String)` / `removeTag(String)` /
  `hasTag(String)` are unchanged.

- **`Component.Serializer` (the inner class on `Component`) is gone.**
  Replaced by `net.minecraft.network.chat.ComponentSerialization`. To
  encode a `Component` to NBT or JSON in 26.1, use
  `ComponentSerialization.CODEC.encodeStart(NbtOps.INSTANCE,
  component).getOrThrow(...)` → `Tag`.

- **`Entity#load(CompoundTag)` → `Entity#load(ValueInput)`.** The
  `ValueInput` / `ValueOutput` interfaces (in
  `net.minecraft.world.level.storage`) wrap NBT for entity save/load.
  To call `load` from mod code with a hand-built `CompoundTag`, wrap
  via `TagValueInput.create(ProblemReporter.DISCARDING,
  entity.registryAccess(), tag)`. `Entity#saveAdditional` likewise
  takes `ValueOutput`.

- **`EntityType#create(Level)` → `EntityType#create(Level,
  EntitySpawnReason)`.** All four create overloads in 26.1 require an
  `EntitySpawnReason` enum (e.g. `EntitySpawnReason.LOAD`,
  `COMMAND`, `MOB_SUMMONED`). Was `MobSpawnType` pre-26.1. For
  mod-spawned utility entities (Display, etc.), `EntitySpawnReason.LOAD`
  is the most neutral choice — bypasses spawn-event side-effects.

- **`Display.TextDisplay#setText(Component)` is private in MC 26.1** —
  the field-setter you'd expect doesn't exist publicly. The canonical
  approach is the NBT roundtrip via `Entity#load(ValueInput)`: build a
  `CompoundTag` with key `"text"` whose value is the JSON-encoded
  Component (via `ComponentSerialization.CODEC`), wrap as `ValueInput`,
  call `display.load(valueInput)`. Vanilla's `readAdditionalSaveData`
  then routes the resolved text into the data-watcher slot.

- **`LandRandomPos.getPos(PathfinderMob, int, int)` returns
  `@Nullable Vec3`.** Standard random-pos sampling for ground animals;
  filters water destinations via `GoalUtils.isWater`. Use over
  `DefaultRandomPos` when the mob must land on solid ground.---

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
