#!/bin/bash
# Hook handler for SubagentStop. Appends one JSONL line to the run dir's
# subagent-log.jsonl so the orchestrator can detect over-grinding agents
# without re-reading transcripts. Silent on success.
#
# Wired via the plugin's hooks/hooks.json (CLAUDE_PLUGIN_ROOT-relative).

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_common.sh"

INPUT=$(cat)

# Double-fire guard: personal skill copy wins if wired (see hook-session-start.sh).
if grep -qs 'mc-mod-develop/scripts/hook-' "$HOME/.claude/settings.json" 2>/dev/null; then
  exit 0
fi

if ! is_mc_mod_repo; then
  exit 0
fi

RUN_DIR=$(latest_run_dir 2>/dev/null || echo "")
if [ -z "$RUN_DIR" ]; then
  exit 0
fi

# Only log into an ACTIVE Lane 2 run. Archived runs (stamped ABANDONED,
# missing state.json, or current_phase=complete) must not accumulate log
# lines — otherwise any subagent stopping while cwd is the repo appends
# noise into historical run dirs (field-observed 2026-07).
STATE="$RUN_DIR/state.json"
if [ ! -f "$STATE" ] || [ -f "$RUN_DIR/ABANDONED.md" ]; then
  exit 0
fi
PHASE=""
if command -v jq >/dev/null 2>&1; then
  PHASE=$(jq -r '.current_phase // ""' "$STATE" 2>/dev/null)
else
  PHASE=$(sed -n 's/.*"current_phase"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE" | head -1)
fi
if [ -z "$PHASE" ] || [ "$PHASE" = "complete" ]; then
  exit 0
fi

LOG="$RUN_DIR/subagent-log.jsonl"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Best-effort enrichment: extract subagent_type and tool_call_count if present.
SUBAGENT="unknown"
TOOL_CALLS="?"
if command -v jq >/dev/null 2>&1; then
  SUBAGENT=$(printf '%s' "$INPUT" | jq -r '.subagent_type // .agent_type // "unknown"' 2>/dev/null)
  TOOL_CALLS=$(printf '%s' "$INPUT" | jq -r '.tool_call_count // .tool_calls // "?"' 2>/dev/null)
fi

printf '{"ts":"%s","subagent":"%s","tool_calls":"%s"}\n' "$TS" "$SUBAGENT" "$TOOL_CALLS" >> "$LOG"
exit 0
