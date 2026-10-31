#!/usr/bin/env python3
"""palette-extract.py — vanilla block-texture palettes from the Minecraft client jar.

Reads block textures straight out of the (already downloaded) client jar in
the Gradle cache, groups them by material family, and emits palette ramps
an agent can hand to a texture generator or to ImageMagick `-remap`.

Usage:
  palette-extract.py [--jar PATH] [--family GLOB ...] [--out DIR] [--top N]
                     [--list]

  --jar      Client jar. Default: the jar matching ./gradle.properties
             minecraft_version under ~/.gradle/caches/neoformruntime/artifacts/,
             else the newest one there.
  --family   One or more fnmatch globs over texture basenames (e.g. "stone*",
             "*cobble*", "oak_*"). Each glob becomes one family. Default:
             a starter set of common building materials.
  --out      Output dir. Default: ./palettes
  --top      Max colors kept per family ramp (default 8).
  --list     Print all block texture names in the jar and exit.

Outputs per family:
  <family>.png   a 1-row strip, one 8x8 swatch per color, darkest → lightest
  <family>.json  hex colors with luminance, sample counts, source textures
  <family>.gpl   GIMP/Aseprite palette
Plus palettes.json summarizing all families.

Only PIL is required. Colors are quantized to the family's dominant colors
by frequency (alpha < 128 ignored), then ordered by luminance so the ramp
reads midtone/shadow/highlight the way the Blockbench style guide wants.
"""
import argparse, fnmatch, glob, io, json, os, sys, zipfile
from collections import Counter

try:
    from PIL import Image
except ImportError:
    sys.exit("palette-extract: Pillow is required (pip install pillow)")

DEFAULT_FAMILIES = [
    "stone", "stone_bricks*", "cobblestone", "deepslate*", "andesite*",
    "diorite*", "granite*", "oak_planks", "oak_log*", "spruce_planks",
    "dark_oak_planks", "sandstone*", "bricks", "mud_bricks", "copper_block",
    "oxidized_copper", "iron_block", "gold_block", "moss_block", "grass_block*",
    "dirt", "gravel", "sand", "glass", "obsidian", "blackstone*",
]

def project_mc_version():
    """minecraft_version from ./gradle.properties, so the palette matches the
    project's own MC line rather than the newest jar in the cache."""
    try:
        with open("gradle.properties") as f:
            for line in f:
                if line.strip().startswith("minecraft_version="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return None

def newest_client_jar():
    pat = os.path.expanduser("~/.gradle/caches/neoformruntime/artifacts/minecraft_*_client.jar")
    jars = glob.glob(pat)
    if not jars:
        sys.exit("palette-extract: no client jar found; pass --jar")
    want = project_mc_version()
    if want:
        for j in jars:
            if os.path.basename(j) == f"minecraft_{want}_client.jar":
                return j
        print(f"palette-extract: no cached jar for project MC {want}; using newest", file=sys.stderr)
    def key(p):
        v = os.path.basename(p).split("_")[1]
        return tuple(int(x) if x.isdigit() else 0 for x in v.split("."))
    return max(jars, key=key)

def luminance(rgb):
    r, g, b = rgb
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def hexc(rgb):
    return "#%02x%02x%02x" % rgb

def quantize(counter, top):
    """Greedy merge of near-identical colors (distance < 12) by frequency."""
    kept = []
    for rgb, n in counter.most_common():
        for k in kept:
            if sum((a - b) ** 2 for a, b in zip(rgb, k["rgb"])) < 12 ** 2:
                k["count"] += n
                break
        else:
            kept.append({"rgb": rgb, "count": n})
        if len(kept) >= top * 3:
            break
    kept.sort(key=lambda k: -k["count"])
    kept = kept[:top]
    kept.sort(key=lambda k: luminance(k["rgb"]))
    return kept

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jar")
    ap.add_argument("--family", action="append")
    ap.add_argument("--out", default="palettes")
    ap.add_argument("--top", type=int, default=8)
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()

    jar = a.jar or newest_client_jar()
    prefix = "assets/minecraft/textures/block/"
    with zipfile.ZipFile(jar) as z:
        names = sorted(n for n in z.namelist() if n.startswith(prefix) and n.endswith(".png"))
        bases = [os.path.basename(n)[:-4] for n in names]
        if a.list:
            print("\n".join(bases)); return
        families = a.family or DEFAULT_FAMILIES
        os.makedirs(a.out, exist_ok=True)
        summary = {"jar": jar, "families": {}}
        for fam in families:
            matched = [n for n, b in zip(names, bases) if fnmatch.fnmatch(b, fam)]
            if not matched:
                print(f"  (no textures match {fam})", file=sys.stderr); continue
            counter = Counter()
            for n in matched:
                img = Image.open(io.BytesIO(z.read(n))).convert("RGBA")
                px = img.load()
                w, h = img.size
                for y in range(h):
                    for x in range(w):
                        r, g, b, al = px[x, y]
                        if al >= 128:
                            counter[(r, g, b)] += 1
            ramp = quantize(counter, a.top)
            slug = fam.replace("*", "").replace("?", "").strip("_") or "all"
            # strip PNG
            strip = Image.new("RGBA", (8 * len(ramp), 8), (0, 0, 0, 0))
            for i, k in enumerate(ramp):
                strip.paste(Image.new("RGBA", (8, 8), k["rgb"] + (255,)), (8 * i, 0))
            strip.save(os.path.join(a.out, f"{slug}.png"))
            # gpl
            with open(os.path.join(a.out, f"{slug}.gpl"), "w") as f:
                f.write(f"GIMP Palette\nName: {slug}\nColumns: {len(ramp)}\n#\n")
                for k in ramp:
                    f.write("%3d %3d %3d\t%s\n" % (*k["rgb"], hexc(k["rgb"])))
            entry = {
                "glob": fam,
                "textures": [os.path.basename(n) for n in matched],
                "ramp": [{"hex": hexc(k["rgb"]), "rgb": list(k["rgb"]),
                          "luminance": round(luminance(k["rgb"]), 1),
                          "count": k["count"]} for k in ramp],
            }
            with open(os.path.join(a.out, f"{slug}.json"), "w") as f:
                json.dump(entry, f, indent=2)
            summary["families"][slug] = entry
            print(f"{slug:18} {len(matched):2} textures  " + " ".join(k["hex"] for k in entry["ramp"]))
        with open(os.path.join(a.out, "palettes.json"), "w") as f:
            json.dump(summary, f, indent=2)
        print(f"\nwrote {len(summary['families'])} families to {a.out}/ (from {os.path.basename(jar)})")

if __name__ == "__main__":
    main()
