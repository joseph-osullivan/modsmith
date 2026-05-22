package com.example.examplemod;

import com.example.examplemod.platform.Services;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Loader-neutral mod entry point. Both {@code FabricModInit} and
 * {@code NeoForgeModInit} call {@link #init()} after their own
 * loader-specific bootstrap completes.
 *
 * <p>Keep this method parameterless. Any loader-specific arguments
 * (e.g. NeoForge's {@code IEventBus}) must be handled in the loader
 * subproject's entrypoint and not leaked into common.
 */
public final class ModInit {

    public static final String MOD_ID   = "examplemod";
    public static final String MOD_NAME = "Example Mod";
    public static final Logger LOG      = LoggerFactory.getLogger(MOD_NAME);

    private ModInit() {}

    public static void init() {
        LOG.info("Example Mod v0.1.0 initialized on {}",
                Services.PLATFORM.getPlatformName());
    }
}
