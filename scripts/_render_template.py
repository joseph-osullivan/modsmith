#!/usr/bin/env python3
"""Render a single template file using the Mustache subset from _mustache.py.

Usage:
    _render_template.py <src> <dst> <vars.json> [<inner_context.json>]

The base context is `vars.json`. If `inner_context.json` is supplied, its
fields are merged on top (overlay) so per-MC × per-loader contexts can
override or add fields without mutating the global vars file.

`package_base_path`, `mc_version_range`, `neoforge_loader_version_range`,
`neoform_version`, `has_parchment`, `is_unobfuscated`,
`fml_has_getcurrent`, and `java_version_daemon` are derived if not
already present (so hand-written vars files that predate those keys still
render; the init skill's translator normally supplies them explicitly).

Exit codes:
  0 — rendered
  1 — error (file IO, JSON parse, etc.)
"""

from __future__ import annotations

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from _mustache import render_file  # noqa: E402


def _load_json(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _derive(ctx: dict) -> dict:
    if "package_base_path" not in ctx and ctx.get("package_base"):
        ctx["package_base_path"] = ctx["package_base"].replace(".", "/")
    mc = ctx.get("mc_version")
    if mc and "mc_version_range" not in ctx:
        ctx["mc_version_range"] = f"[{mc},)"
    if "neoforge_loader_version_range" not in ctx:
        ctx["neoforge_loader_version_range"] = "[4,)"
    if mc and not ctx.get("neoform_version"):
        # Fallback placeholder only — the resolver/translator normally
        # supplies the real revision from maven.neoforged.net.
        ctx["neoform_version"] = f"{mc}-1"
    if "has_parchment" not in ctx:
        ctx["has_parchment"] = bool(
            ctx.get("parchment_mc_version") and ctx.get("parchment_version")
        )
    if mc:
        try:
            mc_major = int(str(mc).split(".")[0])
        except ValueError:
            mc_major = 0
        # MC 26+ ships unobfuscated (drives the fabric Loom plugin-id /
        # mappings / dependency-form switch) and its NeoForge FML exposes
        # the FMLLoader.getCurrent() instance API.
        if "is_unobfuscated" not in ctx:
            ctx["is_unobfuscated"] = mc_major >= 26
        if "fml_has_getcurrent" not in ctx:
            ctx["fml_has_getcurrent"] = mc_major >= 26
    if "java_version_daemon" not in ctx:
        # The JVM that RUNS Gradle must satisfy the Loom/MDG plugin jars'
        # >= 21 runtime constraint, whatever the compile toolchains are.
        candidates: list[int] = []
        rows = ctx.get("mc_versions")
        if isinstance(rows, list):
            for row in rows:
                if isinstance(row, dict) and row.get("java_version"):
                    candidates.append(int(row["java_version"]))
        if ctx.get("java_version"):
            candidates.append(int(ctx["java_version"]))
        ctx["java_version_daemon"] = max([21, *candidates])
    return ctx


def main() -> int:
    if len(sys.argv) < 4:
        print(
            "usage: _render_template.py <src> <dst> <vars.json> [<inner.json>]",
            file=sys.stderr,
        )
        return 1

    src, dst, vars_path = sys.argv[1:4]
    inner_path = sys.argv[4] if len(sys.argv) >= 5 else None

    try:
        ctx = _load_json(vars_path)
    except Exception as e:
        print(f"could not load vars json {vars_path}: {e}", file=sys.stderr)
        return 1

    if inner_path:
        try:
            inner = _load_json(inner_path)
        except Exception as e:
            print(f"could not load inner json {inner_path}: {e}", file=sys.stderr)
            return 1
        ctx.update(inner)

    ctx = _derive(ctx)

    try:
        render_file(src, dst, ctx)
    except Exception as e:
        print(f"render failed for {src} -> {dst}: {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
