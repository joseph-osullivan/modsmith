package com.example.examplemod.neoforge;

import com.example.examplemod.ModInit;
import net.neoforged.bus.api.IEventBus;
import net.neoforged.fml.common.Mod;

/**
 * NeoForge entry point. The {@code @Mod} annotation registers the class with
 * the NeoForge mod loader, which calls this constructor with the mod-event
 * bus when the mod is loaded.
 *
 * <p>Delegates to the loader-neutral {@link ModInit#init()} after capturing
 * the mod bus for any NeoForge-only event subscriptions.
 */
@Mod("examplemod")
public final class NeoForgeModInit {

    public NeoForgeModInit(IEventBus modEventBus) {
        // Register NeoForge-only listeners on `modEventBus` here as the mod grows.
        ModInit.init();
    }
}
