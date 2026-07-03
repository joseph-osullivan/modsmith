package com.example.examplemod.neoforge.platform;

import com.example.examplemod.platform.IPlatformHelper;
import net.neoforged.fml.ModList;
import net.neoforged.fml.loading.FMLLoader;

public final class NeoForgePlatformHelper implements IPlatformHelper {

    @Override
    public String getPlatformName() {
        return "NeoForge";
    }

    @Override
    public boolean isModLoaded(String modid) {
        return ModList.get().isLoaded(modid);
    }

    @Override
    public boolean isDevelopmentEnvironment() {

        // NeoForge 26.x FML: instance API via FMLLoader.getCurrent().
        return !FMLLoader.getCurrent().isProduction();


    }
}
