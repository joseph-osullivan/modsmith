#!/usr/bin/env python3
"""Translate `resolve-versions.sh` output into a `vars.json` for
`expand-templates.sh` — multi-MC (default) or single-MC (`--single-mc`).

The init skill calls this in BOTH scaffold modes:

- **multi-MC** (default): 2+ distinct MC versions resolved and the user
  opted for the multi-MC overlay scaffold. Produces the `mc_versions`-array
  schema.
- **single-MC** (`--single-mc [--mc-version <v>]`): exactly one MC row is
  kept (the first resolved row, or the row matching `--mc-version`).
  Produces the flat single-MC schema so the skill never has to hand-build
  the resolver→vars field mapping.

Input:
    - --resolver  Path to a JSON file holding the raw output of
                  `resolve-versions.sh` (i.e. an object with `resolved` +
                  `warnings`).
    - --identity  Path to a JSON file holding identity fields supplied by
                  the user: modid, mod_name, mod_version, package_base,
                  package_base_path, description, license, authors, and
                  the selected `loaders` array.
    - --out       Path to write the translated vars.json to.
    - --single-mc Emit the flat single-MC schema instead of the multi-MC
                  one.
    - --mc-version <v>
                  With --single-mc: which resolved MC row to keep
                  (default: the first row).

The schemas produced match what `expand-templates.sh` consumes. See
expand-templates.sh's header doc for the canonical schema definitions.

Per-MC translation rules:
    mc_suffix             = mc_version with '.' -> '_'
    java_version          = resolver row's java_toolchain
    neoforge_version      = loaders.neoforge.loader_version   (nullable)
    neoform_version       = resolver row's neoform_version when present,
                            else `{mc_version}-1` as a fallback placeholder.
                            The resolver queries
                            https://maven.neoforged.net/releases/net/neoforged/neoform/maven-metadata.xml
                            and picks the latest revision matching the MC
                            line. If the network call fails or no
                            matching revision exists, the fallback
                            placeholder is written and the user must
                            replace it before the per-MC :common build
                            succeeds.
    fabric_loader_version = loaders.fabric.loader_version
    fabric_api_version    = loaders.fabric.fabric_api_version
    parchment_mc_version  = parchment.mc                       (nullable)
    parchment_version     = parchment.version                  (nullable)
    has_fabric            = "fabric" in identity.loaders AND the resolver
                            row has a non-null fabric loader_version.
    has_neoforge          = "neoforge" in identity.loaders AND the resolver
                            row has a non-null neoforge loader_version.
    has_parchment         = parchment.mc / parchment.version are both
                            non-null on the row.
    is_unobfuscated       = MC major version >= 26. MC 26.x+ ships
                            unobfuscated: the fabric templates switch to
                            the new `net.fabricmc.fabric-loom` plugin id
                            (Loom no-remap mode), drop the mappings block,
                            and use plain `implementation` for mod deps.
    fml_has_getcurrent    = MC major version >= 26. NeoForge 26.x FML has
                            the instance API `FMLLoader.getCurrent()`;
                            21.x only has static `FMLLoader.isProduction()`.

Top-level (multi-MC only):
    java_version_shared   = MIN(per-MC java_version). Top-level :common's
                            bytecode is consumed by EVERY per-MC line, and
                            an older JVM cannot load newer bytecode (a
                            Java-21 line cannot consume Java-25 classes) —
                            so :common must compile at the lowest Java
                            among the targeted MC lines.
    primary_mc_version    = first row's mc_version. Written into
                            gradle.properties as `minecraft_version=` so
                            repo-detection tooling (which greps that key)
                            recognizes the scaffold.
    mc_versions           = ordered list of per-MC rows in resolver order.

Exit codes:
    0 — success
    1 — invalid input (missing fields, empty resolved array, etc.)
    2 — usage error
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _mc_suffix(mc_version: str) -> str:
    return mc_version.replace(".", "_")


def _mc_major(mc_version: str) -> int:
    try:
        return int(mc_version.split(".")[0])
    except (ValueError, IndexError):
        return 0


def _row_or_none(loaders: dict, name: str) -> dict | None:
    if not isinstance(loaders, dict):
        return None
    row = loaders.get(name)
    return row if isinstance(row, dict) else None


def _translate_row(resolver_row: dict, selected_loaders: list[str]) -> dict:
    mc_version = resolver_row.get("mc_version")
    if not mc_version:
        raise ValueError("resolver row missing mc_version")

    java_toolchain = resolver_row.get("java_toolchain")
    if java_toolchain is None:
        raise ValueError(f"resolver row for MC {mc_version} missing java_toolchain")

    loaders_obj = resolver_row.get("loaders") or {}
    fab = _row_or_none(loaders_obj, "fabric")
    neo = _row_or_none(loaders_obj, "neoforge")
    parch = resolver_row.get("parchment")
    if not isinstance(parch, dict):
        parch = None

    fab_loader_v = fab.get("loader_version") if fab else None
    fab_api_v = fab.get("fabric_api_version") if fab else None
    neo_loader_v = neo.get("loader_version") if neo else None

    has_fabric = ("fabric" in selected_loaders) and bool(fab_loader_v)
    has_neoforge = ("neoforge" in selected_loaders) and bool(neo_loader_v)
    has_parchment = bool(parch and parch.get("mc") and parch.get("version"))

    # MC 26+ ships unobfuscated; this drives the fabric template's Loom
    # plugin-id/mappings/dependency-form switch and the NeoForge template's
    # FMLLoader API selection.
    is_unobfuscated = _mc_major(mc_version) >= 26

    # NeoForm: prefer the resolver's resolved revision. If the resolver
    # couldn't reach maven.neoforged.net or no artifact matched the MC
    # line, fall back to a `<mc>-1` placeholder so the rendered
    # gradle.properties is structurally valid. The skill surfaces the
    # resolver's warning to the user when the fallback fires.
    neoform_v = resolver_row.get("neoform_version")
    neoform_is_placeholder = not bool(neoform_v)
    if neoform_is_placeholder:
        neoform_v = f"{mc_version}-1"
        print(
            f"warning: resolver did not return a NeoForm version for MC "
            f"{mc_version}; writing placeholder '{neoform_v}'. The "
            f"NeoForm-consuming :common build will fail until you replace "
            f"the neoform_version pin in gradle.properties with the real "
            f"revision from "
            f"https://maven.neoforged.net/releases/net/neoforged/neoform/",
            file=sys.stderr,
        )

    return {
        "mc_version": mc_version,
        "mc_suffix": _mc_suffix(mc_version),
        "java_version": int(java_toolchain),
        "neoforge_version": neo_loader_v,
        "neoform_version": neoform_v,
        "neoform_version_is_placeholder": neoform_is_placeholder,
        "fabric_loader_version": fab_loader_v,
        "fabric_api_version": fab_api_v,
        "parchment_mc_version": parch.get("mc") if parch else None,
        "parchment_version": parch.get("version") if parch else None,
        "has_fabric": has_fabric,
        "has_neoforge": has_neoforge,
        "has_parchment": has_parchment,
        "is_unobfuscated": is_unobfuscated,
        "fml_has_getcurrent": is_unobfuscated,
    }


def _identity_fields(identity: dict, selected_loaders: list[str]) -> dict:
    """Carry through identity fields verbatim; default package_base_path."""
    return {
        "modid": identity["modid"],
        "mod_name": identity.get("mod_name", identity["modid"]),
        "mod_version": identity.get("mod_version", "0.1.0"),
        "package_base": identity["package_base"],
        "package_base_path": identity.get(
            "package_base_path", identity["package_base"].replace(".", "/")
        ),
        "description": identity.get("description", ""),
        "license": identity.get("license", "MIT"),
        "authors": identity.get("authors", ""),
        "loaders": selected_loaders,
    }


def _dedupe_rows(resolved: list, selected_loaders: list[str]) -> list[dict]:
    """De-duplicate on mc_version while preserving order (so passing
    `latest,latest` only yields one row)."""
    seen: set[str] = set()
    mc_rows: list[dict] = []
    for row in resolved:
        if not isinstance(row, dict):
            continue
        mc_v = row.get("mc_version")
        if not mc_v or mc_v in seen:
            continue
        seen.add(mc_v)
        mc_rows.append(_translate_row(row, selected_loaders))
    return mc_rows


def translate(resolver_doc: dict, identity: dict) -> dict:
    """Multi-MC translation: resolver output (2+ distinct MCs) → the
    `mc_versions`-array vars schema."""
    resolved = resolver_doc.get("resolved")
    if not isinstance(resolved, list) or len(resolved) < 2:
        raise ValueError(
            "translate_resolver expects resolver output with 2+ entries in 'resolved'; "
            f"got {len(resolved) if isinstance(resolved, list) else 'non-list'}"
        )

    selected_loaders = identity.get("loaders") or ["fabric", "neoforge"]
    if not isinstance(selected_loaders, list):
        raise ValueError("identity.loaders must be an array of loader names")

    mc_rows = _dedupe_rows(resolved, selected_loaders)

    if len(mc_rows) < 2:
        raise ValueError(
            f"after de-duplication only {len(mc_rows)} distinct MC version(s) remained; "
            "multi-MC scaffolding requires at least 2 distinct MC versions"
        )

    # MIN, not max: every per-MC line consumes :common's bytecode, and an
    # older JVM cannot load newer bytecode. Building :common at the highest
    # Java would make the older lines fail dependency resolution
    # ("only compatible with JVM runtime version <N> or newer").
    java_version_shared = min(r["java_version"] for r in mc_rows)

    out = _identity_fields(identity, selected_loaders)
    out["java_version_shared"] = java_version_shared
    out["primary_mc_version"] = mc_rows[0]["mc_version"]
    out["mc_versions"] = mc_rows
    return out


def translate_single(
    resolver_doc: dict, identity: dict, mc_version: str | None = None
) -> dict:
    """Single-MC translation: pick ONE resolver row (the first, or the one
    matching `mc_version`) and emit the flat single-MC vars schema."""
    resolved = resolver_doc.get("resolved")
    if not isinstance(resolved, list) or len(resolved) < 1:
        raise ValueError(
            "single-MC translation expects resolver output with 1+ entries in 'resolved'"
        )

    selected_loaders = identity.get("loaders") or ["fabric", "neoforge"]
    if not isinstance(selected_loaders, list):
        raise ValueError("identity.loaders must be an array of loader names")

    mc_rows = _dedupe_rows(resolved, selected_loaders)
    if not mc_rows:
        raise ValueError("no resolver row had a usable mc_version")

    if mc_version:
        matches = [r for r in mc_rows if r["mc_version"] == mc_version]
        if not matches:
            raise ValueError(
                f"--mc-version {mc_version} did not match any resolved row "
                f"(have: {', '.join(r['mc_version'] for r in mc_rows)})"
            )
        row = matches[0]
    else:
        row = mc_rows[0]

    out = _identity_fields(identity, selected_loaders)
    # Flat single-MC schema: the row's fields at top level (no mc_versions
    # array, no mc_suffix — the flat templates don't use suffixed keys).
    for key in (
        "mc_version",
        "java_version",
        "neoform_version",
        "neoform_version_is_placeholder",
        "neoforge_version",
        "fabric_loader_version",
        "fabric_api_version",
        "parchment_mc_version",
        "parchment_version",
        "has_fabric",
        "has_neoforge",
        "has_parchment",
        "is_unobfuscated",
        "fml_has_getcurrent",
    ):
        out[key] = row[key]
    return out


def _main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--resolver", required=True, help="Path to resolver JSON file.")
    p.add_argument("--identity", required=True, help="Path to identity JSON file.")
    p.add_argument("--out", required=True, help="Path to write vars.json to.")
    p.add_argument(
        "--single-mc",
        action="store_true",
        help="Emit the flat single-MC vars schema (keep exactly one MC row).",
    )
    p.add_argument(
        "--mc-version",
        default=None,
        help="With --single-mc: which resolved MC row to keep (default: first).",
    )
    args = p.parse_args()

    try:
        resolver_doc = json.loads(Path(args.resolver).read_text())
        identity = json.loads(Path(args.identity).read_text())
    except (OSError, json.JSONDecodeError) as e:
        print(f"failed to read input JSON: {e}", file=sys.stderr)
        return 2

    for required in ("modid", "package_base"):
        if not identity.get(required):
            print(f"identity is missing required field: {required}", file=sys.stderr)
            return 2

    try:
        if args.single_mc:
            vars_doc = translate_single(resolver_doc, identity, args.mc_version)
        else:
            vars_doc = translate(resolver_doc, identity)
    except ValueError as e:
        print(f"translation failed: {e}", file=sys.stderr)
        return 1

    Path(args.out).write_text(json.dumps(vars_doc, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(_main())
