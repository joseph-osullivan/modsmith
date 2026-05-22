#!/bin/bash
# run-gametest.sh — deterministic wrapper around `./gradlew runGameTestServer`.
# Cleans the universe first (no DirectoryNotEmptyException), tees output to a
# known path, returns structured success/failure.
#
# Usage:
#   run-gametest.sh [--log <path>] [--task <task>] [-- <gradle-args>...]
#
# Exit 0 on green; 1 on test failure; 2 on usage error; 4 on JVM crash.
# Stdout: one JSON line summarizing the run.
# Stderr: live tee of gradle output (so the caller can stream it).

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

LOG_PATH=""
TASK="runGameTestServer"
GRADLE_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOG_PATH="$2"; shift 2 ;;
    --task) TASK="$2"; shift 2 ;;
    --) shift; GRADLE_ARGS=("$@"); break ;;
    *) warn "unknown arg: $1"; exit 2 ;;
  esac
done

if ! is_mc_mod_repo; then
  emit_json status=error reason=not_mc_mod_repo
  exit 2
fi

ROOT=$(repo_root)
cd "$ROOT"

if [ -z "$LOG_PATH" ]; then
  LOG_PATH="/tmp/mc-mod-gametest-$(date +%Y%m%d-%H%M%S)-$$.log"
fi
mkdir -p "$(dirname "$LOG_PATH")"

# Pre-clean — the single most important step. NeoForge's createOrResetDir
# throws DirectoryNotEmptyException if any prior run left state behind.
find run/gametestserver -mindepth 1 -depth -delete 2>/dev/null || true

# Run gradle, tee to log, capture exit. We intentionally avoid `tee` exit-code
# semantics issues by using PIPESTATUS.
START=$(date +%s)
set +e
./gradlew "$TASK" "${GRADLE_ARGS[@]}" 2>&1 | tee "$LOG_PATH" >&2
GRADLE_EXIT=${PIPESTATUS[0]}
set -e
DURATION=$(( $(date +%s) - START ))

# Parse outcome from the log so the caller doesn't have to.
PASSED=$(grep -cE 'GameTest.*passed' "$LOG_PATH" 2>/dev/null | head -1 || echo 0)
FAILED=$(grep -cE 'GameTest.*failed|FAILED' "$LOG_PATH" 2>/dev/null | head -1 || echo 0)
CRASHED=0
grep -qE 'Exception in server tick loop|JVM crash|fatal error' "$LOG_PATH" 2>/dev/null && CRASHED=1

if [ $CRASHED -eq 1 ]; then
  STATUS=crashed
  EXIT=4
elif [ $GRADLE_EXIT -eq 0 ]; then
  STATUS=ok
  EXIT=0
else
  STATUS=failed
  EXIT=1
fi

emit_json \
  status="$STATUS" \
  gradle_exit="$GRADLE_EXIT" \
  passed="$PASSED" \
  failed="$FAILED" \
  duration_s="$DURATION" \
  log="$LOG_PATH"

exit $EXIT
