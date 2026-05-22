package com.example.examplemod.platform;

import java.util.ServiceLoader;

/**
 * Static accessors for ServiceLoader-resolved loader-neutral services.
 *
 * <p>Each loader subproject ships a {@code META-INF/services/} file naming
 * its concrete implementation; {@link #load} resolves the impl at first
 * touch. If no impl is registered (e.g. a service file was forgotten),
 * {@link #load} throws so the error surfaces immediately rather than at
 * the first call site.
 *
 * <p>For new platform services: add the interface under
 * {@code com.example.examplemod.platform}, add impls to both loader subprojects,
 * register impls in each loader's {@code META-INF/services/} directory,
 * then expose a static field on this class:
 * <pre>
 *   public static final IRegistryHelper REGISTRY = load(IRegistryHelper.class);
 * </pre>
 */
public final class Services {

    private Services() {}

    public static final IPlatformHelper PLATFORM = load(IPlatformHelper.class);

    /**
     * Resolve a single implementation of {@code cls} via {@link ServiceLoader}.
     *
     * @throws IllegalStateException if no implementation is registered
     */
    public static <T> T load(Class<T> cls) {
        return ServiceLoader.load(cls, Services.class.getClassLoader())
                .findFirst()
                .orElseThrow(() -> new IllegalStateException(
                        "No ServiceLoader implementation registered for " + cls.getName()
                                + ". Did you forget to add it to META-INF/services/"
                                + cls.getName() + " in the loader subproject?"));
    }
}
