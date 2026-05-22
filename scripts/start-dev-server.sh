#!/bin/bash
# start-dev-server.sh — launch the loader's dev client for a play-test
# session and tee its output to runs/<loader>/play-session.log.
#
# Usage:
#   start-dev-server.sh <loader>                 # fabric | neoforge
#   start-dev-server.sh <loader> --subproject :name
#
# Defaults to gradle task ":<loader>:runClient" (modern Loom + ModDevGradle
# both expose this). Use --subproject to override (e.g. ":mod-fabric"
# instead of ":fabric").
#
# Side effects (all under runs/<loader>/):
#   play-session.log        — tee'd stdout+stderr; appended in real-time
#   play-session.meta.json  — {started_at, loader, gradle_task, host_pid}
#   server.pid              — PID of the gradle wrapper process (this script's child)
#   .session-ended          — sentinel file written on exit (the log-watcher
#                             agent watches for this to trigger its finalize pass)
#   play-session.exit.json  — {exit_code, duration_s, wall_clock_end, crash_signal}
#
# Exit code mirrors gradle's exit code (so callers can detect crashes).
#
# Dependencies: bash, tee, awk, sed. POSIX-ish.

set -u
# Intentionally no `-e` — we want to capture gradle's exit code and write
# our exit artifacts even if it fails, then exit with that code ourselves.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_common.sh" 2>/dev/null || true

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------

usage() {
  sed -n '/^# start-dev-server.sh/,/^# Dependencies:/p' "$0" | sed 's/^# \{0,1\}//'
}

LOADER=""
SUBPROJECT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --subproject)
      shift
      if [ $# -lt 1 ]; then
        warn "--subproject requires a value (e.g. :fabric)"
        exit 2
      fi
      SUBPROJECT="$1"
      shift
      ;;
    fabric|neoforge)
      LOADER="$1"
      shift
      ;;
    *)
      warn "unknown argument: $1"
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$LOADER" ]; then
  warn "loader is required (fabric | neoforge)"
  usage >&2
  exit 2
fi

if [ -z "$SUBPROJECT" ]; then
  SUBPROJECT=":$LOADER"
fi

GRADLE_TASK="${SUBPROJECT}:runClient"

# ----------------------------------------------------------------------------
# Resolve paths and prepare runs/<loader>/
# ----------------------------------------------------------------------------

# Run dir is relative to cwd (the host project root). The orchestrator is
# responsible for cd'ing into the project before invoking us.
RUNS_DIR="runs/$LOADER"
mkdir -p "$RUNS_DIR" || {
  warn "could not create $RUNS_DIR"
  exit 1
}

LOG_PATH="$RUNS_DIR/play-session.log"
META_PATH="$RUNS_DIR/play-session.meta.json"
PID_PATH="$RUNS_DIR/server.pid"
SENTINEL_PATH="$RUNS_DIR/.session-ended"
EXIT_PATH="$RUNS_DIR/play-session.exit.json"

# Rotate any pre-existing play-session.log from a prior iteration so each
# kick-back round gets a fresh tee target (matches the convention in
# references/dev-server-playbook.md).
if [ -f "$LOG_PATH" ]; then
  ROTATED_TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo "rotated")
  mv "$LOG_PATH" "$RUNS_DIR/play-session.${ROTATED_TS}.log" 2>/dev/null || true
fi

# Clean stale exit / sentinel from a prior run; we own these on this run.
rm -f "$SENTINEL_PATH" "$EXIT_PATH" 2>/dev/null || true

# ----------------------------------------------------------------------------
# Resolve the gradle wrapper
# ----------------------------------------------------------------------------

GRADLEW=""
if [ -x "./gradlew" ]; then
  GRADLEW="./gradlew"
elif command -v gradle >/dev/null 2>&1; then
  GRADLEW="gradle"
else
  warn "no ./gradlew in cwd and no 'gradle' on PATH"
  exit 1
fi

# ----------------------------------------------------------------------------
# Write meta + start the dev server
# ----------------------------------------------------------------------------

STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
START_EPOCH=$(date -u +%s 2>/dev/null || echo 0)

# Use printf (not echo) for cross-shell consistency. JSON is small enough that
# we can hand-write it without a jq dependency.
printf '{"started_at":"%s","loader":"%s","gradle_task":"%s","host_pid":%d}\n' \
  "$STARTED_AT" "$LOADER" "$GRADLE_TASK" "$$" > "$META_PATH"

# Print a one-liner before launching so the player knows what's about to
# happen. Diagnostic line goes to stderr so we don't pollute the tee'd log.
warn "modsmith: launching dev server ($GRADLEW $GRADLE_TASK) — log at $LOG_PATH"

# Launch gradle in the background so we can record its PID, then wait. The
# `tee -a` appends to play-session.log so any rotated file isn't overwritten
# (we already moved it above; -a is belt-and-braces).
#
# We use 2>&1 to merge stderr into stdout so the player sees everything in
# one stream and the tee captures everything. Using `script` would also
# preserve a TTY, but we don't need TTY behavior — gradle's MC client
# launches its own window.
"$GRADLEW" "$GRADLE_TASK" 2>&1 | tee -a "$LOG_PATH" &
TEE_PID=$!

# Find the gradle PID — it's the first PID in the pipeline. POSIX gives us
# the last (tee). We approximate gradle's PID by finding the parent of tee's
# stdin (which is the gradle process). Cheaper and more portable: just
# capture the PIPESTATUS array's first PID via /dev/null indirection. Bash
# doesn't expose mid-pipeline PIDs directly, so we settle for recording
# TEE_PID and the gradle PGID; the orchestrator's PID-file check only needs
# *some* live PID associated with the session.
#
# Practical compromise: write TEE_PID. When tee exits, the gradle process
# has exited too (its stdout closed); the orchestrator's `kill -0 <pid>`
# liveness check returns false in either case.
printf '%d\n' "$TEE_PID" > "$PID_PATH"

# ----------------------------------------------------------------------------
# Wait for the pipeline to finish; capture gradle's exit code
# ----------------------------------------------------------------------------

# Trap signals so a Ctrl-C still writes the exit artifacts. We don't kill
# the child explicitly — the SIGINT will propagate through the pipeline.
CAUGHT_SIGNAL=""
trap 'CAUGHT_SIGNAL=INT' INT
trap 'CAUGHT_SIGNAL=TERM' TERM

wait "$TEE_PID"
# PIPESTATUS[0] is gradle, PIPESTATUS[1] is tee. We care about gradle.
GRADLE_EXIT=${PIPESTATUS[0]:-1}

# ----------------------------------------------------------------------------
# Write exit artifacts and the session-ended sentinel
# ----------------------------------------------------------------------------

END_EPOCH=$(date -u +%s 2>/dev/null || echo 0)
DURATION=$(( END_EPOCH - START_EPOCH ))
[ "$DURATION" -lt 0 ] && DURATION=0
END_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

# Format duration HHMMSS for the one-line summary.
HOURS=$(( DURATION / 3600 ))
MINS=$(( (DURATION % 3600) / 60 ))
SECS=$(( DURATION % 60 ))
DURATION_HMS=$(printf '%02d%02d%02d' "$HOURS" "$MINS" "$SECS")

# JSON for the exit artifact. crash_signal is null when we exited cleanly,
# the caught signal name otherwise. We keep this minimal and stable —
# downstream agents (log-watcher) read it.
if [ -n "$CAUGHT_SIGNAL" ]; then
  CRASH_SIGNAL_JSON="\"$CAUGHT_SIGNAL\""
else
  CRASH_SIGNAL_JSON="null"
fi

printf '{"exit_code":%d,"duration_s":%d,"wall_clock_end":"%s","crash_signal":%s}\n' \
  "$GRADLE_EXIT" "$DURATION" "$END_AT" "$CRASH_SIGNAL_JSON" > "$EXIT_PATH"

# The .session-ended sentinel is what agents/log-watcher.md watches for to
# trigger its finalize pass. We write it AFTER play-session.exit.json so
# any reader that races on the sentinel can already see the exit metadata.
: > "$SENTINEL_PATH"

# Clean up the PID file (the orchestrator's PID-liveness check now sees a
# missing file and treats that as "process exited").
rm -f "$PID_PATH" 2>/dev/null || true

# One-line summary to stderr (consistent with the convention in
# _common.sh — stdout reserved for structured data).
warn "Dev server exited (loader=$LOADER, duration=$DURATION_HMS, exit_code=$GRADLE_EXIT)"

exit "$GRADLE_EXIT"
