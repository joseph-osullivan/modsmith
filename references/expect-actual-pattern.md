# The expect/actual pattern (Java ServiceLoader)

modsmith uses **`java.util.ServiceLoader`** as its expect/actual mechanism.
**It does NOT use Architectury's `@ExpectPlatform`.** Migrators from an
Architectury project must rewrite every `@ExpectPlatform` static method as
an interface method on a `common` interface with one impl per loader.

The pattern has four moving parts:

1. An **interface** in `common/.../platform/` (the "expect").
2. A **`Services` wrapper** in `common/.../platform/` that does the
   `ServiceLoader` lookup (single place to import `ServiceLoader`).
3. One **impl class** in each loader subproject (the "actual"s).
4. One line in `src/main/resources/META-INF/services/<FQN-of-interface>`
   per impl, naming the FQN of the impl class.

## Step-by-step example

### 1. Declare the interface in `common/`

```java
// common/src/main/java/com/example/mymod/platform/IPlatformHelper.java
package com.example.mymod.platform;

import java.nio.file.Path;

public interface IPlatformHelper {
    /** Name of the current loader, e.g. "fabric" or "neoforge". */
    String getPlatformName();

    /** True if a mod with the given id is loaded. */
    boolean isModLoaded(String modId);

    /** True when running in the dev environment (loom/MDG run config). */
    boolean isDevelopmentEnvironment();

    /** Game directory, e.g. `.minecraft/` or the MDG/Loom run dir. */
    Path getGameFolder();
}
```

### 2. The `Services` wrapper in `common/`

This is **the only place** in the codebase that imports `java.util.ServiceLoader`.
Every call site in `common` goes through `Services.load(...)`.

```java
// common/src/main/java/com/example/mymod/platform/Services.java
package com.example.mymod.platform;

import java.util.ServiceLoader;

public final class Services {
    private Services() {}

    /**
     * Loads the single registered impl of {@code service} via {@link ServiceLoader}.
     * <p>
     * Throws if no impl is registered for the current loader — usually a missing
     * {@code META-INF/services/<FQN>} file. The error wording is deliberately
     * loud because this is one of the most common modsmith mis-configurations.
     */
    public static <T> T load(Class<T> service) {
        return ServiceLoader.load(service)
            .findFirst()
            .orElseThrow(() -> new IllegalStateException(
                "No service registered for " + service.getName()
                + " — check META-INF/services/" + service.getName()
                + " exists and points to an impl class on the classpath."));
    }
}
```

### 3. Call site (in `common/`)

Anywhere in `common` that needs platform-specific behavior calls `Services.load(...)`.
Most projects cache the lookup once in a `public static final` field for cheap reuse.

```java
// common/src/main/java/com/example/mymod/PlatformAccess.java
package com.example.mymod;

import com.example.mymod.platform.IPlatformHelper;
import com.example.mymod.platform.Services;

public final class PlatformAccess {
    public static final IPlatformHelper PLATFORM = Services.load(IPlatformHelper.class);
    private PlatformAccess() {}
}

// Usage:
// if (PlatformAccess.PLATFORM.isModLoaded("trinkets")) { ... }
```

### 4. The Fabric impl

```java
// fabric/src/main/java/com/example/mymod/fabric/platform/FabricPlatformHelper.java
package com.example.mymod.fabric.platform;

import com.example.mymod.platform.IPlatformHelper;
import net.fabricmc.loader.api.FabricLoader;

import java.nio.file.Path;

public final class FabricPlatformHelper implements IPlatformHelper {
    @Override public String getPlatformName() { return "fabric"; }

    @Override
    public boolean isModLoaded(String modId) {
        return FabricLoader.getInstance().isModLoaded(modId);
    }

    @Override
    public boolean isDevelopmentEnvironment() {
        return FabricLoader.getInstance().isDevelopmentEnvironment();
    }

    @Override
    public Path getGameFolder() {
        return FabricLoader.getInstance().getGameDir();
    }
}
```

### 5. The NeoForge impl

```java
// neoforge/src/main/java/com/example/mymod/neoforge/platform/NeoForgePlatformHelper.java
package com.example.mymod.neoforge.platform;

import com.example.mymod.platform.IPlatformHelper;
import net.neoforged.fml.ModList;
import net.neoforged.fml.loading.FMLLoader;
import net.neoforged.fml.loading.FMLPaths;

import java.nio.file.Path;

public final class NeoForgePlatformHelper implements IPlatformHelper {
    @Override public String getPlatformName() { return "neoforge"; }

    @Override
    public boolean isModLoaded(String modId) {
        return ModList.get() != null && ModList.get().isLoaded(modId);
    }

    @Override
    public boolean isDevelopmentEnvironment() {
        return !FMLLoader.isProduction();
    }

    @Override
    public Path getGameFolder() {
        return FMLPaths.GAMEDIR.get();
    }
}
```

### 6. The service registrations

Each impl needs **one** plain-text file under `META-INF/services/` whose
name is the **FQN of the interface** and whose body is **one line: the
FQN of the impl class** (no extra whitespace, no trailing comment).

```
# fabric/src/main/resources/META-INF/services/com.example.mymod.platform.IPlatformHelper
com.example.mymod.fabric.platform.FabricPlatformHelper
```

```
# neoforge/src/main/resources/META-INF/services/com.example.mymod.platform.IPlatformHelper
com.example.mymod.neoforge.platform.NeoForgePlatformHelper
```

**File naming gotchas:**

- The file name is the **FQN of the interface**, including dots — the directory is
  `META-INF/services/` and the file itself is literally
  `com.example.mymod.platform.IPlatformHelper` (no extension).
- One file **per interface**, not per impl. If you have three interfaces, you have
  three files in each loader subproject.
- Multiple impls per interface (e.g. for chained handlers) **are** legal —
  one impl FQN per line. modsmith convention is one impl per interface;
  `Services.load(...).findFirst()` only returns the first registration.

## When to use this pattern

**Use it every time a feature touches a loader-specific API.** Examples:

| Need | Common interface | Fabric impl uses | NeoForge impl uses |
| --- | --- | --- | --- |
| Mod-loaded check | `IPlatformHelper.isModLoaded` | `FabricLoader.isModLoaded` | `ModList.get().isLoaded` |
| Deferred register | `IRegistryHelper.register(BLOCK, ...)` | `Registry.register(BuiltInRegistries.BLOCK, ...)` | `DeferredRegister<Block>` |
| Network packet send | `INetworkHelper.sendToPlayer` | `ServerPlayNetworking.send` | `PacketDistributor.sendToPlayer` |
| Lifecycle event | `ILifecycleHooks.onServerStarted` | `ServerLifecycleEvents.SERVER_STARTED` | `@SubscribeEvent ServerStartedEvent` |
| Game folder path | `IPlatformHelper.getGameFolder` | `FabricLoader.getGameDir` | `FMLPaths.GAMEDIR.get` |

**Do NOT use this pattern for** vanilla Minecraft APIs (those go straight
in `common/` with no abstraction) or for features that are intrinsically
single-loader (put them in that loader's subproject only and don't add a
`common` interface).

## Why ServiceLoader and not @ExpectPlatform

- `@ExpectPlatform` is part of Architectury, which adds a third version axis
  to the build (Architectury × loader × MC). modsmith intentionally avoids
  that axis.
- `ServiceLoader` is `java.util`. Nothing to import, nothing to update,
  nothing to pin. The compiler enforces the contract at the interface
  level; `Services.load` enforces the registration at runtime.
- `/modsmith:doctor` can verify the pattern structurally: every interface
  in `common/.../platform/` must have an impl class in each loader
  subproject, and every impl must be referenced from a
  `META-INF/services/` file. None of that is possible with `@ExpectPlatform`.

## Migrating from `@ExpectPlatform`

For each `@ExpectPlatform` method like:

```java
// OLD (Architectury) — DOES NOT WORK in modsmith
public class PlatformHelper {
    @ExpectPlatform
    public static boolean isModLoaded(String modId) {
        throw new AssertionError();
    }
}
```

Convert to:

1. An interface method `boolean isModLoaded(String modId)` on
   `IPlatformHelper` in `common/.../platform/`.
2. An impl method on each loader's `*PlatformHelper` class.
3. A registration line in each loader's `META-INF/services/` file.
4. Call sites change from `PlatformHelper.isModLoaded(...)` to
   `Services.load(IPlatformHelper.class).isModLoaded(...)` (or the cached
   `PLATFORM.isModLoaded(...)` via a holder class).

There is no shortcut. `@ExpectPlatform` is a different mechanism and the
migration is mechanical-but-not-automatic.
