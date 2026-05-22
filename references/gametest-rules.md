# Gametest reliability rules

These rules exist because Minecraft gametests have a sharp edge: they
look like JUnit but run inside a live MC server tick loop, with timing
races, world-state pollution, RNG, and JVM warmup all conspiring to make
naive tests flaky. modsmith bakes these rules into the
`gametest-author` agent's system prompt and `/modsmith:doctor` checks
the structural ones.

The goal is twofold: **not flaky** (a passing test stays passing) and
**catches intent** (a passing test actually exercised the behavior the
planner asked for, not a tautology).

## Rule 1: Always assert via `succeedWhen` / `succeedIf` with timeout

The single most common gametest bug: assert at a fixed tick (e.g. tick
20) and hope the world is ready by then. If the chunk loads slowly,
the entity hasn't ticked, the structure hasn't fully populated — the
assertion fires too early and the test flakes.

**Right:**

```java
@GameTest(templateNamespace = "mymod", template = "shopkeeper_discount")
public static void heroTagAppliesDiscount(GameTestHelper helper) {
    // /spec: hero-tagged player gets a discount from the shopkeeper.
    BlockPos shopPos = new BlockPos(2, 2, 2);
    helper.setBlock(shopPos, ModBlocks.SHOPKEEPER_DESK.get());

    Player player = helper.makeMockPlayer();
    player.addTag("hero");

    helper.useBlock(shopPos, player);

    helper.succeedWhen(() -> {
        // Re-evaluated every tick until true or timeout (default 200 ticks = 10s)
        ItemStack receipt = player.getMainHandItem();
        helper.assertTrue(
            receipt.getOrDefault(ModDataComponents.DISCOUNT_PCT, 0) >= 10,
            "discount component should be >= 10"
        );
    });
}
```

**Wrong:**

```java
@GameTest(templateNamespace = "mymod", template = "shopkeeper_discount")
public static void heroTagAppliesDiscount_FLAKY(GameTestHelper helper) {
    helper.setBlock(new BlockPos(2, 2, 2), ModBlocks.SHOPKEEPER_DESK.get());
    Player player = helper.makeMockPlayer();
    player.addTag("hero");
    helper.useBlock(new BlockPos(2, 2, 2), player);

    // BAD: fixed-tick assertion. If the interaction doesn't resolve by
    // tick 5, the test fails for a timing reason, not a logic reason.
    helper.runAtTickTime(5, () -> {
        helper.assertTrue(
            player.getMainHandItem().getOrDefault(ModDataComponents.DISCOUNT_PCT, 0) >= 10,
            "discount component should be >= 10"
        );
    });
}
```

`runAtTickTime` is fine for **actions** ("at tick 5, right-click the
block"), but never for **assertions**. The general shape is:

1. Setup (synchronous, before any `runAtTickTime`)
2. Optional scheduled actions via `runAtTickTime` / `runAfterDelay`
3. One `succeedWhen(...)` or `succeedIf(...)` block with the actual checks

Timeout defaults to 200 ticks (10 seconds). To override:
`helper.succeedOnTickWhen(400, () -> { ... })`. Pick a generous
timeout — a fast test is one that succeeds on tick 3, not one that
fails on tick 6.

## Rule 2: Each test in its own structure

Sharing a single `.nbt` template across multiple tests means each test
inherits whatever the previous one mutated. Even with `helper.killAllEntities()`
between, block states and tile entities leak.

**Always**: one `.nbt` per `@GameTest`. modsmith convention:
`data/<modid>/gametest/structures/<test_method_name>.nbt`. Reference
from the annotation as `template = "<test_method_name>"` —
gametest-author should emit them in lock-step.

Verify the structure is empty / matches expectations at the start using
an `onlyWhenEmpty`-style precondition check before the first action:

```java
@GameTest(templateNamespace = "mymod", template = "shopkeeper_discount")
public static void heroTagAppliesDiscount(GameTestHelper helper) {
    helper.assertBlockNotPresent(ModBlocks.SHOPKEEPER_DESK.get(), new BlockPos(2, 2, 2));
    // ... rest of the test
}
```

If two tests genuinely need the same structure (true duplication, not
"close enough"), they can share the `.nbt` — but document the dependency
in a `// shared with: <test_name>` comment so the next gametest-author
run knows the relationship.

## Rule 3: Tick-delay any post-spawn assertion

Entities don't finish initializing in the tick they're spawned. AI
goals, attribute modifiers, data components, and equipment all settle
1–2 ticks later. Asserting properties of a freshly-spawned entity in
the same tick **silently fails** because the field you're reading
hasn't been populated yet.

**Right:**

```java
public static void freshCowHasWeightComponent(GameTestHelper helper) {
    Cow cow = helper.spawnWithNoFreeWill(EntityType.COW, new BlockPos(2, 2, 2));

    helper.runAfterDelay(2, () -> {
        helper.assertTrue(
            cow.getData(ModData.WEIGHT_KG).isPresent(),
            "cow should have a weight component after init"
        );
        helper.succeed();
    });
}
```

**Wrong:**

```java
public static void freshCowHasWeightComponent_FLAKY(GameTestHelper helper) {
    Cow cow = helper.spawnWithNoFreeWill(EntityType.COW, new BlockPos(2, 2, 2));
    // BAD: read in the same tick the entity spawned in
    helper.assertTrue(cow.getData(ModData.WEIGHT_KG).isPresent(), "...");
    helper.succeed();
}
```

`helper.runAfterDelay(2, ...)` followed by `helper.succeed()` is the
shortest reliable pattern. For longer settle times (e.g. complex AI
behavior), `helper.succeedWhen(...)` from Rule 1 is preferred — it
will retry every tick until the assertion holds.

## Rule 4: RNG via `SeededHelpers`

`helper.getLevel().random` is server-shared and changes between runs.
Any test that gates on RNG (loot tables, mob behavior, growth, drops)
will be flaky if it samples that directly.

modsmith ships `com.example.gametest.SeededHelpers` (in the gametest
common module) which exposes:

```java
public final class SeededHelpers {
    /** Returns a fresh RandomSource seeded with the test's name. Deterministic per test. */
    public static RandomSource forTest(GameTestHelper helper);

    /** Variant for sharing a seed across an explicit string label. */
    public static RandomSource forLabel(String label);

    /** Swap the level's random with a seeded one for the duration of the test. */
    public static AutoCloseable pinLevelRandom(GameTestHelper helper, long seed);
}
```

Use `forTest(helper)` for any draw the test itself does; use
`pinLevelRandom(helper, seed)` when the behavior under test reads
from `level.random` internally (loot tables, mob AI, etc.).

```java
public static void heroDropsRareItem(GameTestHelper helper) {
    try (var ignored = SeededHelpers.pinLevelRandom(helper, 0xC0FFEEL)) {
        Zombie zombie = helper.spawnWithNoFreeWill(EntityType.ZOMBIE, new BlockPos(2, 2, 2));
        zombie.hurt(helper.getLevel().damageSources().generic(), Float.MAX_VALUE);

        helper.succeedWhen(() -> {
            // With the seed pinned, the drop is deterministic
            List<ItemEntity> drops = helper.getEntities(new BlockPos(2, 2, 2), 3.0, EntityType.ITEM);
            helper.assertTrue(
                drops.stream().anyMatch(e -> e.getItem().is(ModItems.HERO_EMBLEM.get())),
                "hero emblem should drop with seed 0xC0FFEE"
            );
        });
    }
}
```

If a test must NOT be seeded (e.g. it's testing distribution-of-drops
over many rolls), make that explicit with a comment, and assert on
distribution properties, not exact outcomes.

## Rule 5: `@spec` JavaDoc anchor

Every gametest carries a one-line `@spec` JavaDoc tag quoting the
planner's intent. The reviewer agent cross-references this against the
assertions in the test body — if the asserts don't actually exercise
what `@spec` says, that's a reviewer kick-back.

```java
/**
 * @spec Hero-tagged players receive a 10% discount on shopkeeper trades.
 */
@GameTest(templateNamespace = "mymod", template = "hero_discount")
public static void heroTagAppliesDiscount(GameTestHelper helper) {
    // ...
}
```

`@spec` content comes from the architect's feature decomposition; the
gametest-author copies the relevant intent into each test verbatim.
Phrase it as a single declarative sentence — what the player should be
able to do, observed externally. Not "calls X" or "method Y returns Z"
— that's an implementation detail, not an intent.

## Rule 6: Positive + negative pair per work unit

A gametest that always returns the same result (no matter the input)
passes a positive-only assertion vacuously. To catch this class of bug,
every work unit ships **a matched positive/negative pair**.

Example: "hero-tagged player gets a discount" needs **both**:

```java
/** @spec Hero-tagged players receive a 10% discount on shopkeeper trades. */
public static void heroTagAppliesDiscount(GameTestHelper helper) {
    Player player = helper.makeMockPlayer();
    player.addTag("hero");
    // ... assert discount applied
}

/** @spec Players without the hero tag receive no discount on shopkeeper trades. */
public static void noTagNoDiscount(GameTestHelper helper) {
    Player player = helper.makeMockPlayer();
    // no hero tag
    // ... assert discount NOT applied (and is the default/full price)
}
```

If the discount code is broken in a way that always applies the
discount, the positive test still passes but the negative one fails.
If the code never applies the discount, the negative passes but the
positive fails. Only correct code passes both.

The reviewer agent flags any work unit that has a positive test
without a matching negative (or vice versa) as incomplete coverage.

## Rule 7: Warmup pass

The first gametest run after a build is paying for JVM cold-start. The
MC server bootstrap takes ~5–10s of JIT warmup; tests that run during
this window have unpredictable tick costs and can falsely time out.

`scripts/run-gametest.sh --warmup` runs the gametest suite **once**
with results discarded, then runs it again with real result capture.
Only the second pass counts.

modsmith's CI config and the dev-loop scripts both pass `--warmup` by
default. The only place you'd skip it is a fast local debug iteration
where you've already warmed the JVM. **Never report a "flake" without
having run with `--warmup`.**

## Sub-rules / corollaries

- **Template references must exist.** `/modsmith:doctor` validates that
  every `template = "X"` in a `@GameTest` annotation has a matching
  `data/<modid>/gametest/structures/X.nbt` file checked into the same
  commit. A missing template silently fails the test.
- **Don't use `Thread.sleep` or any wall-clock delay.** Always
  tick-based delays (`runAfterDelay`) or tick-bounded waits
  (`succeedWhen`). Wall-clock breaks under JVM pause / debugger.
- **Server-only by default.** Gametests run on the integrated server;
  asserting client-side state (rendering, GUI) needs a separate
  approach (scenario tests in modsmith terminology, not gametests).
- **Catch and re-throw with context.** When `helper.assertX` fails, the
  message should identify *which* test and *why* — assertion messages
  show up directly in the run report.

## See also

- `references/landmines.md` — for MC API quirks that bite gametest
  authors (entity rename burns, NBT roundtrip oddities, etc.).
- The vanilla `net.minecraft.gametest.framework` source — the
  `GameTestHelper` API surface is the canonical authority for
  available helpers.
