# Cross-run Minecraft API landmine index

Shared knowledge across `/mc-mod-develop` runs so a builder hitting a known
API rename doesn't grind on it. Every entry traces to a real burn.

**Read protocol:** when a builder hits a "cannot find symbol" / class-not-found
error in vendor MC code, grep this file by the missing symbol BEFORE spawning
a researcher. If it's listed, apply the fix; if not, escalate as usual and
*append the answer here* once resolved.

**Format:** one heading per affected MC version, one bullet per rename/removal.
Keep entries to ≤2 lines. Link the run that discovered it.

---

## Minecraft 26.1 (NeoForge 26.1.x)

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

- **Shield durability via `LivingEntity#hurtCurrentlyUsedShield` no longer
  reaches non-Player subclasses cleanly** — moved to the `BlocksAttacks`
  data component. Guard armor durability ships, shield drain is a known gap
  (see issue #19).

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

---

## How to add an entry

When a builder or researcher resolves an API change:

1. One bullet at the top of the relevant section, in the format
   `**Old.symbol → New.symbol.** One-line note. Discovered in run-NNN.`
2. If the change is large (a whole subsystem refactor), link to a longer
   write-up in the relevant `docs/workflow-runs/NNN-slug/research.md` rather
   than inlining the explanation.
3. If the rename has cross-cutting impact (touches >5 call sites), also add
   to the host project's `CLAUDE.md` "Active landmines" section. This file
   is the cross-run index; CLAUDE.md is the per-project rule sheet.
