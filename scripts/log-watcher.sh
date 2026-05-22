#!/bin/bash
# log-watcher.sh — deterministic scanner for the dev-server play-session log.
#
# Reads a play-session log, applies feature-specific expectations
# (play-expectations.json) merged with universal + loader-specific baselines
# (extracted from references/log-watcher-rules.md), and updates a structured
# state file with new findings + byte offset for incremental re-scans.
#
# Called repeatedly by the log-watcher agent during the Handoff phase.
#
# Usage:
#   log-watcher.sh \
#     --log <path/to/play-session.log> \
#     --expectations <path/to/play-expectations.json> \
#     --rules <path/to/references/log-watcher-rules.md> \
#     --state <path/to/watcher-state.json> \
#     --loader <fabric|neoforge> \
#     [--since-byte N] \
#     [--finalize]
#
# Output:
#   stdout: updated watcher-state.json (also written to --state path)
#   stderr: brief diagnostics
#
# Exit codes:
#   0  scan completed (regardless of finding count)
#   2  usage / invalid arg
#   3  required input missing (log/rules/expectations not found)
#
# Dependencies: bash, awk, grep -E, jq, stat. POSIX-friendly otherwise.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

LOG=""
EXPECTATIONS=""
RULES=""
STATE=""
LOADER=""
SINCE_BYTE=""
FINALIZE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOG="$2"; shift 2 ;;
    --expectations) EXPECTATIONS="$2"; shift 2 ;;
    --rules) RULES="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --loader) LOADER="$2"; shift 2 ;;
    --since-byte) SINCE_BYTE="$2"; shift 2 ;;
    --finalize) FINALIZE=1; shift ;;
    *) warn "unknown arg: $1"; exit 2 ;;
  esac
done

[ -z "$LOG" ] && { warn "--log required"; exit 2; }
[ -z "$RULES" ] && { warn "--rules required"; exit 2; }
[ -z "$STATE" ] && { warn "--state required"; exit 2; }
[ -z "$LOADER" ] && { warn "--loader required"; exit 2; }
[ -z "$EXPECTATIONS" ] && { warn "--expectations required"; exit 2; }

# Required inputs must exist (log may be empty initially).
[ -f "$RULES" ] || { warn "rules file not found: $RULES"; exit 3; }
[ -f "$EXPECTATIONS" ] || { warn "expectations file not found: $EXPECTATIONS"; exit 3; }
if [ ! -f "$LOG" ]; then
  # Touch a zero-byte log so the rest of the pipeline has something to read.
  mkdir -p "$(dirname "$LOG")"
  : > "$LOG"
fi

mkdir -p "$(dirname "$STATE")"

# ── Pattern set assembly ───────────────────────────────────────────────────

# Extract a single <!-- baselines:CATEGORY --> ... ```jsonc ... ``` block from
# the rules markdown. Prints the JSON array body (or [] if not found).
extract_baseline_block() {
  local category="$1" rules_file="$2"
  awk -v cat="$category" '
    BEGIN { in_block = 0; in_jsonc = 0; printed = 0 }
    !printed && in_block && /^```jsonc[[:space:]]*$/ { in_jsonc = 1; next }
    !printed && in_jsonc && /^```[[:space:]]*$/ { in_jsonc = 0; in_block = 0; printed = 1; next }
    !printed && in_jsonc { print; next }
    !printed && $0 == "<!-- baselines:" cat " -->" { in_block = 1; next }
  ' "$rules_file"
}

# Build the merged pattern set:
#   universal baselines  +  loader baselines  +  feature should_see /
#   should_not_see / background_baseline.
# Each entry is normalized to: { pattern, severity, source, kind, min_count?,
# max_count?, note? }
# where kind ∈ {baseline, should_see, should_not_see, background_baseline}.
build_patterns() {
  local universal loader_block feature
  universal="$(extract_baseline_block "universal" "$RULES")"
  loader_block="$(extract_baseline_block "$LOADER" "$RULES")"
  [ -z "$universal" ] && universal="[]"
  [ -z "$loader_block" ] && loader_block="[]"
  feature="$(cat "$EXPECTATIONS")"

  jq -n \
    --argjson universal "$universal" \
    --argjson loader "$loader_block" \
    --argjson feature "$feature" \
    --arg loader_name "$LOADER" \
    '
    def normalize_baseline(arr; src):
      arr // [] | map({
        pattern: .pattern,
        severity: .severity,
        source: (.source // src),
        kind: "baseline",
        min_count: null,
        max_count: (.max_count // null),
        note: (.note // null)
      });

    def normalize_feature(arr; kind; default_severity):
      arr // [] | map({
        pattern: .pattern,
        severity: (.severity // default_severity),
        source: "feature-spec",
        kind: kind,
        min_count: (.min_count // null),
        max_count: (.max_count // null),
        note: (.note // null)
      });

    normalize_baseline($universal; "universal")
    + normalize_baseline($loader; $loader_name)
    + normalize_feature($feature.should_see; "should_see"; "warn_if_missing")
    + normalize_feature($feature.should_not_see; "should_not_see"; "warn")
    + normalize_feature($feature.background_baseline; "background_baseline"; "warn_if_exceeded")
    '
}

PATTERNS_JSON="$(build_patterns)"

# ── State seed ─────────────────────────────────────────────────────────────

# Load or seed the state file.
if [ -f "$STATE" ] && [ -s "$STATE" ]; then
  STATE_JSON="$(cat "$STATE")"
else
  STATE_JSON="$(jq -n --arg log "$LOG" '
    {
      raw_log_path: $log,
      byte_offset: 0,
      first_seen_log_ts: null,
      last_seen_log_ts: null,
      findings: [],
      performance: {
        tick_warnings: 0,
        tick_samples: [],
        avg_tick_ms: null,
        max_tick_ms: null
      },
      started_at_epoch: (now | floor)
    }
  ')"
fi

# Override byte_offset if caller passed --since-byte.
if [ -n "$SINCE_BYTE" ]; then
  STATE_JSON="$(echo "$STATE_JSON" | jq --argjson b "$SINCE_BYTE" '.byte_offset = $b')"
fi

PRIOR_OFFSET="$(echo "$STATE_JSON" | jq -r '.byte_offset')"

# ── Slice unread log ───────────────────────────────────────────────────────

# Current file size. Use stat with macOS / GNU compatibility shim.
log_size() {
  if stat -f '%z' "$1" >/dev/null 2>&1; then
    stat -f '%z' "$1"
  else
    stat -c '%s' "$1"
  fi
}

CURRENT_SIZE="$(log_size "$LOG")"

# Handle log truncation / rotation: if file shrunk, reset offset to 0.
if [ "$CURRENT_SIZE" -lt "$PRIOR_OFFSET" ]; then
  warn "log shrank (prior=$PRIOR_OFFSET current=$CURRENT_SIZE); resetting offset"
  PRIOR_OFFSET=0
fi

# Slice [PRIOR_OFFSET, CURRENT_SIZE) from the log into a temp file. The slice
# may end mid-line; we'll handle that by leaving the last partial line for
# the next invocation (move the new offset back to the last newline).
SLICE_FILE="$(mktemp -t log-watcher-slice.XXXXXX)"
trap 'rm -f "$SLICE_FILE"' EXIT

if [ "$CURRENT_SIZE" -gt "$PRIOR_OFFSET" ]; then
  # dd skips PRIOR_OFFSET bytes, then reads the rest. bs=1 is slow on huge
  # gaps but accurate. For typical play sessions (~MB) this is fine.
  dd if="$LOG" of="$SLICE_FILE" bs=1 skip="$PRIOR_OFFSET" count=$((CURRENT_SIZE - PRIOR_OFFSET)) 2>/dev/null
fi

# Trim the slice to the last complete newline so we don't half-process a
# partial last line. If there's no newline at all, drop the slice entirely
# and wait for the next scan.
NEW_OFFSET="$PRIOR_OFFSET"
if [ -s "$SLICE_FILE" ]; then
  # Find byte position of last \n in the slice.
  LAST_NL="$(awk 'BEGIN{pos=0} {pos+=length($0)+1} END{print pos}' "$SLICE_FILE")"
  # `pos` from awk includes the trailing \n if present. If the last line
  # didn't end in \n, we need to back off by its length.
  TOTAL_LEN="$(wc -c < "$SLICE_FILE" | tr -d ' ')"
  if [ -z "$LAST_NL" ] || [ "$LAST_NL" -eq 0 ]; then
    # No newlines at all in slice — defer.
    : > "$SLICE_FILE"
    NEW_OFFSET="$PRIOR_OFFSET"
  else
    # Truncate slice to LAST_NL bytes.
    if [ "$TOTAL_LEN" -gt "$LAST_NL" ]; then
      head -c "$LAST_NL" "$SLICE_FILE" > "${SLICE_FILE}.trim"
      mv "${SLICE_FILE}.trim" "$SLICE_FILE"
    fi
    NEW_OFFSET=$((PRIOR_OFFSET + LAST_NL))
  fi
fi

# ── Timestamp helpers ──────────────────────────────────────────────────────

# Best-effort: lines from MC look like "[HH:MM:SS] [thread/LEVEL] message".
# We extract HH:MM:SS and join to the log's file mtime date.
log_mtime_date() {
  if stat -f '%Sm' -t '%Y-%m-%d' "$1" >/dev/null 2>&1; then
    stat -f '%Sm' -t '%Y-%m-%d' "$1"
  else
    date -d "@$(stat -c '%Y' "$1")" '+%Y-%m-%d'
  fi
}

LOG_DATE="$(log_mtime_date "$LOG")"

# Extract first HH:MM:SS-style timestamp from a line, format as
# YYYY-MM-DDTHH:MM:SS.000, or empty if not present.
extract_ts() {
  local line="$1"
  local hms
  hms="$(echo "$line" | grep -oE '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]' | head -1 | tr -d '[]')"
  if [ -n "$hms" ]; then
    printf '%sT%s.000\n' "$LOG_DATE" "$hms"
  fi
}

# ── Pattern matching ───────────────────────────────────────────────────────

# For each pattern, grep -nE across the slice; emit one record per hit with
# the matched line, byte position within the slice (approx via line num), and
# context lines.
#
# Output: JSON array of {pattern_index, matched_line, line_no, ts, context}.
NEW_HITS_FILE="$(mktemp -t log-watcher-hits.XXXXXX)"
trap 'rm -f "$SLICE_FILE" "$NEW_HITS_FILE"' EXIT

printf '%s\n' "[]" > "$NEW_HITS_FILE"

# Iterate patterns.
PATTERN_COUNT="$(echo "$PATTERNS_JSON" | jq 'length')"

if [ -s "$SLICE_FILE" ] && [ "$PATTERN_COUNT" -gt 0 ]; then
  for i in $(seq 0 $((PATTERN_COUNT - 1))); do
    pattern="$(echo "$PATTERNS_JSON" | jq -r ".[$i].pattern")"
    kind="$(echo "$PATTERNS_JSON" | jq -r ".[$i].kind")"

    # should_see / should_not_see / baseline / background_baseline all scan
    # the same way at this stage; gap-status for should_see is computed at
    # finalize time.
    [ -z "$pattern" ] && continue

    # grep -nE: line number + text. Suppress errors for invalid regex —
    # malformed patterns are skipped rather than aborting the scan.
    while IFS= read -r grep_line; do
      [ -z "$grep_line" ] && continue
      line_no="${grep_line%%:*}"
      matched="${grep_line#*:}"
      ts="$(extract_ts "$matched")"
      # Context: one line before, the match, one line after.
      ctx_before=""
      ctx_after=""
      if [ "$line_no" -gt 1 ]; then
        ctx_before="$(sed -n "$((line_no - 1))p" "$SLICE_FILE" 2>/dev/null || true)"
      fi
      ctx_after="$(sed -n "$((line_no + 1))p" "$SLICE_FILE" 2>/dev/null || true)"

      # Build the hit record. Note: we use jq --arg to safely escape.
      jq --argjson hits "$(cat "$NEW_HITS_FILE")" \
         --argjson idx "$i" \
         --arg line "$matched" \
         --arg ts "$ts" \
         --arg before "$ctx_before" \
         --arg after "$ctx_after" \
         -n '
           $hits + [{
             pattern_index: $idx,
             line: $line,
             ts: (if $ts == "" then null else $ts end),
             context_before: (if $before == "" then null else $before end),
             context_after: (if $after == "" then null else $after end)
           }]
         ' > "${NEW_HITS_FILE}.tmp"
      mv "${NEW_HITS_FILE}.tmp" "$NEW_HITS_FILE"
    done < <(grep -nE "$pattern" "$SLICE_FILE" 2>/dev/null || true)
  done
fi

NEW_HITS_JSON="$(cat "$NEW_HITS_FILE")"

# ── Performance parsing ────────────────────────────────────────────────────

# Count new "Can't keep up!" warnings in the slice. grep -c exits 1 on no
# match but still emits "0" to stdout; we don't want the "|| echo" fallback
# stacking another line — capture safely.
NEW_TICK_WARNS=0
if [ -s "$SLICE_FILE" ]; then
  set +e
  NEW_TICK_WARNS="$(grep -cE "Can't keep up! .* ticks behind" "$SLICE_FILE" 2>/dev/null)"
  set -e
  NEW_TICK_WARNS="${NEW_TICK_WARNS:-0}"
fi

# Extract per-tick ms samples from "Server tick: <N>ms" lines (if the dev
# server emits them; many setups don't). Use a temp file so we can short-
# circuit cleanly when there are no matches (a piped pipeline can produce
# spurious output under set -e+pipefail).
TICK_SAMPLES_JSON="[]"
if [ -s "$SLICE_FILE" ]; then
  TICK_SAMPLES_RAW="$(grep -oE 'Server tick: [0-9]+ms' "$SLICE_FILE" 2>/dev/null | grep -oE '[0-9]+' || true)"
  if [ -n "$TICK_SAMPLES_RAW" ]; then
    TICK_SAMPLES_JSON="$(printf '%s\n' "$TICK_SAMPLES_RAW" | jq -R 'tonumber' | jq -s '.')"
  fi
fi

# Track the actual first/last log-line timestamps in the slice (for accurate
# session duration, regardless of which patterns matched).
SLICE_FIRST_TS=""
SLICE_LAST_TS=""
if [ -s "$SLICE_FILE" ]; then
  first_line="$(grep -m1 -E '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]' "$SLICE_FILE" 2>/dev/null || true)"
  last_line="$(grep -E '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]' "$SLICE_FILE" 2>/dev/null | tail -1 || true)"
  SLICE_FIRST_TS="$(extract_ts "$first_line")"
  SLICE_LAST_TS="$(extract_ts "$last_line")"
fi

# ── Merge into state ───────────────────────────────────────────────────────

# Group new hits by pattern_index, then merge into state.findings. For a
# pattern not yet in findings, create the entry. For an existing entry,
# bump hit_count and (only if existing context_lines.length < 3) extend
# the context.
STATE_JSON="$(echo "$STATE_JSON" | jq \
  --argjson hits "$NEW_HITS_JSON" \
  --argjson patterns "$PATTERNS_JSON" \
  --argjson new_warns "$NEW_TICK_WARNS" \
  --argjson new_samples "$TICK_SAMPLES_JSON" \
  --arg new_offset "$NEW_OFFSET" \
  --arg slice_first_ts "$SLICE_FIRST_TS" \
  --arg slice_last_ts "$SLICE_LAST_TS" \
  '
  def merge_hit(state; hit; patterns):
    state | (
      .findings as $f
      | (hit.pattern_index | tonumber) as $i
      | patterns[$i] as $p
      | ($f | map(.pattern) | index($p.pattern)) as $existing
      | if $existing == null then
          .findings += [{
            severity: $p.severity,
            pattern: $p.pattern,
            source: $p.source,
            kind: $p.kind,
            min_count: ($p.min_count // null),
            max_count: ($p.max_count // null),
            hit_count: 1,
            first_seen_ts: hit.ts,
            last_seen_ts: hit.ts,
            context_lines: (
              [hit.context_before, hit.line, hit.context_after]
              | map(select(. != null and . != ""))
            ),
            note: $p.note
          }]
        else
          .findings[$existing].hit_count += 1
          | (if .findings[$existing].first_seen_ts == null then
              .findings[$existing].first_seen_ts = hit.ts
             else . end)
          | .findings[$existing].last_seen_ts = hit.ts
          | (if (.findings[$existing].context_lines | length) < 3 then
              .findings[$existing].context_lines += (
                [hit.line] | map(select(. != null and . != ""))
              )
             else . end)
        end
    );

  # Apply each hit sequentially.
  ($hits) as $all
  | reduce range(0; ($all | length)) as $k (
      .;
      merge_hit(.; $all[$k]; $patterns)
    )
  | .byte_offset = ($new_offset | tonumber)
  | .performance.tick_warnings += $new_warns
  | .performance.tick_samples += $new_samples
  | (
      if (.first_seen_log_ts == null) and ($slice_first_ts != "") then
        .first_seen_log_ts = $slice_first_ts
      else . end
    )
  | (
      if $slice_last_ts != "" then
        .last_seen_log_ts = $slice_last_ts
      else . end
    )
  ')"

# ── Finalize pass ──────────────────────────────────────────────────────────

if [ "$FINALIZE" -eq 1 ]; then
  STATE_JSON="$(echo "$STATE_JSON" | jq \
    --argjson patterns "$PATTERNS_JSON" \
    '
    # Add zero-hit should_see entries (warn_if_missing).
    . as $s
    | reduce range(0; ($patterns | length)) as $i (
        .;
        ($patterns[$i]) as $p
        | if $p.kind == "should_see" then
            ((.findings | map(.pattern) | index($p.pattern)) as $existing
              | if $existing == null then
                  .findings += [{
                    severity: "warn_if_missing",
                    pattern: $p.pattern,
                    source: $p.source,
                    kind: $p.kind,
                    min_count: ($p.min_count // 1),
                    max_count: null,
                    hit_count: 0,
                    first_seen_ts: null,
                    last_seen_ts: null,
                    context_lines: [],
                    note: ($p.note // "expected at least \($p.min_count // 1) occurrence")
                  }]
                else
                  # Existing entry — if hit_count < min_count, downgrade severity
                  # to warn_if_missing-equivalent (the report layer renders it).
                  (if (.findings[$existing].hit_count < ($p.min_count // 1)) then
                    .findings[$existing].severity = "warn_if_missing"
                    | .findings[$existing].note = "observed \(.findings[$existing].hit_count) of \($p.min_count // 1) expected"
                   else
                    .findings[$existing].severity = "info"
                   end)
                end)
          else . end
      )
    # For any entry with a max_count threshold (universal baselines like
    # tick-warnings or feature background_baselines), promote to firing
    # when hit_count > threshold and demote to "info" otherwise.
    | .findings = (
        .findings
        | map(
            if (.max_count != null) and (.severity == "warn_if_exceeded") then
              if .hit_count > .max_count then
                .note = "observed \(.hit_count) > threshold \(.max_count)"
              else
                .severity = "info"
                | .note = "within threshold (\(.hit_count) of \(.max_count))"
              end
            else . end
          )
      )
    # Compute average / max tick ms from samples.
    | .performance.avg_tick_ms = (
        if (.performance.tick_samples | length) > 0 then
          ((.performance.tick_samples | add) / (.performance.tick_samples | length) | floor)
        else null end
      )
    | .performance.max_tick_ms = (
        if (.performance.tick_samples | length) > 0 then
          (.performance.tick_samples | max)
        else null end
      )
    # Compute duration_seconds: prefer log-ts derived; else file mtime - started_at.
    | .duration_seconds = (
        if .first_seen_log_ts != null and .last_seen_log_ts != null then
          # Naive HH:MM:SS arithmetic via splitting on T then on :
          ((.last_seen_log_ts | split("T")[1] | split(".")[0] | split(":") | map(tonumber) | (.[0]*3600 + .[1]*60 + .[2]))
            - (.first_seen_log_ts | split("T")[1] | split(".")[0] | split(":") | map(tonumber) | (.[0]*3600 + .[1]*60 + .[2])))
        else
          ((now | floor) - .started_at_epoch)
        end
      )
    | .finalized = true
    ')"
fi

# ── Persist + emit ─────────────────────────────────────────────────────────

# Atomic write: write to temp, then move.
TMP_OUT="${STATE}.tmp"
echo "$STATE_JSON" | jq '.' > "$TMP_OUT"
mv "$TMP_OUT" "$STATE"

# Print updated state to stdout.
cat "$STATE"

exit 0
