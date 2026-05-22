#!/usr/bin/env python3
"""Translate `resolve-versions.sh` output into a multi-MC `vars.json` for
`expand-templates.sh`.

The init skill calls this when 2+ MC versions were resolved AND the user
opted for the multi-MC overlay scaffold. For single-MC scaffolds the skill
builds vars.json inline (existing v0.1.0 path) and never invokes this
helper.

Input:
    - --resolver  Path to a JSON file holding the raw output of
                  `resolve-versions.sh` (i.e. an object with `resolved` +
                  `warnings`).
    - --identity  Path to a JSON file holding identity fields supplied by
                  the user: modid, mod_name, mod_version, package_base,
                  package_base_path, description, license, authors, and
                  the selected `loaders` array.
    - --out       Path to write the translated multi-MC vars.json to.

The schema produced matches what `expand-templates.sh` consumes when it
detects `mc_versions.length >= 2`. See expand-templates.sh's header doc
for the canonical schema definition.

Per-MC translation rules:
    mc_suffix             = mc_version with '.' -> '_'
    java_version          = resolver row's java_toolchain
    neoforge_version      = loaders.neoforge.loader_version   (nullable)
    neoform_version       = `{mc_version}-1` placeholder (the resolver does
                            not currently emit a NeoForm timestamp; the
                            user is expected to bump this to the real
                            timestamp from
                            https://projects.neoforged.net/neoforged/neoform
                            before running the MDG build. This mirrors the
                            single-MC template's convention.)
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

Top-level:
    java_version_shared   = max(per-MC java_version). Top-level :common
                            compiles against this so its bytecode is
                            forward-compatible with every per-MC JVM.
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

    return {
        "mc_version": mc_version,
        "mc_suffix": _mc_suffix(mc_version),
        "java_version": int(java_toolchain),
        "neoforge_version": neo_loader_v,
        # The resolver does not currently emit a NeoForm timestamp. The
        # single-MC template uses `{mc_version}-1` as a placeholder; we
        # mirror that here so the rendered gradle.properties is structurally
        # valid. The user is expected to bump this to the real timestamp
        # before invoking MDG. See SKILL.md "Multi-MC scaffolding".
        "neoform_version": f"{mc_version}-1",
        "fabric_loader_version": fab_loader_v,
        "fabric_api_version": fab_api_v,
        "parchment_mc_version": parch.get("mc") if parch else None,
        "parchment_version": parch.get("version") if parch else None,
        "has_fabric": has_fabric,
        "has_neoforge": has_neoforge,
        "has_parchment": has_parchment,
    }


def translate(resolver_doc: dict, identity: dict) -> dict:
    resolved = resolver_doc.get("resolved")
    if not isinstance(resolved, list) or len(resolved) < 2:
        raise ValueError(
            "translate_resolver expects resolver output with 2+ entries in 'resolved'; "
            f"got {len(resolved) if isinstance(resolved, list) else 'non-list'}"
        )

    selected_loaders = identity.get("loaders") or ["fabric", "neoforge"]
    if not isinstance(selected_loaders, list):
        raise ValueError("identity.loaders must be an array of loader names")

    # De-duplicate while preserving order: if the user passed
    # --mc latest,latest we only want one row.
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

    if len(mc_rows) < 2:
        raise ValueError(
            f"after de-duplication only {len(mc_rows)} distinct MC version(s) remained; "
            "multi-MC scaffolding requires at least 2 distinct MC versions"
        )

    java_version_shared = max(r["java_version"] for r in mc_rows)

    # Carry through identity fields verbatim. Default package_base_path
    # from package_base if the caller didn't provide it.
    out = {
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
        "java_version_shared": java_version_shared,
        "mc_versions": mc_rows,
    }
    return out


def _main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--resolver", required=True, help="Path to resolver JSON file.")
    p.add_argument("--identity", required=True, help="Path to identity JSON file.")
    p.add_argument("--out", required=True, help="Path to write multi-MC vars.json to.")
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
        vars_doc = translate(resolver_doc, identity)
    except ValueError as e:
        print(f"translation failed: {e}", file=sys.stderr)
        return 1

    Path(args.out).write_text(json.dumps(vars_doc, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(_main())
