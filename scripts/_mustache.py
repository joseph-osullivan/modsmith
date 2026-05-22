#!/usr/bin/env python3
"""Tiny Mustache-subset renderer for modsmith templates.

Supports:
  - `{{var}}` and `{{ var }}` value interpolation
  - `{{#section}}...{{/section}}` iteration over arrays of objects
  - `{{^section}}...{{/section}}` inverted section (renders if value is
    missing, false, empty list, or empty string)

Lookup rules:
  - Inside a section iteration, names resolve against the inner object
    first, then fall back to the outer context (so per-MC sections can
    still reference `modid` from the global context).
  - Unresolved `{{name}}` tokens are LEFT IN PLACE. The caller's post-check
    is responsible for failing the render if any survive. This matches the
    original single-MC renderer's behavior.

Why a custom mini-Mustache instead of pulling in `chevron`/`pystache`?
We already require python3; adding a binary or pip dep increases the
install surface of the modsmith plugin. The subset above is enough for
modsmith's templates and clocks in around 60 lines.

Usage:
    render_file(src_path, dst_path, context)

where `context` is a dict that may contain scalars and lists-of-dicts.
"""

from __future__ import annotations

import os
import re
from typing import Any


_SECTION_RE = re.compile(
    r"\{\{\s*(?P<kind>[#^])\s*(?P<name>[a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}"
    r"(?P<body>.*?)"
    r"\{\{\s*/\s*(?P=name)\s*\}\}",
    re.DOTALL,
)

_VAR_RE = re.compile(r"\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}")


def _resolve(name: str, stack: list[dict[str, Any]]) -> Any:
    """Look up `name` against the context stack (innermost first)."""
    for ctx in reversed(stack):
        if name in ctx:
            return ctx[name]
    return None


def _truthy(value: Any) -> bool:
    if value is None or value is False:
        return False
    if isinstance(value, (list, tuple)) and len(value) == 0:
        return False
    if isinstance(value, str) and value == "":
        return False
    return True


def _render(text: str, stack: list[dict[str, Any]]) -> str:
    """Recursive Mustache subset renderer."""
    # Resolve all sections first (innermost via re.sub recursion).
    def section_repl(m: re.Match[str]) -> str:
        kind = m.group("kind")
        name = m.group("name")
        body = m.group("body")
        value = _resolve(name, stack)
        if kind == "#":
            if not _truthy(value):
                return ""
            if isinstance(value, list):
                parts = []
                for item in value:
                    inner = item if isinstance(item, dict) else {}
                    parts.append(_render(body, stack + [inner]))
                return "".join(parts)
            if isinstance(value, dict):
                return _render(body, stack + [value])
            # Truthy scalar: render body once in current context.
            return _render(body, stack)
        elif kind == "^":
            if _truthy(value):
                return ""
            return _render(body, stack)
        return ""

    # Apply outermost sections, looping until none remain (handles nesting).
    prev = None
    while prev != text:
        prev = text
        text = _SECTION_RE.sub(section_repl, text)

    # Now substitute plain variables.
    def var_repl(m: re.Match[str]) -> str:
        key = m.group(1)
        value = _resolve(key, stack)
        if value is None:
            return m.group(0)
        return str(value)

    return _VAR_RE.sub(var_repl, text)


def render_string(text: str, context: dict[str, Any]) -> str:
    return _render(text, [context])


def render_file(src: str, dst: str, context: dict[str, Any]) -> None:
    with open(src, encoding="utf-8") as f:
        text = f.read()
    out = _render(text, [context])
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    with open(dst, "w", encoding="utf-8") as f:
        f.write(out)
