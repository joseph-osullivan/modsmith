#!/bin/bash
# Hook handler for SessionStart. Runs preflight + kill-stuck-jvms when cwd is
# a Minecraft mod project; silent otherwise. Output goes to the user transcript
# via stdout — keep it short on success, multi-line only when something is
# wrong or needs the model's attention.
#
# Wired via the plugin's hooks/hooks.json (CLAUDE_PLUGIN_ROOT-relative).

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_common.sh"

# Discard hook input (we don't need session_id etc).
cat >/dev/null 2>&1 || true

# Double-fire guard: if this machine ALSO wires equivalent hooks from a
# personal skill copy (~/.claude/settings.json pointing at
# .../skills/mc-mod-develop/scripts/), let the personal copy win — running
# both would double-fire the JVM reaper and duplicate the banner.
if grep -qs 'mc-mod-develop/scripts/hook-' "$HOME/.claude/settings.json" 2>/dev/null; then
  exit 0
fi

if ! is_mc_mod_repo; then
  exit 0
fi

# Non-fatal: even if these fail, the session still starts.
PREFLIGHT_OUT=$("$DIR/preflight.sh" --check-only 2>/dev/null || echo '{"status":"err"}')
JVM_OUT=$("$DIR/kill-stuck-jvms.sh" 2>/dev/null || echo '{"killed_count":0}')

# Summary line, then an imperative routing line: description-based skill
# auto-invocation is unreliable on mid-tier models, but an instruction in
# hook stdout lands in context deterministically — and this hook fires in
# exactly the repos where the skill applies.
printf 'modsmith preflight: %s | jvm-reaper: %s\n' "$PREFLIGHT_OUT" "$JVM_OUT"
printf 'This is a Minecraft mod repo: for ANY feature or fix work, invoke the modsmith develop skill (/modsmith:develop) BEFORE making code changes.\n'

# Landmine staleness banner: references/landmines.md is organized in
# per-MC-version sections. If this project's minecraft_version has NO
# section, every MC-API entry in the file predates this version — say so
# up front instead of letting stale guidance be applied silently
# (append-only files rot quietly).
LANDMINES="$DIR/../references/landmines.md"
MC_VER=""
if [ -f "gradle.properties" ]; then
  MC_VER=$(sed -n 's/^minecraft_version=\([0-9]*\.[0-9]*\).*/\1/p' gradle.properties | head -1)
fi
if [ -f "$LANDMINES" ] && [ -n "$MC_VER" ] && ! grep -q "^## Minecraft $MC_VER" "$LANDMINES"; then
  printf 'WARNING: references/landmines.md has no section for Minecraft %s — all MC-API entries are for OTHER versions. Verify with scripts/symbol-check.sh before applying any of them; start a "## Minecraft %s" section with what you learn.\n' "$MC_VER" "$MC_VER"
fi
