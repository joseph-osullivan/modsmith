#!/bin/bash
# Hook handler for SessionStart. Runs preflight + kill-stuck-jvms when cwd is
# a Minecraft mod project; silent otherwise. Output goes to the user transcript
# via stdout — keep it to one informative line on success, multi-line only when
# something is wrong.
#
# Wired in ~/.claude/settings.json under hooks.SessionStart.

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_common.sh"

# Discard hook input (we don't need session_id etc).
cat >/dev/null 2>&1 || true

if ! is_mc_mod_repo; then
  exit 0
fi

# Non-fatal: even if these fail, the session still starts.
PREFLIGHT_OUT=$("$DIR/preflight.sh" --check-only 2>/dev/null || echo '{"status":"err"}')
JVM_OUT=$("$DIR/kill-stuck-jvms.sh" 2>/dev/null || echo '{"killed_count":0}')

# Single-line summary.
printf 'mc-mod-develop preflight: %s | jvm-reaper: %s\n' "$PREFLIGHT_OUT" "$JVM_OUT"
