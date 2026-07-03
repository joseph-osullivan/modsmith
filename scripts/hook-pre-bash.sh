#!/bin/bash
# Hook handler for PreToolUse on Bash. Auto-cleans run/gametestserver/ before
# any `./gradlew runGameTestServer` invocation so the NeoForge harness's
# createOrResetDir doesn't trip on stale state.
#
# Receives JSON on stdin: {tool_name, tool_input: {command, ...}, ...}
# Always exits 0 (must not block the tool call).

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_common.sh"

# Read stdin, extract command. Use jq if available; fall back to grep.
INPUT=$(cat)

# Double-fire guard: personal skill copy wins if wired (see hook-session-start.sh).
if grep -qs 'mc-mod-develop/scripts/hook-' "$HOME/.claude/settings.json" 2>/dev/null; then
  exit 0
fi
CMD=""
if command -v jq >/dev/null 2>&1; then
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
else
  CMD=$(printf '%s' "$INPUT" | sed -n 's/.*"command":"\([^"]*\)".*/\1/p')
fi

# Only act for the specific command we care about.
case "$CMD" in
  *runGameTestServer*)
    if is_mc_mod_repo; then
      find run/gametestserver -mindepth 1 -depth -delete 2>/dev/null || true
    fi
    ;;
esac

exit 0
