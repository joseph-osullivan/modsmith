#!/bin/bash
# symbol-check.sh — compile-probe MC/loader API symbols against the host
# project's REAL classpath. Mechanizes the "throwaway probe class" technique:
# decompiled/toolchain-cache jars can be pre-mapping and lie about signatures;
# the only trustworthy oracle is javac against the project's compile classpath.
#
# Usage (single-loader / monolith):
#   scripts/symbol-check.sh <project_dir> <<'JAVA'
#   import net.minecraft.gametest.framework.GameTestHelper;
#   class Probe {
#       static void probe(GameTestHelper helper) {
#           helper.succeedWhen(() -> {});
#       }
#   }
#   JAVA
#
# Usage (multiloader — probe against one subproject's classpath):
#   scripts/symbol-check.sh --subproject :neoforge <project_dir> < probe.java
#   scripts/symbol-check.sh --subproject :common   <project_dir> < probe.java
#
# stdin  : a complete Java compilation unit (imports + one class). Any class
#          name works; the file is written as <ClassName>.java in the default
#          package of the target source set's test root.
# stdout : one JSON line: {"status":"ok"} or
#          {"status":"fail","errors":["...","..."]} (first 10 errors).
# exit   : 0 on ok, 1 on fail, 2 on usage/setup error.
#
# Requires the target to compile tests against MC classes (ModDevGradle
# `unitTest { enable() }`, Loom's test fixtures, or equivalent). The probe
# file is ALWAYS deleted, including on ctrl-C — nothing to commit, nothing
# to forget.

set -u

SUBPROJECT=""
if [ "${1:-}" = "--subproject" ]; then
  SUBPROJECT="${2:-}"
  shift 2
  case "$SUBPROJECT" in
    :*) ;;
    *) echo '{"status":"err","reason":"--subproject expects a gradle path like :neoforge or :common"}'; exit 2 ;;
  esac
fi

PROJECT="${1:-}"
[ -d "$PROJECT" ] || { echo '{"status":"err","reason":"usage: symbol-check.sh [--subproject :name] <project_dir> < probe.java"}'; exit 2; }
[ -f "$PROJECT/gradlew" ] || { echo '{"status":"err","reason":"no gradlew in project_dir"}'; exit 2; }

# Resolve the test source root: subproject dir for multiloader, root otherwise.
SUBDIR="${SUBPROJECT#:}"
SUBDIR="${SUBDIR//:/\/}"
if [ -n "$SUBPROJECT" ]; then
  [ -d "$PROJECT/$SUBDIR" ] || { echo "{\"status\":\"err\",\"reason\":\"subproject dir $SUBDIR not found under project\"}"; exit 2; }
  TEST_SRC="$PROJECT/$SUBDIR/src/test/java"
  GRADLE_TASK="${SUBPROJECT}:compileTestJava"
else
  TEST_SRC="$PROJECT/src/test/java"
  GRADLE_TASK="compileTestJava"
fi
mkdir -p "$TEST_SRC"

BODY="$(cat)"
CLASS="$(printf '%s\n' "$BODY" | sed -nE 's/.*(^|[[:space:]])(class|interface|record|enum)[[:space:]]+([A-Za-z0-9_]+).*/\3/p' | head -1)"
[ -n "$CLASS" ] || { echo '{"status":"err","reason":"no class declaration found on stdin"}'; exit 2; }

PROBE_FILE="$TEST_SRC/$CLASS.java"
[ -e "$PROBE_FILE" ] && { echo "{\"status\":\"err\",\"reason\":\"$CLASS.java already exists — pick a unique probe class name\"}"; exit 2; }

cleanup() { rm -f "$PROBE_FILE"; }
trap cleanup EXIT INT TERM

printf '%s\n' "$BODY" > "$PROBE_FILE"

OUT="$(cd "$PROJECT" && ./gradlew "$GRADLE_TASK" -q 2>&1)"
STATUS=$?

if [ $STATUS -eq 0 ]; then
  echo '{"status":"ok"}'
  exit 0
fi

# Emit the first 10 javac error lines as a JSON array (best-effort escaping).
printf '%s\n' "$OUT" \
  | grep -E "error:|cannot find symbol|incompatible types|method .* cannot be applied" \
  | head -10 \
  | python3 -c 'import json,sys; print(json.dumps({"status":"fail","errors":[l.rstrip() for l in sys.stdin]}))'
exit 1
