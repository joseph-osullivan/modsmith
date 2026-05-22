package com.example.examplemod.fabric.platform;

import com.example.examplemod.platform.IPlatformHelper;
import net.fabricmc.loader.api.FabricLoader;

public final class FabricPlatformHelper implements IPlatformHelper {

    @Override
    public String getPlatformName() {
        return "Fabric";
    }

    @Override
    public boolean isModLoaded(String modid) {
        return FabricLoader.getInstance().isModLoaded(modid);
    }

    @Override
    public boolean isDevelopmentEnvironment() {
        return FabricLoader.getInstance().isDevelopmentEnvironment();
    }
}
