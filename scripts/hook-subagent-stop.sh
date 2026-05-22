#!/bin/bash
# Hook handler for SubagentStop. Appends one JSONL line to the run dir's
# subagent-log.jsonl so the orchestrator can detect over-grinding agents
# without re-reading transcripts. Silent on success.
#
# Wired in ~/.claude/settings.json under hooks.SubagentStop.

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_common.sh"

INPUT=$(cat)

if ! is_mc_mod_repo; then
  exit 0
fi

RUN_DIR=$(latest_run_dir 2>/dev/null || echo "")
if [ -z "$RUN_DIR" ]; then
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
