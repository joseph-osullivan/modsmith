#!/bin/bash
# doctor.sh — multi-loader hygiene audit. Emits a single JSON document on
# stdout describing findings; exits 0 if no hard_fail, 1 otherwise.
#
# Usage:
#   doctor.sh                                    # detects targets via detect-targets.sh, prints JSON
#   doctor.sh --json                             # same (the --json flag is currently a no-op; JSON is the only output)
#   doctor.sh --targets <path/to/detected.json>  # use a pre-computed targets JSON
#
# Output schema (see skills/doctor/SKILL.md for the user-facing version):
#   {
#     "summary": { "hard_fail_count": N, "warn_count": N, "passed_count": N,
#                  "verdict": "fail" | "pass" | "pass_with_warnings" },
#     "findings": [
#       { "check": "...", "severity": "hard_fail|warn|info",
#         "status": "fail|pass|skip", "file": "...", "line": N,
#         "message": "...", "fix_hint": "..." }
#     ]
#   }
#
# Dependencies: bash, awk, sed, grep, find. (jq is NOT required.)
#
# Exit codes:
#   0  every hard_fail check passed (the repo may still have warns or skips)
#   1  at least one hard_fail check failed
#   2  usage error

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------

JSON_ONLY=0
TARGETS_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json)
      JSON_ONLY=1
      shift
      ;;
    --targets)
      shift
      if [ $# -lt 1 ]; then
        warn "--targets requires a path argument"
        exit 2
      fi
      TARGETS_PATH="$1"
      shift
      ;;
    -h|--help)
      sed -n 's/^# \{0,1\}//p' "$0" | sed -n '/^doctor.sh/,/^Exit codes:/p'
      exit 0
      ;;
    *)
      warn "unknown argument: $1"
      exit 2
      ;;
  esac
done

ROOT="$(pwd)"

# ----------------------------------------------------------------------------
# Resolve the targets matrix. Either read the supplied file or invoke
# detect-targets.sh against cwd.
# ----------------------------------------------------------------------------

if [ -z "$TARGETS_PATH" ]; then
  TARGETS_PATH="$(mktemp -t modsmith-doctor-targets.XXXXXX)"
  # detect-targets.sh exits 1 on "unknown" layout; that's fine — we'll
  # surface the layout and skip most checks. So we deliberately don't
  # propagate its exit code here.
  if ! bash "$SCRIPT_DIR/detect-targets.sh" "$ROOT" > "$TARGETS_PATH" 2>/dev/null; then
    : # ignore non-zero; the JSON still describes the layout
  fi
fi

if [ ! -f "$TARGETS_PATH" ]; then
  warn "targets JSON not found: $TARGETS_PATH"
  exit 2
fi

# ----------------------------------------------------------------------------
# Minimal JSON extraction helpers — read the small subset of fields we need
# out of detect-targets' output without taking a jq dependency.
#
# These are NOT general-purpose JSON parsers; they assume the well-formed
# output that detect-targets.sh emits.
# ----------------------------------------------------------------------------

# Read a top-level string field. Returns empty if missing or null.
json_field_string() {
  local file="$1"
  local key="$2"
  awk -v k="$key" '
    {
      content = content $0
    }
    END {
      # Match "key":"value" or "key":null
      pat = "\"" k "\""
      idx = index(content, pat)
      if (idx == 0) { exit }
      rest = substr(content, idx + length(pat))
      # skip whitespace and colon
      sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
      if (substr(rest, 1, 4) == "null") { exit }
      if (substr(rest, 1, 1) != "\"") { exit }
      rest = substr(rest, 2)
      out = ""
      i = 1
      while (i <= length(rest)) {
        c = substr(rest, i, 1)
        if (c == "\\") {
          n = substr(rest, i + 1, 1)
          if (n == "n") out = out "\n"
          else if (n == "t") out = out "\t"
          else if (n == "r") out = out "\r"
          else out = out n
          i += 2
        } else if (c == "\"") {
          break
        } else {
          out = out c
          i += 1
        }
      }
      print out
    }
  ' "$file"
}

# Read a top-level integer field. Returns empty if null or missing.
json_field_int() {
  local file="$1"
  local key="$2"
  awk -v k="$key" '
    { content = content $0 }
    END {
      pat = "\"" k "\""
      idx = index(content, pat)
      if (idx == 0) { exit }
      rest = substr(content, idx + length(pat))
      sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
      if (substr(rest, 1, 4) == "null") { exit }
      m = match(rest, /^-?[0-9]+/)
      if (m == 0) { exit }
      print substr(rest, RSTART, RLENGTH)
    }
  ' "$file"
}

# Read a top-level boolean field. Returns 1 if true, 0 otherwise / missing.
json_field_bool() {
  local file="$1"
  local key="$2"
  awk -v k="$key" '
    { content = content $0 }
    END {
      pat = "\"" k "\""
      idx = index(content, pat)
      if (idx == 0) { print 0; exit }
      rest = substr(content, idx + length(pat))
      sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
      if (substr(rest, 1, 4) == "true") { print 1; exit }
      print 0
    }
  ' "$file"
}

# Iterate the "mc_commons" array — emit one tab-separated row per element:
#   mc_version\tsubproject\tjava_toolchain
json_iter_mc_commons() {
  local file="$1"
  awk '
    { content = content $0 }
    END {
      idx = index(content, "\"mc_commons\"")
      if (idx == 0) { exit }
      rest = substr(content, idx)
      o = index(rest, "[")
      if (o == 0) { exit }
      rest = substr(rest, o + 1)
      depth = 1
      arr = ""
      i = 1
      while (i <= length(rest) && depth > 0) {
        c = substr(rest, i, 1)
        if (c == "[") depth += 1
        else if (c == "]") {
          depth -= 1
          if (depth == 0) break
        }
        arr = arr c
        i += 1
      }
      while (1) {
        s = index(arr, "{")
        if (s == 0) break
        d = 1
        j = s + 1
        while (j <= length(arr) && d > 0) {
          ch = substr(arr, j, 1)
          if (ch == "{") d += 1
          else if (ch == "}") d -= 1
          j += 1
        }
        obj = substr(arr, s, j - s)
        arr = substr(arr, j + 1)
        mc   = extract_str(obj, "mc_version")
        subp = extract_str(obj, "subproject")
        java = extract_int(obj, "java_toolchain")
        printf "%s\t%s\t%s\n", mc, subp, java
      }
    }
    function extract_str(obj, k) {
      pat = "\"" k "\""
      i = index(obj, pat)
      if (i == 0) return ""
      r = substr(obj, i + length(pat))
      sub(/^[[:space:]]*:[[:space:]]*/, "", r)
      if (substr(r, 1, 4) == "null") return ""
      if (substr(r, 1, 1) != "\"") return ""
      r = substr(r, 2)
      out = ""
      ii = 1
      while (ii <= length(r)) {
        cc = substr(r, ii, 1)
        if (cc == "\\") {
          out = out substr(r, ii + 1, 1)
          ii += 2
        } else if (cc == "\"") {
          break
        } else {
          out = out cc
          ii += 1
        }
      }
      return out
    }
    function extract_int(obj, k) {
      pat = "\"" k "\""
      i = index(obj, pat)
      if (i == 0) return ""
      r = substr(obj, i + length(pat))
      sub(/^[[:space:]]*:[[:space:]]*/, "", r)
      if (substr(r, 1, 4) == "null") return ""
      m = match(r, /^-?[0-9]+/)
      if (m == 0) return ""
      return substr(r, RSTART, RLENGTH)
    }
  ' "$file"
}

# Iterate the "targets" array — emit one tab-separated row per element:
#   loader\tmc_version\tloader_version\tsubproject\tjava_toolchain
json_iter_targets() {
  local file="$1"
  awk '
    { content = content $0 }
    END {
      idx = index(content, "\"targets\"")
      if (idx == 0) { exit }
      rest = substr(content, idx)
      # Find the opening "["
      o = index(rest, "[")
      if (o == 0) { exit }
      rest = substr(rest, o + 1)
      depth = 1
      arr = ""
      i = 1
      while (i <= length(rest) && depth > 0) {
        c = substr(rest, i, 1)
        if (c == "[") depth += 1
        else if (c == "]") {
          depth -= 1
          if (depth == 0) break
        }
        arr = arr c
        i += 1
      }
      # Now split arr on each "{...}" object.
      while (1) {
        s = index(arr, "{")
        if (s == 0) break
        # Find matching "}"
        d = 1
        j = s + 1
        while (j <= length(arr) && d > 0) {
          ch = substr(arr, j, 1)
          if (ch == "{") d += 1
          else if (ch == "}") d -= 1
          j += 1
        }
        obj = substr(arr, s, j - s)
        arr = substr(arr, j + 1)

        loader   = extract_str(obj, "loader")
        mc       = extract_str(obj, "mc_version")
        lver     = extract_str(obj, "loader_version")
        subp     = extract_str(obj, "subproject")
        java     = extract_int(obj, "java_toolchain")
        printf "%s\t%s\t%s\t%s\t%s\n", loader, mc, lver, subp, java
      }
    }
    function extract_str(obj, k) {
      pat = "\"" k "\""
      i = index(obj, pat)
      if (i == 0) return ""
      r = substr(obj, i + length(pat))
      sub(/^[[:space:]]*:[[:space:]]*/, "", r)
      if (substr(r, 1, 4) == "null") return ""
      if (substr(r, 1, 1) != "\"") return ""
      r = substr(r, 2)
      out = ""
      ii = 1
      while (ii <= length(r)) {
        cc = substr(r, ii, 1)
        if (cc == "\\") {
          out = out substr(r, ii + 1, 1)
          ii += 2
        } else if (cc == "\"") {
          break
        } else {
          out = out cc
          ii += 1
        }
      }
      return out
    }
    function extract_int(obj, k) {
      pat = "\"" k "\""
      i = index(obj, pat)
      if (i == 0) return ""
      r = substr(obj, i + length(pat))
      sub(/^[[:space:]]*:[[:space:]]*/, "", r)
      if (substr(r, 1, 4) == "null") return ""
      m = match(r, /^-?[0-9]+/)
      if (m == 0) return ""
      return substr(r, RSTART, RLENGTH)
    }
  ' "$file"
}

# ----------------------------------------------------------------------------
# Pull the matrix into shell variables.
# ----------------------------------------------------------------------------

LAYOUT=$(json_field_string "$TARGETS_PATH" "layout")
COMMON_SUBPROJECT=$(json_field_string "$TARGETS_PATH" "common_subproject")
MULTI_MC=$(json_field_bool "$TARGETS_PATH" "multi_mc")

# Per-target parallel arrays
T_LOADER=()
T_MC=()
T_LVER=()
T_SUBPROJECT=()
T_JAVA=()

while IFS=$'\t' read -r loader mc lver subp java; do
  [ -z "$loader" ] && continue
  T_LOADER+=("$loader")
  T_MC+=("$mc")
  T_LVER+=("$lver")
  T_SUBPROJECT+=("$subp")
  T_JAVA+=("$java")
done < <(json_iter_targets "$TARGETS_PATH")

# Per-MC common subproject parallel arrays (populated only when multi_mc=1).
MC_COMMON_MC=()
MC_COMMON_SUBPROJECT=()
MC_COMMON_JAVA=()

while IFS=$'\t' read -r mc subp java; do
  [ -z "$mc" ] && continue
  MC_COMMON_MC+=("$mc")
  MC_COMMON_SUBPROJECT+=("$subp")
  MC_COMMON_JAVA+=("$java")
done < <(json_iter_mc_commons "$TARGETS_PATH")

# A helper: list the unique MC versions in the multi-MC matrix.
unique_mcs() {
  local i=0
  local n=${#T_MC[@]}
  local seen=""
  while [ $i -lt $n ]; do
    local mc="${T_MC[$i]}"
    i=$((i + 1))
    [ -z "$mc" ] && continue
    case " $seen " in
      *" $mc "*) ;;
      *) seen="$seen $mc"; printf '%s\n' "$mc" ;;
    esac
  done
  # Also include any per-MC commons that may have no loader target.
  local k=0
  local m=${#MC_COMMON_MC[@]}
  while [ $k -lt $m ]; do
    local mc="${MC_COMMON_MC[$k]}"
    k=$((k + 1))
    [ -z "$mc" ] && continue
    case " $seen " in
      *" $mc "*) ;;
      *) seen="$seen $mc"; printf '%s\n' "$mc" ;;
    esac
  done
}

# A helper: convert "1.21.1" to the "1_21_1" suffix used in gradle.properties.
mc_suffix() {
  printf '%s' "${1//./_}"
}

# Either "multiloader" or "multiloader-multi-mc" — both are checked by the
# multi-loader-style checks. The single-MC checks gate on LAYOUT="multiloader".
is_any_multiloader() {
  case "$LAYOUT" in
    multiloader|multiloader-multi-mc) return 0 ;;
    *) return 1 ;;
  esac
}

# Map a Gradle subproject path (":fabric") to a filesystem directory under ROOT.
subproject_dir() {
  local p="$1"
  case "$p" in
    "")  printf '' ;;
    ":") printf '.' ;;
    :*)
      local rel="${p#:}"
      rel="${rel//://}"
      printf '%s' "$rel"
      ;;
    *)   printf '%s' "$p" ;;
  esac
}

# Find a build.gradle(.kts) for a relative subproject directory; print path or empty.
subproject_build_file() {
  local dir="$1"
  [ -z "$dir" ] && return 0
  if [ -f "$dir/build.gradle" ]; then
    printf '%s' "$dir/build.gradle"
  elif [ -f "$dir/build.gradle.kts" ]; then
    printf '%s' "$dir/build.gradle.kts"
  fi
}

# Loader-by-name lookup — print the relative subproject dir of the named loader,
# or empty if the matrix doesn't include it.
loader_dir() {
  local needle="$1"
  local i=0
  local n=${#T_LOADER[@]}
  while [ $i -lt $n ]; do
    if [ "${T_LOADER[$i]}" = "$needle" ]; then
      subproject_dir "${T_SUBPROJECT[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 0
}

# ----------------------------------------------------------------------------
# Findings accumulator. Each finding is one entry across parallel arrays.
# ----------------------------------------------------------------------------

F_CHECK=()
F_SEVERITY=()
F_STATUS=()
F_FILE=()
F_LINE=()
F_MESSAGE=()
F_HINT=()

HARD_FAIL_COUNT=0
WARN_COUNT=0
PASSED_COUNT=0

add_finding() {
  local check="$1"
  local severity="$2"   # hard_fail | warn | info
  local status="$3"     # fail | pass | skip
  local file="$4"
  local line="$5"
  local message="$6"
  local hint="$7"

  F_CHECK+=("$check")
  F_SEVERITY+=("$severity")
  F_STATUS+=("$status")
  F_FILE+=("$file")
  F_LINE+=("$line")
  F_MESSAGE+=("$message")
  F_HINT+=("$hint")

  if [ "$status" = "fail" ] && [ "$severity" = "hard_fail" ]; then
    HARD_FAIL_COUNT=$((HARD_FAIL_COUNT + 1))
  elif [ "$status" = "fail" ] && [ "$severity" = "warn" ]; then
    WARN_COUNT=$((WARN_COUNT + 1))
  elif [ "$status" = "pass" ]; then
    PASSED_COUNT=$((PASSED_COUNT + 1))
  fi
}

# JSON escape — same rules as detect-targets.sh.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# ----------------------------------------------------------------------------
# Helpers used by multiple checks
# ----------------------------------------------------------------------------

read_gradle_prop() {
  local file="$1"
  local key="$2"
  if [ -f "$file" ]; then
    awk -F= -v k="$key" '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      {
        sub(/^[[:space:]]+/, "", $1)
        sub(/[[:space:]]+$/, "", $1)
        if ($1 == k) {
          line = $0
          sub(/^[^=]*=/, "", line)
          sub(/^[[:space:]]+/, "", line)
          sub(/[[:space:]]+$/, "", line)
          print line
          exit
        }
      }
    ' "$file"
  fi
  return 0
}

# Extract a string value out of a JSON file using a simple awk routine.
# Used for fabric.mod.json mod id reads. Returns the first match in document order.
read_json_string_field() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] || return 0
  awk -v k="$key" '
    BEGIN { found = 0 }
    {
      line = $0
      while ((m = match(line, "\"" k "\"[[:space:]]*:[[:space:]]*\"[^\"]*\"")) > 0) {
        seg = substr(line, RSTART, RLENGTH)
        sub(/^[^:]*:[[:space:]]*"/, "", seg)
        sub(/"$/, "", seg)
        print seg
        found = 1
        exit
      }
    }
  ' "$file"
  return 0
}

# Extract the [[mods]].modId from a neoforge.mods.toml.
read_toml_modid() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    /^[[:space:]]*modId[[:space:]]*=/ {
      line = $0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      gsub(/^["'\'']/, "", line)
      gsub(/["'\''][[:space:]]*$/, "", line)
      print line
      exit
    }
  ' "$file"
  return 0
}

# Strip block + line comments from gradle code so we don't match inside them.
# This isn't a real parser; it's a best-effort filter that drops everything
# from `//` to EOL and lines bracketed by `/*` ... `*/`.
strip_gradle_comments() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    BEGIN { inblock = 0 }
    {
      line = $0
      # Block comments
      while (1) {
        if (inblock) {
          ce = index(line, "*/")
          if (ce == 0) { line = ""; break }
          line = substr(line, ce + 2)
          inblock = 0
        } else {
          cs = index(line, "/*")
          if (cs == 0) break
          ce = index(substr(line, cs + 2), "*/")
          if (ce == 0) {
            line = substr(line, 1, cs - 1)
            inblock = 1
            break
          }
          line = substr(line, 1, cs - 1) substr(line, cs + 2 + ce + 1)
        }
      }
      # Line comments
      sub(/\/\/.*$/, "", line)
      print line
    }
  ' "$file"
}

# Best-effort detection of the modid from gradle.properties (modid/mod_id/modId).
detect_root_modid() {
  local v
  for k in modid mod_id modId; do
    v=$(read_gradle_prop "gradle.properties" "$k")
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  done
  return 0
}

# Java-toolchain expected for an MC version.
expected_java_for_mc() {
  local mc="$1"
  case "$mc" in
    1.21*|1.21) printf '21' ;;
    26.*)       printf '25' ;;
    1.20*|1.20|1.19*|1.18*|1.17*) printf '17' ;;
    *)          printf '' ;;
  esac
}

# ----------------------------------------------------------------------------
# Check 3: common-no-loader-imports
# ----------------------------------------------------------------------------

check_common_no_loader_imports() {
  if ! is_any_multiloader; then
    add_finding "common-no-loader-imports" "hard_fail" "skip" "" "" \
      "skipped: layout=$LAYOUT (multiloader-only check)" ""
    return 0
  fi

  # Gather every common-style directory to walk:
  #   - top-level :common (both multiloader and multi-MC)
  #   - per-MC :versions:<mc>:common (multi-MC only)
  local dirs=()
  local labels=()
  local cdir
  cdir=$(subproject_dir "$COMMON_SUBPROJECT")
  if [ -n "$cdir" ] && [ -d "$cdir/src/main/java" ]; then
    dirs+=("$cdir/src/main/java")
    labels+=("$cdir")
  fi
  if [ "$MULTI_MC" = "1" ]; then
    local k=0
    local m=${#MC_COMMON_MC[@]}
    while [ $k -lt $m ]; do
      local subp="${MC_COMMON_SUBPROJECT[$k]}"
      k=$((k + 1))
      local d
      d=$(subproject_dir "$subp")
      [ -n "$d" ] && [ -d "$d/src/main/java" ] && {
        dirs+=("$d/src/main/java")
        labels+=("$d")
      }
    done
  fi

  if [ ${#dirs[@]} -eq 0 ]; then
    add_finding "common-no-loader-imports" "hard_fail" "skip" "" "" \
      "skipped: no common/src/main/java directory (top-level or per-MC)" ""
    return 0
  fi

  local any_fail=0
  local idx=0
  while [ $idx -lt ${#dirs[@]} ]; do
    local d="${dirs[$idx]}"
    local label="${labels[$idx]}"
    idx=$((idx + 1))
    while IFS= read -r -d '' f; do
      while IFS=: read -r lineno line; do
        [ -z "$lineno" ] && continue
        local msg="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        add_finding "common-no-loader-imports" "hard_fail" "fail" \
          "$f" "$lineno" \
          "$msg in $label/ — loader APIs forbidden in common" \
          "Move this code to a platform helper interface in $label/.../platform/ (see references/expect-actual-pattern.md) or to the appropriate loader subproject"
        any_fail=1
      done < <(grep -nE '^[[:space:]]*import[[:space:]]+net\.(fabricmc|neoforged)\.' "$f" 2>/dev/null || true)
    done < <(find "$d" -type f -name '*.java' -print0 2>/dev/null)
  done

  if [ $any_fail -eq 0 ]; then
    local scope="common/src/main/java"
    [ "$MULTI_MC" = "1" ] && scope="top-level :common and every :versions:<mc>:common"
    add_finding "common-no-loader-imports" "hard_fail" "pass" "" "" \
      "no loader-specific imports under $scope" ""
  fi
}

# ----------------------------------------------------------------------------
# Check 1 + 2: platform-interface-impl-coverage + services-meta-inf-registration
#
# For each interface declared in a `platform/` directory under any common
# module, verify (a) there's an impl in every applicable loader subproject
# and (b) the META-INF/services/ registration is present + valid.
#
# Multi-MC: a top-level :common interface needs impls in EVERY (mc, loader)
# pair; a :versions:<mc>:common interface only needs impls in that MC line's
# loader subprojects.
# ----------------------------------------------------------------------------

# Inner helper for coverage/services: given a platform-interface .java file
# and a list of (loader, subdir) pairs, verify impl + services. Writes
# findings; sets the two outer "any_*_fail" via globals so we can summarize.
__plat_check_interface() {
  local f="$1"; shift
  local base; base=$(basename "$f" .java)

  # Skip Services.java (the wrapper) by name convention.
  if [ "$base" = "Services" ]; then return 0; fi
  # Verify the file actually declares `public interface <base>`.
  if ! grep -qE "^[[:space:]]*public[[:space:]]+interface[[:space:]]+${base}([[:space:]<{]|$)" "$f"; then
    return 0
  fi
  PLAT_FOUND_INTERFACES=1

  # Derive FQN from package + class name.
  local pkg
  pkg=$(awk '/^[[:space:]]*package[[:space:]]+/ {
    sub(/^[[:space:]]*package[[:space:]]+/, "")
    sub(/;.*$/, "")
    gsub(/[[:space:]]/, "")
    print
    exit
  }' "$f")
  local fqn=""
  if [ -n "$pkg" ]; then fqn="${pkg}.${base}"; else fqn="$base"; fi

  # The remaining args are pairs: loader, subdir, loader, subdir, ...
  while [ $# -gt 0 ]; do
    local loader="$1"; shift
    local subdir="$1"; shift
    [ -z "$subdir" ] && continue

    # (a) impl class
    local impl_match=""
    if [ -d "$subdir/src/main/java" ]; then
      impl_match=$( { grep -rlE "implements[[:space:]]+([A-Za-z0-9_.]+\\.)?${base}([[:space:]<,{]|$)" \
        "$subdir/src/main/java" 2>/dev/null || true; } | head -1)
    fi
    if [ -z "$impl_match" ]; then
      add_finding "platform-interface-impl-coverage" "hard_fail" "fail" \
        "$f" "" \
        "interface $fqn has no impl in $loader subproject ($subdir)" \
        "Add a class under $subdir/src/main/java that declares 'implements $base' and register it via META-INF/services/$fqn"
      PLAT_ANY_COVERAGE_FAIL=1
    else
      local impl_base impl_pkg impl_fqn
      impl_base=$(basename "$impl_match" .java)
      impl_pkg=$(awk '/^[[:space:]]*package[[:space:]]+/ {
        sub(/^[[:space:]]*package[[:space:]]+/, "")
        sub(/;.*$/, "")
        gsub(/[[:space:]]/, "")
        print
        exit
      }' "$impl_match")
      if [ -n "$impl_pkg" ]; then impl_fqn="${impl_pkg}.${impl_base}"; else impl_fqn="$impl_base"; fi

      local svc_file="$subdir/src/main/resources/META-INF/services/$fqn"
      if [ ! -f "$svc_file" ]; then
        add_finding "services-meta-inf-registration" "hard_fail" "fail" \
          "$svc_file" "" \
          "$loader: missing META-INF/services/$fqn registering an impl of $fqn" \
          "Create $svc_file with one line: $impl_fqn"
        PLAT_ANY_SERVICES_FAIL=1
      else
        local listed
        listed=$(awk '
          /^[[:space:]]*#/ { next }
          /^[[:space:]]*$/ { next }
          { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print; exit }
        ' "$svc_file")
        if [ -z "$listed" ]; then
          add_finding "services-meta-inf-registration" "hard_fail" "fail" \
            "$svc_file" "" \
            "$loader: META-INF/services/$fqn is empty" \
            "Write the FQN of the impl class on a single line (e.g. $impl_fqn)"
          PLAT_ANY_SERVICES_FAIL=1
        elif ! printf '%s' "$listed" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$'; then
          add_finding "services-meta-inf-registration" "hard_fail" "fail" \
            "$svc_file" "" \
            "$loader: META-INF/services/$fqn first line is not a valid Java FQN: '$listed'" \
            "Replace with the impl class FQN (e.g. $impl_fqn)"
          PLAT_ANY_SERVICES_FAIL=1
        else
          local impl_path
          impl_path="$subdir/src/main/java/$(printf '%s' "$listed" | sed 's|\.|/|g').java"
          if [ ! -f "$impl_path" ]; then
            add_finding "services-meta-inf-registration" "hard_fail" "fail" \
              "$svc_file" "" \
              "$loader: META-INF/services/$fqn references $listed but $impl_path does not exist" \
              "Either rename the file/class, or fix the line in $svc_file to match the actual impl"
            PLAT_ANY_SERVICES_FAIL=1
          fi
        fi
      fi
    fi
  done
}

check_platform_coverage_and_services() {
  if ! is_any_multiloader; then
    add_finding "platform-interface-impl-coverage" "hard_fail" "skip" "" "" \
      "skipped: layout=$LAYOUT (multiloader-only check)" ""
    add_finding "services-meta-inf-registration" "hard_fail" "skip" "" "" \
      "skipped: layout=$LAYOUT (multiloader-only check)" ""
    return 0
  fi

  # Globals consumed by the inner helper.
  PLAT_ANY_COVERAGE_FAIL=0
  PLAT_ANY_SERVICES_FAIL=0
  PLAT_FOUND_INTERFACES=0

  # Walk top-level :common platform interfaces against EVERY (mc, loader) target.
  local common_dir
  common_dir=$(subproject_dir "$COMMON_SUBPROJECT")
  if [ -n "$common_dir" ] && [ -d "$common_dir/src/main/java" ]; then
    # Build target pairs (loader, subdir) — all of them, since top-level
    # interfaces must be implemented in every loader subproject.
    local target_args=()
    local i=0
    local n=${#T_LOADER[@]}
    while [ $i -lt $n ]; do
      local subp
      subp=$(subproject_dir "${T_SUBPROJECT[$i]}")
      target_args+=("${T_LOADER[$i]}" "$subp")
      i=$((i + 1))
    done
    while IFS= read -r -d '' pdir; do
      while IFS= read -r -d '' f; do
        __plat_check_interface "$f" "${target_args[@]}"
      done < <(find "$pdir" -maxdepth 1 -type f -name '*.java' -print0 2>/dev/null)
    done < <(find "$common_dir/src/main/java" -type d -name platform -print0 2>/dev/null)
  fi

  # Multi-MC: walk per-MC :versions:<mc>:common platform interfaces against
  # only that MC's loader subprojects.
  if [ "$MULTI_MC" = "1" ]; then
    local k=0
    local m=${#MC_COMMON_MC[@]}
    while [ $k -lt $m ]; do
      local mc="${MC_COMMON_MC[$k]}"
      local sub="${MC_COMMON_SUBPROJECT[$k]}"
      k=$((k + 1))
      local pmc_dir
      pmc_dir=$(subproject_dir "$sub")
      [ -z "$pmc_dir" ] && continue
      [ ! -d "$pmc_dir/src/main/java" ] && continue
      # Build target pairs filtered to this MC.
      local pmc_targets=()
      local j=0
      local jn=${#T_LOADER[@]}
      while [ $j -lt $jn ]; do
        if [ "${T_MC[$j]}" = "$mc" ]; then
          local sd
          sd=$(subproject_dir "${T_SUBPROJECT[$j]}")
          pmc_targets+=("${T_LOADER[$j]}" "$sd")
        fi
        j=$((j + 1))
      done
      while IFS= read -r -d '' pdir; do
        while IFS= read -r -d '' f; do
          __plat_check_interface "$f" "${pmc_targets[@]}"
        done < <(find "$pdir" -maxdepth 1 -type f -name '*.java' -print0 2>/dev/null)
      done < <(find "$pmc_dir/src/main/java" -type d -name platform -print0 2>/dev/null)
    done
  fi

  if [ $PLAT_FOUND_INTERFACES -eq 0 ]; then
    add_finding "platform-interface-impl-coverage" "hard_fail" "skip" "" "" \
      "skipped: no public interfaces found under any common/.../platform/" ""
    add_finding "services-meta-inf-registration" "hard_fail" "skip" "" "" \
      "skipped: no interfaces under any common/.../platform/ to register" ""
    return 0
  fi

  if [ $PLAT_ANY_COVERAGE_FAIL -eq 0 ]; then
    local scope="common/.../platform/"
    [ "$MULTI_MC" = "1" ] && scope="every common/.../platform/ (top-level + per-MC)"
    add_finding "platform-interface-impl-coverage" "hard_fail" "pass" "" "" \
      "every $scope interface has an impl in each applicable loader subproject" ""
  fi
  if [ $PLAT_ANY_SERVICES_FAIL -eq 0 ]; then
    add_finding "services-meta-inf-registration" "hard_fail" "pass" "" "" \
      "every platform interface has a valid META-INF/services/ registration per loader" ""
  fi
}

# ----------------------------------------------------------------------------
# Check 4: common-no-loader-deps
# ----------------------------------------------------------------------------

check_common_no_loader_deps() {
  if ! is_any_multiloader; then
    add_finding "common-no-loader-deps" "hard_fail" "skip" "" "" \
      "skipped: layout=$LAYOUT (multiloader-only check)" ""
    return 0
  fi

  # Gather every common build.gradle to inspect:
  #   - top-level :common
  #   - per-MC :versions:<mc>:common (multi-MC only)
  local files=()
  local labels=()
  local common_dir
  common_dir=$(subproject_dir "$COMMON_SUBPROJECT")
  if [ -n "$common_dir" ]; then
    local f
    f=$(subproject_build_file "$common_dir")
    if [ -n "$f" ]; then
      files+=("$f")
      labels+=("$common_dir")
    fi
  fi
  if [ "$MULTI_MC" = "1" ]; then
    local k=0
    local m=${#MC_COMMON_MC[@]}
    while [ $k -lt $m ]; do
      local sub="${MC_COMMON_SUBPROJECT[$k]}"
      k=$((k + 1))
      local d; d=$(subproject_dir "$sub")
      [ -z "$d" ] && continue
      local bf; bf=$(subproject_build_file "$d")
      [ -n "$bf" ] && { files+=("$bf"); labels+=("$d"); }
    done
  fi

  if [ ${#files[@]} -eq 0 ]; then
    add_finding "common-no-loader-deps" "hard_fail" "skip" "" "" \
      "skipped: no :common or :versions:<mc>:common build files found" ""
    return 0
  fi

  local any=0
  local idx=0
  while [ $idx -lt ${#files[@]} ]; do
    local f="${files[$idx]}"
    local label="${labels[$idx]}"
    idx=$((idx + 1))
    while IFS=: read -r lineno line; do
      [ -z "$lineno" ] && continue
      local msg="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      add_finding "common-no-loader-deps" "hard_fail" "fail" \
        "$f" "$lineno" \
        "$label/ declares a loader runtime dep: $msg" \
        "Move loader dependencies to fabric/ or neoforge/ build files; common/ depends only on Mojmap MC + Java"
      any=1
    done < <(strip_gradle_comments "$f" | \
              grep -nE '(modImplementation|implementation).*(fabric-loader|fabric-api|net\.neoforged:neoforge|net\.neoforged\.fancymodloader|net\.fabricmc:fabric)' \
              2>/dev/null || true)
  done

  if [ $any -eq 0 ]; then
    local scope="common/build.gradle"
    [ "$MULTI_MC" = "1" ] && scope="every common/build.gradle (top-level + per-MC)"
    add_finding "common-no-loader-deps" "hard_fail" "pass" "" "" \
      "$scope does not depend on loader runtimes" ""
  fi
}

# ----------------------------------------------------------------------------
# Check 5: gradle-properties-source-of-truth
#
# Walk every subproject build.gradle(.kts). Any line that mentions
# minecraft / neoforge / fabric-loader / fabric-api / forge AND contains a
# bare version literal (e.g. `"1.21.1"`, `'26.1.2'`, `version "20.1.2"`)
# instead of a `project.foo_version` / `${foo_version}` reference is a fail.
#
# Loom/MDG plugin-id pins are explicitly allowed (and skipped).
# ----------------------------------------------------------------------------

check_gradle_props_source_of_truth() {
  local any=0
  local checked=0
  # Targets we walk for this check.
  local files=()
  local i=0
  local n=${#T_SUBPROJECT[@]}
  while [ $i -lt $n ]; do
    local subdir
    subdir=$(subproject_dir "${T_SUBPROJECT[$i]}")
    i=$((i + 1))
    [ -z "$subdir" ] && continue
    local f
    f=$(subproject_build_file "$subdir")
    [ -n "$f" ] && files+=("$f")
  done
  # Include common (both flat multiloader and multi-MC).
  if is_any_multiloader; then
    local cdir
    cdir=$(subproject_dir "$COMMON_SUBPROJECT")
    if [ -n "$cdir" ]; then
      local cf
      cf=$(subproject_build_file "$cdir")
      [ -n "$cf" ] && files+=("$cf")
    fi
  fi
  # Include per-MC :versions:<mc>:common build files in multi-MC mode.
  if [ "$MULTI_MC" = "1" ]; then
    local k=0
    local m=${#MC_COMMON_MC[@]}
    while [ $k -lt $m ]; do
      local sub="${MC_COMMON_SUBPROJECT[$k]}"
      k=$((k + 1))
      local d; d=$(subproject_dir "$sub")
      [ -z "$d" ] && continue
      local bf; bf=$(subproject_build_file "$d")
      [ -n "$bf" ] && files+=("$bf")
    done
  fi

  if [ ${#files[@]} -eq 0 ]; then
    add_finding "gradle-properties-source-of-truth" "hard_fail" "skip" "" "" \
      "skipped: no subproject build files found" ""
    return 0
  fi

  for f in "${files[@]}"; do
    checked=1
    # Walk every line with line number; flag those that look like
    # version-pinned dependency declarations.
    while IFS=: read -r lineno line; do
      [ -z "$lineno" ] && continue
      # Allow plugin id pins explicitly: `id '...' version '...'` /
      # `id("...") version "..."` — these are infrastructure.
      if printf '%s' "$line" | grep -qE 'id[[:space:]]*[(]?[[:space:]]*[\x27"]'; then
        continue
      fi
      # Allow lines that already reference a project property via the
      # MC-suffixed scheme (`project.findProperty('mc_version_1_21_1')`),
      # the shorthand `project.<x>_version`, or string interpolation
      # `${<x>_version}` — these are correct, source-of-truth via
      # gradle.properties.
      if printf '%s' "$line" | grep -qE '(project\.findProperty|project\.[A-Za-z_][A-Za-z0-9_]*|\$\{[A-Za-z_][A-Za-z0-9_]*\})'; then
        continue
      fi
      local raw="$line"
      # Strip optional opening `dependencies { ... }` wrapper noise.
      # Lines we care about look like one of:
      #   modImplementation "net.fabricmc:fabric-loader:0.18.6"
      #   implementation "net.fabricmc.fabric-api:fabric-api:0.145.4+26.1.2"
      #   implementation "curse.maven:trinkets-219475:6038854"
      #   neoForge.version = "26.1.2.43-beta"
      #   minecraft "com.mojang:minecraft:1.21.1"
      if printf '%s' "$line" | grep -qE '(minecraft|neoforge|fabric-loader|fabric-api|fabricmc|neoforged|forge|moddev|loom)' && \
         printf '%s' "$line" | grep -qE '[\x27"][^[\x27"]*:[0-9]+\.[0-9]+'; then
        # Looks like a `group:artifact:version` literal with version digits.
        local msg
        msg=$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        add_finding "gradle-properties-source-of-truth" "hard_fail" "fail" \
          "$f" "$lineno" \
          "hardcoded version in subproject: $msg" \
          "Move the version to root gradle.properties (e.g. minecraft_version=...) and reference it via project.<x>_version"
        any=1
        continue
      fi
      # Loose pattern: `(neoForge|loom|fabric).version = "<digits>.<digits>...`
      if printf '%s' "$line" | grep -qE '(version|setVersion)[[:space:]]*[=(][[:space:]]*[\x27"][0-9]+\.[0-9]+'; then
        local msg
        msg=$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        add_finding "gradle-properties-source-of-truth" "hard_fail" "fail" \
          "$f" "$lineno" \
          "hardcoded version assignment in subproject: $msg" \
          "Replace with project.<x>_version and define <x>_version in root gradle.properties"
        any=1
      fi
    done < <(strip_gradle_comments "$f" | nl -ba -s: 2>/dev/null | sed 's/^[[:space:]]*//' || true)
  done

  if [ $checked -eq 1 ] && [ $any -eq 0 ]; then
    add_finding "gradle-properties-source-of-truth" "hard_fail" "pass" "" "" \
      "no hardcoded mod-dependency versions in subproject build files" ""
  fi
}

# ----------------------------------------------------------------------------
# Check 6: neoforge-mods-toml-name
# ----------------------------------------------------------------------------

check_neoforge_mods_toml_name() {
  # Scan any NeoForge subproject resource path (multiloader OR single-loader).
  local searched=0
  local any_old=0
  local any_new=0

  # Build list of NeoForge subprojects to inspect.
  local nf_dirs=()
  local i=0
  local n=${#T_LOADER[@]}
  while [ $i -lt $n ]; do
    if [ "${T_LOADER[$i]}" = "neoforge" ]; then
      local d
      d=$(subproject_dir "${T_SUBPROJECT[$i]}")
      [ -n "$d" ] && nf_dirs+=("$d")
    fi
    i=$((i + 1))
  done
  # Also handle single-loader root (subproject ":").
  if [ ${#nf_dirs[@]} -eq 0 ]; then
    add_finding "neoforge-mods-toml-name" "hard_fail" "skip" "" "" \
      "skipped: no NeoForge target detected in this repo" ""
    return 0
  fi

  local d
  for d in "${nf_dirs[@]}"; do
    searched=1
    if [ -f "$d/src/main/resources/META-INF/mods.toml" ]; then
      add_finding "neoforge-mods-toml-name" "hard_fail" "fail" \
        "$d/src/main/resources/META-INF/mods.toml" "" \
        "found mods.toml — the pre-26.x name; current NeoForge requires neoforge.mods.toml" \
        "Rename mods.toml to neoforge.mods.toml at the same path (file contents are unchanged)"
      any_old=1
    fi
    if [ -f "$d/src/main/resources/META-INF/neoforge.mods.toml" ]; then
      any_new=1
    fi
  done

  if [ $searched -eq 1 ] && [ $any_old -eq 0 ]; then
    if [ $any_new -eq 1 ]; then
      add_finding "neoforge-mods-toml-name" "hard_fail" "pass" "" "" \
        "NeoForge manifest is named neoforge.mods.toml (correct)" ""
    else
      add_finding "neoforge-mods-toml-name" "hard_fail" "fail" "" "" \
        "no neoforge.mods.toml or mods.toml found in any NeoForge subproject" \
        "Create neoforge/src/main/resources/META-INF/neoforge.mods.toml (or the equivalent for single-loader root)"
    fi
  fi
}

# ----------------------------------------------------------------------------
# Check 7: java-toolchain-matches-mc
# ----------------------------------------------------------------------------

check_java_toolchain() {
  local n=${#T_LOADER[@]}
  if [ "$n" -eq 0 ]; then
    add_finding "java-toolchain-matches-mc" "hard_fail" "skip" "" "" \
      "skipped: no targets detected" ""
    return 0
  fi
  local any=0
  local checked=0
  local i=0
  while [ $i -lt $n ]; do
    local loader="${T_LOADER[$i]}"
    local mc="${T_MC[$i]}"
    local java="${T_JAVA[$i]}"
    local subdir
    subdir=$(subproject_dir "${T_SUBPROJECT[$i]}")
    i=$((i + 1))

    [ -z "$mc" ] && continue
    local expected
    expected=$(expected_java_for_mc "$mc")
    if [ -z "$expected" ]; then
      add_finding "java-toolchain-matches-mc" "hard_fail" "skip" "" "" \
        "skipped for $loader: no java-toolchain convention for MC $mc" ""
      continue
    fi
    checked=1
    if [ -z "$java" ]; then
      add_finding "java-toolchain-matches-mc" "hard_fail" "fail" \
        "$subdir/build.gradle" "" \
        "$loader ($mc): no java_version pin found; expected Java $expected" \
        "Set java_version=$expected in gradle.properties (or declare a toolchain block in build.gradle)"
      any=1
    elif [ "$java" != "$expected" ]; then
      add_finding "java-toolchain-matches-mc" "hard_fail" "fail" \
        "$subdir/build.gradle" "" \
        "$loader ($mc): java_version=$java but MC $mc requires Java $expected" \
        "Set java_version=$expected in gradle.properties to match MC $mc"
      any=1
    fi
  done
  if [ $checked -eq 1 ] && [ $any -eq 0 ]; then
    add_finding "java-toolchain-matches-mc" "hard_fail" "pass" "" "" \
      "Java toolchain matches the MC version for every detected target" ""
  fi
}

# ----------------------------------------------------------------------------
# Check 8: fabric-refmap-enabled-neoforge-disabled
# ----------------------------------------------------------------------------

check_refmap_config() {
  if ! is_any_multiloader; then
    add_finding "fabric-refmap-enabled-neoforge-disabled" "hard_fail" "skip" "" "" \
      "skipped: layout=$LAYOUT (multiloader-only check)" ""
    return 0
  fi
  local any=0
  local checked=0

  # Walk every fabric/neoforge target.
  local i=0
  local n=${#T_LOADER[@]}
  while [ $i -lt $n ]; do
    local loader="${T_LOADER[$i]}"
    local subdir
    subdir=$(subproject_dir "${T_SUBPROJECT[$i]}")
    i=$((i + 1))
    [ -z "$subdir" ] && continue
    local bf
    bf=$(subproject_build_file "$subdir")
    [ -z "$bf" ] && continue

    if [ "$loader" = "fabric" ]; then
      checked=1
      while IFS=: read -r lineno line; do
        [ -z "$lineno" ] && continue
        local msg
        msg=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        add_finding "fabric-refmap-enabled-neoforge-disabled" "hard_fail" "fail" \
          "$bf" "$lineno" \
          "Fabric build ($subdir) disables Loom's default mixin refmap behavior: $msg" \
          "Remove this line; Fabric requires the refmap to apply mixins in dev + prod"
        any=1
      done < <(strip_gradle_comments "$bf" | \
        grep -nE '(useLegacyMixinAp[[:space:]]*=[[:space:]]*false|refmap[[:space:]]*=[[:space:]]*false|noRefmap[[:space:]]*[=(])' \
        2>/dev/null || true)
    elif [ "$loader" = "neoforge" ]; then
      checked=1
      while IFS=: read -r lineno line; do
        [ -z "$lineno" ] && continue
        local msg
        msg=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        add_finding "fabric-refmap-enabled-neoforge-disabled" "hard_fail" "fail" \
          "$bf" "$lineno" \
          ":neoforge subproject ($subdir) applies a Loom plugin, which would emit refmap mappings that NeoForge cannot consume: $msg" \
          "Remove the fabric-loom plugin from $subdir/build.gradle — only ModDevGradle (net.neoforged.moddev) belongs here"
        any=1
      done < <(strip_gradle_comments "$bf" | \
        grep -nE "(net\.fabricmc\.fabric-loom|['\"]fabric-loom['\"]|dev\.architectury\.loom)" \
        2>/dev/null || true)
    fi
  done

  if [ $checked -eq 1 ] && [ $any -eq 0 ]; then
    add_finding "fabric-refmap-enabled-neoforge-disabled" "hard_fail" "pass" "" "" \
      "Loom refmap behavior is preserved on every Fabric subproject; no Loom plugin on any NeoForge subproject" ""
  elif [ $checked -eq 0 ]; then
    add_finding "fabric-refmap-enabled-neoforge-disabled" "hard_fail" "skip" "" "" \
      "skipped: no fabric or neoforge build files found" ""
  fi
}

# ----------------------------------------------------------------------------
# Check 9: mixin-config-references
# ----------------------------------------------------------------------------

check_mixin_config_references() {
  # Find every *.mixins.json. For each, see if it's listed in a loader manifest.
  # Multi-MC: a mixins.json under versions/<mc>/ must be referenced from a
  # manifest under the SAME versions/<mc>/ subtree (or from a top-level common
  # manifest, which doesn't actually exist in our scaffolds, but be lenient).
  local any=0
  local checked=0

  while IFS= read -r -d '' mixin; do
    checked=1
    local base
    base=$(basename "$mixin")
    # Determine the per-MC scope, if any. If the mixin path matches
    # ./versions/<mc>/..., we'll constrain manifest search to that subtree.
    local mc_scope=""
    case "$mixin" in
      ./versions/*/*|versions/*/*)
        # Strip leading "./", then take "versions/<mc>/".
        local p="${mixin#./}"
        mc_scope="${p#versions/}"
        mc_scope="${mc_scope%%/*}"
        ;;
    esac

    local referenced=0
    local fm_root="."
    if [ -n "$mc_scope" ] && [ "$MULTI_MC" = "1" ]; then
      fm_root="./versions/$mc_scope"
    fi

    while IFS= read -r -d '' fm; do
      if grep -qF "\"$base\"" "$fm" 2>/dev/null; then
        referenced=1
        break
      fi
    done < <(find "$fm_root" \( -path '*/build/*' -o -path '*/.gradle/*' -o -path '*/.git/*' -o -path '*/node_modules/*' \) -prune \
              -o -type f -name 'fabric.mod.json' -print0 \
              2>/dev/null)

    if [ $referenced -eq 0 ]; then
      while IFS= read -r -d '' nf; do
        # NeoForge manifests reference mixins under `[[mixins]] config = "..."`.
        if grep -qE "config[[:space:]]*=[[:space:]]*[\"']${base}[\"']" "$nf" 2>/dev/null; then
          referenced=1
          break
        fi
      done < <(find "$fm_root" \( -path '*/build/*' -o -path '*/.gradle/*' -o -path '*/.git/*' -o -path '*/node_modules/*' \) -prune \
                -o -type f \( -name 'neoforge.mods.toml' -o -name 'mods.toml' \) -print0 \
                2>/dev/null)
    fi

    if [ $referenced -eq 0 ]; then
      local where="any loader manifest"
      [ -n "$mc_scope" ] && [ "$MULTI_MC" = "1" ] && where="any loader manifest under versions/$mc_scope/"
      add_finding "mixin-config-references" "hard_fail" "fail" \
        "$mixin" "" \
        "$base is not referenced from $where" \
        "Add \"$base\" to the fabric.mod.json mixins array, or a [[mixins]] config=\"$base\" entry in neoforge.mods.toml (per-MC manifests for multi-MC)"
      any=1
    fi
  done < <(find . \( -path '*/build/*' -o -path '*/.gradle/*' -o -path '*/.git/*' -o -path '*/node_modules/*' \) -prune \
            -o -type f -name '*.mixins.json' -print0 \
            2>/dev/null)

  if [ $checked -eq 0 ]; then
    add_finding "mixin-config-references" "hard_fail" "skip" "" "" \
      "skipped: no *.mixins.json files in the repo" ""
  elif [ $any -eq 0 ]; then
    add_finding "mixin-config-references" "hard_fail" "pass" "" "" \
      "every mixin config is referenced from a loader manifest" ""
  fi
}

# ----------------------------------------------------------------------------
# Check 10: modid-consistent-across-loaders
# ----------------------------------------------------------------------------

check_modid_consistent() {
  # Multi-MC: walk every (mc, loader) manifest, verify they all share one modid.
  if [ "$MULTI_MC" = "1" ]; then
    local rootid; rootid=$(detect_root_modid)
    local first_id=""
    local first_src=""
    local any_fail=0
    local checked=0
    local i=0
    local n=${#T_LOADER[@]}
    while [ $i -lt $n ]; do
      local loader="${T_LOADER[$i]}"
      local subdir
      subdir=$(subproject_dir "${T_SUBPROJECT[$i]}")
      local mc="${T_MC[$i]}"
      i=$((i + 1))
      [ -z "$subdir" ] && continue
      local manifest=""
      local mid=""
      if [ "$loader" = "fabric" ] && [ -f "$subdir/src/main/resources/fabric.mod.json" ]; then
        manifest="$subdir/src/main/resources/fabric.mod.json"
        mid=$(read_json_string_field "$manifest" "id")
      elif [ "$loader" = "neoforge" ] || [ "$loader" = "forge" ]; then
        if [ -f "$subdir/src/main/resources/META-INF/neoforge.mods.toml" ]; then
          manifest="$subdir/src/main/resources/META-INF/neoforge.mods.toml"
        elif [ -f "$subdir/src/main/resources/META-INF/mods.toml" ]; then
          manifest="$subdir/src/main/resources/META-INF/mods.toml"
        fi
        if [ -n "$manifest" ]; then
          mid=$(read_toml_modid "$manifest")
        fi
      fi
      [ -z "$manifest" ] && continue
      # NeoForge mods.toml may use ${mod_id} — treat that as "matches".
      if printf '%s' "$mid" | grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*\}'; then
        continue
      fi
      [ -z "$mid" ] && continue
      checked=1
      if [ -z "$first_id" ]; then
        first_id="$mid"
        first_src="$manifest"
      elif [ "$first_id" != "$mid" ]; then
        add_finding "modid-consistent-across-loaders" "hard_fail" "fail" \
          "$manifest" "" \
          "modid mismatch: $manifest modId=$mid but $first_src had $first_id (multi-MC: all manifests across MC × loader pairs must agree)" \
          "Pick a single modid and update every per-MC, per-loader manifest"
        any_fail=1
      fi
    done
    # Optional: gradle.properties modid match.
    if [ -n "$rootid" ] && [ -n "$first_id" ] && [ "$rootid" != "$first_id" ]; then
      add_finding "modid-consistent-across-loaders" "hard_fail" "fail" \
        "gradle.properties" "" \
        "gradle.properties modid=$rootid does not match manifest modid=$first_id" \
        "Reconcile gradle.properties' modid with the manifests"
      any_fail=1
    fi
    if [ $checked -eq 0 ]; then
      add_finding "modid-consistent-across-loaders" "hard_fail" "skip" "" "" \
        "skipped: no per-MC manifests found (or all use \${mod_id} placeholder)" ""
      return 0
    fi
    if [ $any_fail -eq 0 ]; then
      add_finding "modid-consistent-across-loaders" "hard_fail" "pass" "" "" \
        "modid consistent across every (MC, loader) pair ($first_id)" ""
    fi
    return 0
  fi

  # Find each loader's manifest, extract its modid, compare.
  local fdir ndir
  fdir=$(loader_dir "fabric")
  ndir=$(loader_dir "neoforge")

  if [ "$LAYOUT" = "multiloader" ]; then
    local fabric_manifest=""
    local neoforge_manifest=""
    if [ -n "$fdir" ]; then
      if [ -f "$fdir/src/main/resources/fabric.mod.json" ]; then
        fabric_manifest="$fdir/src/main/resources/fabric.mod.json"
      fi
    fi
    if [ -n "$ndir" ]; then
      if [ -f "$ndir/src/main/resources/META-INF/neoforge.mods.toml" ]; then
        neoforge_manifest="$ndir/src/main/resources/META-INF/neoforge.mods.toml"
      elif [ -f "$ndir/src/main/resources/META-INF/mods.toml" ]; then
        neoforge_manifest="$ndir/src/main/resources/META-INF/mods.toml"
      fi
    fi
    if [ -z "$fabric_manifest" ] || [ -z "$neoforge_manifest" ]; then
      add_finding "modid-consistent-across-loaders" "hard_fail" "skip" "" "" \
        "skipped: one or both loader manifests missing (fabric=$fabric_manifest neoforge=$neoforge_manifest)" \
        ""
      return 0
    fi
    local fid
    fid=$(read_json_string_field "$fabric_manifest" "id")
    local nid
    nid=$(read_toml_modid "$neoforge_manifest")
    if [ -z "$fid" ] || [ -z "$nid" ]; then
      add_finding "modid-consistent-across-loaders" "hard_fail" "fail" \
        "$fabric_manifest" "" \
        "could not extract modid from one of the manifests (fabric=$fid neoforge=$nid)" \
        "Ensure fabric.mod.json has a top-level \"id\": \"...\" and neoforge.mods.toml has modId = \"...\""
      return 0
    fi
    if [ "$fid" != "$nid" ]; then
      add_finding "modid-consistent-across-loaders" "hard_fail" "fail" \
        "$fabric_manifest" "" \
        "modid mismatch: fabric.mod.json#id=$fid but neoforge.mods.toml modId=$nid" \
        "Pick a single modid and update both manifests to match"
      return 0
    fi
    # Optional: confirm gradle.properties modid (if present) matches.
    local rootid
    rootid=$(detect_root_modid)
    if [ -n "$rootid" ] && [ "$rootid" != "$fid" ]; then
      add_finding "modid-consistent-across-loaders" "hard_fail" "fail" \
        "gradle.properties" "" \
        "gradle.properties modid=$rootid does not match manifest modid=$fid" \
        "Reconcile gradle.properties' modid (or mod_id) with the manifests"
      return 0
    fi
    add_finding "modid-consistent-across-loaders" "hard_fail" "pass" "" "" \
      "modid consistent across loaders ($fid)" ""
    return 0
  fi

  # Single-loader case.
  if [ "$LAYOUT" = "single-loader" ]; then
    local rootid
    rootid=$(detect_root_modid)
    if [ -z "$rootid" ]; then
      add_finding "modid-consistent-across-loaders" "hard_fail" "skip" "" "" \
        "skipped: no modid declared in gradle.properties" ""
      return 0
    fi
    # Find the (single) loader manifest.
    local i=0
    local n=${#T_LOADER[@]}
    while [ $i -lt $n ]; do
      local loader="${T_LOADER[$i]}"
      local subdir
      subdir=$(subproject_dir "${T_SUBPROJECT[$i]}")
      i=$((i + 1))
      [ -z "$subdir" ] && continue
      if [ "$loader" = "fabric" ]; then
        local f="$subdir/src/main/resources/fabric.mod.json"
        if [ -f "$f" ]; then
          local fid
          fid=$(read_json_string_field "$f" "id")
          if [ -n "$fid" ] && [ "$fid" != "$rootid" ]; then
            add_finding "modid-consistent-across-loaders" "hard_fail" "fail" \
              "$f" "" \
              "fabric.mod.json#id=$fid does not match gradle.properties modid=$rootid" \
              "Align fabric.mod.json#id with gradle.properties (or update gradle.properties)"
            return 0
          fi
        fi
      elif [ "$loader" = "neoforge" ] || [ "$loader" = "forge" ]; then
        local nf=""
        if [ -f "$subdir/src/main/resources/META-INF/neoforge.mods.toml" ]; then
          nf="$subdir/src/main/resources/META-INF/neoforge.mods.toml"
        elif [ -f "$subdir/src/main/resources/META-INF/mods.toml" ]; then
          nf="$subdir/src/main/resources/META-INF/mods.toml"
        fi
        if [ -n "$nf" ]; then
          local nid
          nid=$(read_toml_modid "$nf")
          # NeoForge mods.toml may be templated with ${mod_id} (resolved
          # at runtime). Accept that as a non-failure here.
          if [ -n "$nid" ] && [ "$nid" != "$rootid" ] \
             && ! printf '%s' "$nid" | grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*\}'; then
            add_finding "modid-consistent-across-loaders" "hard_fail" "fail" \
              "$nf" "" \
              "neoforge.mods.toml modId=$nid does not match gradle.properties modid=$rootid" \
              "Align modId with gradle.properties (or use \${mod_id} for runtime expansion)"
            return 0
          fi
        fi
      fi
    done
    add_finding "modid-consistent-across-loaders" "hard_fail" "pass" "" "" \
      "modid matches gradle.properties ($rootid)" ""
    return 0
  fi

  add_finding "modid-consistent-across-loaders" "hard_fail" "skip" "" "" \
    "skipped: layout=$LAYOUT" ""
}

# ----------------------------------------------------------------------------
# Check 11: pack-mcmeta-present-if-assets-or-data (warn)
# ----------------------------------------------------------------------------

check_pack_mcmeta_present() {
  local checked=0
  local any=0
  # We look at each subproject's resources directory (single-loader uses ".").
  local dirs=()
  local i=0
  local n=${#T_SUBPROJECT[@]}
  while [ $i -lt $n ]; do
    local d
    d=$(subproject_dir "${T_SUBPROJECT[$i]}")
    [ -n "$d" ] && dirs+=("$d")
    i=$((i + 1))
  done
  if is_any_multiloader; then
    local cdir
    cdir=$(subproject_dir "$COMMON_SUBPROJECT")
    [ -n "$cdir" ] && dirs+=("$cdir")
  fi
  if [ "$MULTI_MC" = "1" ]; then
    local k=0
    local m=${#MC_COMMON_MC[@]}
    while [ $k -lt $m ]; do
      local sub="${MC_COMMON_SUBPROJECT[$k]}"
      k=$((k + 1))
      local d; d=$(subproject_dir "$sub")
      [ -n "$d" ] && dirs+=("$d")
    done
  fi
  if [ ${#dirs[@]} -eq 0 ]; then
    add_finding "pack-mcmeta-present-if-assets-or-data" "warn" "skip" "" "" \
      "skipped: no subprojects to inspect" ""
    return 0
  fi
  local d
  for d in "${dirs[@]}"; do
    local r="$d/src/main/resources"
    [ ! -d "$r" ] && continue
    # Are there any assets/<modid>/ or data/<modid>/ children?
    local has_content=0
    # `-print -quit` exits find early → SIGPIPE on the grep side. Subshell wraps.
    if [ -d "$r/assets" ] && ( find "$r/assets" -mindepth 2 -type f -print -quit 2>/dev/null | grep -q . ); then
      has_content=1
    fi
    if [ -d "$r/data" ] && ( find "$r/data" -mindepth 2 -type f -print -quit 2>/dev/null | grep -q . ); then
      has_content=1
    fi
    if [ $has_content -eq 1 ]; then
      checked=1
      if [ ! -f "$r/pack.mcmeta" ]; then
        add_finding "pack-mcmeta-present-if-assets-or-data" "warn" "fail" \
          "$r" "" \
          "$r has assets/ or data/ content but no pack.mcmeta" \
          "Add $r/pack.mcmeta with {\"pack\":{\"pack_format\":<N>,\"description\":\"<mod name>\"}}; pack_format depends on MC version"
        any=1
      fi
    fi
  done
  if [ $checked -eq 1 ] && [ $any -eq 0 ]; then
    add_finding "pack-mcmeta-present-if-assets-or-data" "warn" "pass" "" "" \
      "all assets/data directories have a sibling pack.mcmeta" ""
  elif [ $checked -eq 0 ]; then
    add_finding "pack-mcmeta-present-if-assets-or-data" "warn" "skip" "" "" \
      "skipped: no assets/<modid>/ or data/<modid>/ content found" ""
  fi
}

# ----------------------------------------------------------------------------
# Check 12: pinned-versions-fresh (warn, best-effort)
#
# Queries the loader version metadata APIs. If offline or the query fails,
# we silently skip rather than fail — this is informational.
# ----------------------------------------------------------------------------

http_fetch() {
  local url="$1"
  local out
  out=$(curl -sfL --max-time 5 "$url" 2>/dev/null) || return 1
  printf '%s' "$out"
}

check_pinned_versions_fresh() {
  local n=${#T_LOADER[@]}
  if [ "$n" -eq 0 ]; then
    add_finding "pinned-versions-fresh" "warn" "skip" "" "" \
      "skipped: no targets detected" ""
    return 0
  fi
  # Quick offline probe — if we can't reach a tiny endpoint in 2s, bail.
  if ! curl -sfL --max-time 2 -o /dev/null "https://meta.fabricmc.net/v2/versions/game" 2>/dev/null \
     && ! curl -sfL --max-time 2 -o /dev/null "https://maven.neoforged.net/releases" 2>/dev/null; then
    add_finding "pinned-versions-fresh" "warn" "skip" "" "" \
      "skipped: version-metadata APIs unreachable (offline?)" ""
    return 0
  fi
  local any=0
  local checked=0
  local i=0
  while [ $i -lt $n ]; do
    local loader="${T_LOADER[$i]}"
    local mc="${T_MC[$i]}"
    local lver="${T_LVER[$i]}"
    i=$((i + 1))
    [ -z "$loader" ] && continue
    # In multi-MC, surface the MC line in the message and reference the
    # suffixed gradle.properties key in the hint.
    local mc_label=""
    local suffix=""
    if [ "$MULTI_MC" = "1" ] && [ -n "$mc" ]; then
      mc_label=" (MC $mc)"
      suffix="_$(mc_suffix "$mc")"
    fi
    case "$loader" in
      fabric)
        # Fetch the loader stable list. Match the first "version":"X.Y.Z" out of the JSON.
        local body
        body=$(http_fetch "https://meta.fabricmc.net/v2/versions/loader") || continue
        # Pipe-to-awk-with-exit triggers SIGPIPE → set -o pipefail trips. Use
        # a tempfile-free workaround: print all matches, take the first.
        local latest
        latest=$(awk 'BEGIN{RS=","} /"version":/ {
          v = $0
          sub(/.*"version":"/, "", v)
          sub(/".*/, "", v)
          print v
        }' <<< "$body" | head -1) || true
        checked=1
        if [ -n "$latest" ] && [ -n "$lver" ] && [ "$latest" != "$lver" ]; then
          add_finding "pinned-versions-fresh" "warn" "fail" \
            "gradle.properties" "" \
            "Fabric loader pinned at $lver${mc_label}; latest is $latest" \
            "Bump fabric_loader_version${suffix} to $latest (or recent enough)"
          any=1
        fi
        ;;
      neoforge)
        # Hit NeoForge's maven-metadata for the neoforge artifact.
        local body
        body=$(http_fetch "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml") || continue
        local latest
        latest=$(awk '/<latest>/ {
          v = $0
          sub(/.*<latest>/, "", v)
          sub(/<\/latest>.*/, "", v)
          print v
        }' <<< "$body" | head -1) || true
        checked=1
        if [ -n "$latest" ] && [ -n "$lver" ] && [ "$latest" != "$lver" ]; then
          # Compare on the major+minor prefix; if user has 26.1.2.43 and
          # latest is 26.1.2.99, we surface it; if the major differs (still
          # 26.1.x), that's a regular bump suggestion.
          add_finding "pinned-versions-fresh" "warn" "fail" \
            "gradle.properties" "" \
            "NeoForge pinned at $lver${mc_label}; latest is $latest" \
            "Bump neoforge_version${suffix} to $latest (or recent enough; check release notes for breaking changes)"
          any=1
        fi
        ;;
      *)
        ;;
    esac
  done
  if [ $checked -eq 1 ] && [ $any -eq 0 ]; then
    add_finding "pinned-versions-fresh" "warn" "pass" "" "" \
      "pinned loader versions are at the latest published release" ""
  elif [ $checked -eq 0 ]; then
    add_finding "pinned-versions-fresh" "warn" "skip" "" "" \
      "skipped: could not query loader version metadata for any target" ""
  fi
}

# ----------------------------------------------------------------------------
# Check 13: forge-deps-via-modimplementation
#
# In Fabric build.gradle files, mod artifacts from CurseForge / Modrinth
# must use `modImplementation` (not raw `implementation`). NeoForge's MDG
# transforms classpath deps at the plugin level so the rule is Fabric-only.
# ----------------------------------------------------------------------------

check_forge_deps_via_modimpl() {
  # Walk every Fabric build file detected in the matrix (one per (mc, fabric)
  # pair in multi-MC; one in single-MC multiloader; potentially the root in
  # single-loader fabric). The antipattern is the same across all of them.
  local files=()
  local i=0
  local n=${#T_LOADER[@]}
  while [ $i -lt $n ]; do
    if [ "${T_LOADER[$i]}" = "fabric" ]; then
      local d
      d=$(subproject_dir "${T_SUBPROJECT[$i]}")
      if [ -n "$d" ]; then
        local bf
        bf=$(subproject_build_file "$d")
        [ -n "$bf" ] && files+=("$bf")
      fi
    fi
    i=$((i + 1))
  done

  if [ ${#files[@]} -eq 0 ]; then
    add_finding "forge-deps-via-modimplementation" "hard_fail" "skip" "" "" \
      "skipped: no Fabric target detected" ""
    return 0
  fi

  local any=0
  local fb
  for fb in "${files[@]}"; do
    while IFS=: read -r lineno line; do
      [ -z "$lineno" ] && continue
      # Skip lines that already use modImplementation / modApi etc.
      if printf '%s' "$line" | grep -qE '^\s*(modImplementation|modApi|modRuntimeOnly|modCompileOnly)'; then
        continue
      fi
      if ! printf '%s' "$line" | grep -qE '^\s*implementation[[:space:]]'; then
        continue
      fi
      # Look for the mod-jar coordinate signals.
      if printf '%s' "$line" | grep -qE '(curse\.maven|maven\.modrinth|com\.terraformersmc|teamreborn|cottonmc|trinkets|cloth-config|net\.fabricmc\.fabric-api|com\.github\.[A-Za-z]+)'; then
        local msg
        msg=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        add_finding "forge-deps-via-modimplementation" "hard_fail" "fail" \
          "$fb" "$lineno" \
          "Fabric mod-jar dependency uses raw implementation (Loom won't remap): $msg" \
          "Replace 'implementation' with 'modImplementation' so Loom remaps the jar (raw classpath inclusion breaks at runtime)"
        any=1
      fi
    done < <(strip_gradle_comments "$fb" | nl -ba -s: 2>/dev/null | sed 's/^[[:space:]]*//' || true)
  done

  if [ $any -eq 0 ]; then
    add_finding "forge-deps-via-modimplementation" "hard_fail" "pass" "" "" \
      "all Fabric mod-jar dependencies use modImplementation across every Fabric subproject" ""
  fi
}

# ----------------------------------------------------------------------------
# Check 14: AT-AW-parity (warn if either side missing)
# ----------------------------------------------------------------------------

# Returns 0 if the Fabric build file looks like it generates / consumes
# an accesswidener (either has a `generateAccessWidener` task definition
# or sets `accessWidenerPath` / references a `.accesswidener` file).
__fabric_has_aw_pipeline() {
  local fb="$1"
  [ -f "$fb" ] || return 1
  grep -qE '(generateAccessWidener|accessWidenerPath|\.accesswidener)' "$fb"
}

# Returns the first *.accesswidener file in a fabric subproject's source
# resources (top-level, max-depth 1). Empty if none.
__fabric_aw_file() {
  local fdir="$1"
  [ -d "$fdir/src/main/resources" ] || return 0
  find "$fdir/src/main/resources" -maxdepth 1 -type f -name '*.accesswidener' 2>/dev/null | head -1
  return 0
}

# Inner helper: given a triple (cdir, fdir, ndir), evaluate parity and
# add a finding. Used both for single-MC multiloader and once per MC for
# multi-MC.
__at_aw_eval_one() {
  local label="$1"
  local cdir="$2"
  local fdir="$3"
  local ndir="$4"

  local at_path=""
  if [ -n "$cdir" ] && [ -f "$cdir/src/main/resources/META-INF/accesstransformer.cfg" ]; then
    at_path="$cdir/src/main/resources/META-INF/accesstransformer.cfg"
  elif [ -n "$ndir" ] && [ -f "$ndir/src/main/resources/META-INF/accesstransformer.cfg" ]; then
    at_path="$ndir/src/main/resources/META-INF/accesstransformer.cfg"
  fi
  local aw_path=""
  [ -n "$fdir" ] && aw_path=$(__fabric_aw_file "$fdir")
  local fab_build=""
  [ -n "$fdir" ] && fab_build=$(subproject_build_file "$fdir")
  local aw_pipeline=0
  if [ -n "$fab_build" ] && __fabric_has_aw_pipeline "$fab_build"; then
    aw_pipeline=1
  fi

  if [ -z "$at_path" ] && [ -z "$aw_path" ] && [ $aw_pipeline -eq 0 ]; then
    add_finding "AT-AW-parity" "warn" "skip" "" "" \
      "skipped${label}: neither accesstransformer.cfg nor *.accesswidener nor an AW build pipeline present" ""
    return 0
  fi

  if [ -n "$at_path" ] && [ -z "$aw_path" ] && [ $aw_pipeline -eq 0 ]; then
    add_finding "AT-AW-parity" "warn" "fail" \
      "$at_path" "" \
      "accesstransformer.cfg${label} present but no Fabric *.accesswidener (or AT->AW generator task) found" \
      "Add a Gradle task in $fdir/build.gradle that generates <modid>.accesswidener from $at_path (see references/landmines.md)"
    return 0
  fi
  if [ -n "$aw_path" ] && [ -z "$at_path" ]; then
    add_finding "AT-AW-parity" "warn" "fail" \
      "$aw_path" "" \
      "*.accesswidener${label} present but no NeoForge accesstransformer.cfg — NeoForge will not see the access changes" \
      "Author $cdir/src/main/resources/META-INF/accesstransformer.cfg (or neoforge equivalent) and either generate the AW from it or keep both in sync"
    return 0
  fi
  add_finding "AT-AW-parity" "warn" "pass" "" "" \
    "AT and AW are in parity${label}" ""
}

check_at_aw_parity() {
  if ! is_any_multiloader; then
    add_finding "AT-AW-parity" "warn" "skip" "" "" \
      "skipped: layout=$LAYOUT (multiloader-only check)" ""
    return 0
  fi

  if [ "$MULTI_MC" = "1" ]; then
    local mcs
    mcs=$(unique_mcs)
    if [ -z "$mcs" ]; then
      add_finding "AT-AW-parity" "warn" "skip" "" "" \
        "skipped: no MC versions detected in multi-MC layout" ""
      return 0
    fi
    while IFS= read -r mc; do
      [ -z "$mc" ] && continue
      # Resolve per-MC dirs.
      local cdir="versions/$mc/common"; [ -d "$cdir" ] || cdir=""
      local fdir="versions/$mc/fabric"; [ -d "$fdir" ] || fdir=""
      local ndir="versions/$mc/neoforge"; [ -d "$ndir" ] || ndir=""
      __at_aw_eval_one " (MC $mc)" "$cdir" "$fdir" "$ndir"
    done <<< "$mcs"
    return 0
  fi

  # Single-MC multiloader (v0.1.0 behavior).
  local fdir ndir cdir
  fdir=$(loader_dir "fabric")
  ndir=$(loader_dir "neoforge")
  cdir=$(subproject_dir "$COMMON_SUBPROJECT")
  __at_aw_eval_one "" "$cdir" "$fdir" "$ndir"
}

# ----------------------------------------------------------------------------
# Check 15: mod-bus-vs-game-bus-events (info)
#
# Surfaces every @SubscribeEvent location in NeoForge subprojects so the
# user can verify the right bus. We can't reliably know which bus an event
# class extends without resolving types, so this is purely informational.
# ----------------------------------------------------------------------------

check_event_bus_heuristic() {
  local i=0
  local n=${#T_LOADER[@]}
  local emitted=0
  while [ $i -lt $n ]; do
    local loader="${T_LOADER[$i]}"
    local subdir
    subdir=$(subproject_dir "${T_SUBPROJECT[$i]}")
    i=$((i + 1))
    [ "$loader" != "neoforge" ] && [ "$loader" != "forge" ] && continue
    [ -z "$subdir" ] && continue
    [ ! -d "$subdir/src/main/java" ] && continue
    # Sample at most 25 occurrences so this stays cheap.
    while IFS=: read -r path lineno line; do
      [ -z "$lineno" ] && continue
      local msg
      msg=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      add_finding "mod-bus-vs-game-bus-events" "info" "fail" \
        "$path" "$lineno" \
        "@SubscribeEvent here — confirm registration is on the correct bus (mod bus for lifecycle/registry; game bus for gameplay)" \
        "Mod-lifecycle events (FMLClientSetupEvent, RegisterEvent, etc.) belong on modEventBus.addListener / register; game events belong on NeoForge.EVENT_BUS"
      emitted=$((emitted + 1))
      if [ $emitted -ge 25 ]; then
        break
      fi
    done < <(grep -rnE '^[[:space:]]*@SubscribeEvent\b' "$subdir/src/main/java" 2>/dev/null || true)
    [ $emitted -ge 25 ] && break
  done
  if [ $emitted -eq 0 ]; then
    add_finding "mod-bus-vs-game-bus-events" "info" "skip" "" "" \
      "skipped: no @SubscribeEvent annotations found in NeoForge sources" ""
  fi
}

# ----------------------------------------------------------------------------
# Check 16: single-loader-upgrade-suggested (info)
# ----------------------------------------------------------------------------

check_single_loader_upgrade() {
  if [ "$LAYOUT" != "single-loader" ]; then
    add_finding "single-loader-upgrade-suggested" "info" "skip" "" "" \
      "skipped: layout=$LAYOUT" ""
    return 0
  fi
  # We always emit, regardless of which loader they're on.
  local loader=""
  if [ ${#T_LOADER[@]} -gt 0 ]; then
    loader="${T_LOADER[0]}"
  fi
  add_finding "single-loader-upgrade-suggested" "info" "fail" \
    "" "" \
    "this repo is single-loader ($loader); a multi-loader split (Fabric + NeoForge) would broaden reach" \
    "Run /modsmith:develop with task 'migrate to multi-loader' to get a phased decomposition (gradle restructure → registry → events → network → NBT → client). See references/multiloader-layout.md"
}

# ============================================================================
# Multi-MC specific checks (HARD_FAIL, multi-MC only).
# ============================================================================

# ----------------------------------------------------------------------------
# Check 17: top-common-pure-java
#
# Top-level common/src/main/java/ must NOT contain any net.minecraft.* imports.
# This is the load-bearing rule for the multi-MC overlay layout: code that
# references MC types belongs in versions/<mc>/common/ (one copy per MC line),
# because MC APIs diverge across versions.
# ----------------------------------------------------------------------------

check_top_common_pure_java() {
  if [ "$MULTI_MC" != "1" ]; then
    add_finding "top-common-pure-java" "hard_fail" "skip" "" "" \
      "skipped: multi-MC-only check (layout=$LAYOUT)" ""
    return 0
  fi
  local cdir
  cdir=$(subproject_dir "$COMMON_SUBPROJECT")
  if [ -z "$cdir" ] || [ ! -d "$cdir/src/main/java" ]; then
    add_finding "top-common-pure-java" "hard_fail" "skip" "" "" \
      "skipped: no top-level common/src/main/java (multi-MC layout but :common module missing)" ""
    return 0
  fi
  local any_fail=0
  while IFS= read -r -d '' f; do
    while IFS=: read -r lineno line; do
      [ -z "$lineno" ] && continue
      local msg
      msg=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      add_finding "top-common-pure-java" "hard_fail" "fail" \
        "$f" "$lineno" \
        "top-level :common imports MC: $msg — top-level common must be pure Java" \
        "Move this class to versions/<mc>/common/ for each MC version that uses it, OR remove the MC import if the logic can be made MC-agnostic"
      any_fail=1
    done < <(grep -nE '^[[:space:]]*import[[:space:]]+net\.minecraft\.' "$f" 2>/dev/null || true)
  done < <(find "$cdir/src/main/java" -type f -name '*.java' -print0 2>/dev/null)
  if [ $any_fail -eq 0 ]; then
    add_finding "top-common-pure-java" "hard_fail" "pass" "" "" \
      "top-level common/src/main/java has no net.minecraft.* imports (pure Java)" ""
  fi
}

# ----------------------------------------------------------------------------
# Check 18: per-mc-subproject-coverage
#
# For each MC line in the matrix, all three subprojects must exist when the
# user opted into both loaders: versions/<mc>/common, versions/<mc>/fabric,
# versions/<mc>/neoforge. Missing directories suggest a broken scaffold.
# ----------------------------------------------------------------------------

check_per_mc_subproject_coverage() {
  if [ "$MULTI_MC" != "1" ]; then
    add_finding "per-mc-subproject-coverage" "hard_fail" "skip" "" "" \
      "skipped: multi-MC-only check (layout=$LAYOUT)" ""
    return 0
  fi
  # Decide which loaders the project opted into by inspecting the union of
  # loaders across the matrix. If both fabric and neoforge appear anywhere,
  # both must be present for every MC.
  local has_fabric=0
  local has_neoforge=0
  local i=0
  local n=${#T_LOADER[@]}
  while [ $i -lt $n ]; do
    [ "${T_LOADER[$i]}" = "fabric" ] && has_fabric=1
    [ "${T_LOADER[$i]}" = "neoforge" ] && has_neoforge=1
    i=$((i + 1))
  done
  local any_fail=0
  local mcs
  mcs=$(unique_mcs)
  if [ -z "$mcs" ]; then
    add_finding "per-mc-subproject-coverage" "hard_fail" "skip" "" "" \
      "skipped: no MC versions detected in multi-MC layout" ""
    return 0
  fi
  while IFS= read -r mc; do
    [ -z "$mc" ] && continue
    if [ ! -d "versions/$mc/common" ]; then
      add_finding "per-mc-subproject-coverage" "hard_fail" "fail" \
        "versions/$mc/common" "" \
        "missing versions/$mc/common/ subproject — every MC line must have its own MC-touching :common" \
        "Re-run /modsmith:init for this MC, or create versions/$mc/common/ + build.gradle (see references/multiloader-layout.md ## Multi-MC layout)"
      any_fail=1
    fi
    if [ $has_fabric -eq 1 ] && [ ! -d "versions/$mc/fabric" ]; then
      add_finding "per-mc-subproject-coverage" "hard_fail" "fail" \
        "versions/$mc/fabric" "" \
        "missing versions/$mc/fabric/ subproject — Fabric was selected but this MC has no Fabric subproject" \
        "Re-run /modsmith:init to render Fabric for this MC, or remove the MC from the matrix"
      any_fail=1
    fi
    if [ $has_neoforge -eq 1 ] && [ ! -d "versions/$mc/neoforge" ]; then
      add_finding "per-mc-subproject-coverage" "hard_fail" "fail" \
        "versions/$mc/neoforge" "" \
        "missing versions/$mc/neoforge/ subproject — NeoForge was selected but this MC has no NeoForge subproject" \
        "Re-run /modsmith:init to render NeoForge for this MC, or remove the MC from the matrix"
      any_fail=1
    fi
  done <<< "$mcs"
  if [ $any_fail -eq 0 ]; then
    add_finding "per-mc-subproject-coverage" "hard_fail" "pass" "" "" \
      "every MC line has all expected subprojects (common + every opted-in loader)" ""
  fi
}

# ----------------------------------------------------------------------------
# Check 19: per-mc-java-toolchain-keyed
#
# gradle.properties must contain `java_version_<mc_suffix>` for each MC in the
# matrix, AND that value must match the MC->Java rule (1.21.x->21, 26.x->25).
# ----------------------------------------------------------------------------

check_per_mc_java_toolchain_keyed() {
  if [ "$MULTI_MC" != "1" ]; then
    add_finding "per-mc-java-toolchain-keyed" "hard_fail" "skip" "" "" \
      "skipped: multi-MC-only check (layout=$LAYOUT)" ""
    return 0
  fi
  if [ ! -f gradle.properties ]; then
    add_finding "per-mc-java-toolchain-keyed" "hard_fail" "skip" "" "" \
      "skipped: gradle.properties not found" ""
    return 0
  fi
  local any_fail=0
  local checked=0
  local mcs
  mcs=$(unique_mcs)
  while IFS= read -r mc; do
    [ -z "$mc" ] && continue
    local suffix; suffix=$(mc_suffix "$mc")
    local key="java_version_$suffix"
    local actual
    actual=$(read_gradle_prop "gradle.properties" "$key")
    local expected
    expected=$(expected_java_for_mc "$mc")
    if [ -z "$expected" ]; then
      add_finding "per-mc-java-toolchain-keyed" "hard_fail" "skip" "" "" \
        "skipped for MC $mc: no Java-toolchain convention known for this MC" ""
      continue
    fi
    checked=1
    if [ -z "$actual" ]; then
      add_finding "per-mc-java-toolchain-keyed" "hard_fail" "fail" \
        "gradle.properties" "" \
        "missing $key in gradle.properties; expected $key=$expected for MC $mc" \
        "Add '$key=$expected' to gradle.properties so versions/$mc/* subprojects can resolve their toolchain"
      any_fail=1
    elif [ "$actual" != "$expected" ]; then
      add_finding "per-mc-java-toolchain-keyed" "hard_fail" "fail" \
        "gradle.properties" "" \
        "$key=$actual but MC $mc requires Java $expected" \
        "Change $key to $expected in gradle.properties (1.21.x requires Java 21; 26.x requires Java 25)"
      any_fail=1
    fi
  done <<< "$mcs"
  if [ $checked -eq 1 ] && [ $any_fail -eq 0 ]; then
    add_finding "per-mc-java-toolchain-keyed" "hard_fail" "pass" "" "" \
      "every MC line has a java_version_<suffix>= pin matching the MC->Java rule" ""
  elif [ $checked -eq 0 ]; then
    add_finding "per-mc-java-toolchain-keyed" "hard_fail" "skip" "" "" \
      "skipped: no MC versions detected" ""
  fi
}

# ----------------------------------------------------------------------------
# Check 20: top-common-no-loader-deps
#
# Top-level common/build.gradle must not declare any net.fabricmc:*,
# net.neoforged:*, OR MC artifact dependencies (com.mojang:minecraft,
# net.neoforged:neoform, etc.). It is pure-Java only.
# ----------------------------------------------------------------------------

check_top_common_no_loader_deps() {
  if [ "$MULTI_MC" != "1" ]; then
    add_finding "top-common-no-loader-deps" "hard_fail" "skip" "" "" \
      "skipped: multi-MC-only check (layout=$LAYOUT)" ""
    return 0
  fi
  local cdir
  cdir=$(subproject_dir "$COMMON_SUBPROJECT")
  if [ -z "$cdir" ]; then
    add_finding "top-common-no-loader-deps" "hard_fail" "skip" "" "" \
      "skipped: multi-MC layout but no top-level :common subproject" ""
    return 0
  fi
  local f
  f=$(subproject_build_file "$cdir")
  if [ -z "$f" ]; then
    add_finding "top-common-no-loader-deps" "hard_fail" "skip" "" "" \
      "skipped: no $cdir/build.gradle(.kts) found" ""
    return 0
  fi
  local any_fail=0
  while IFS=: read -r lineno line; do
    [ -z "$lineno" ] && continue
    local msg
    msg=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    add_finding "top-common-no-loader-deps" "hard_fail" "fail" \
      "$f" "$lineno" \
      "top-level :common declares a loader/MC dep: $msg — :common must be pure Java" \
      "Move this dependency to versions/<mc>/common/build.gradle (MC types are MC-version-specific) or to a loader subproject; :common compiles only against Java + 3rd-party pure-Java libs"
    any_fail=1
  done < <(strip_gradle_comments "$f" | \
    grep -nE '(net\.fabricmc(:|\.fabric-api)|net\.neoforged(:|\.fancymodloader|\.neoforge|\.moddev|\.gradle)|com\.mojang:minecraft|fabric-loader|neoform|userdev|fabric-loom|loom\.officialMojangMappings|mappings[[:space:]]*loom)' \
    2>/dev/null || true)

  if [ $any_fail -eq 0 ]; then
    add_finding "top-common-no-loader-deps" "hard_fail" "pass" "" "" \
      "top-level :common build.gradle has no loader/MC dependencies (pure Java)" ""
  fi
}

# ----------------------------------------------------------------------------
# Check 21: per-mc-modid-consistency
#
# All versions/<mc>/<loader>/ manifests across all MC × loader pairs must
# share the same modid. (Note: this overlaps with modid-consistent-across-loaders
# in multi-MC mode, but is kept separate as it scales to many MC lines and
# emits per-pair findings; the older check just summarizes.)
# ----------------------------------------------------------------------------

check_per_mc_modid_consistency() {
  if [ "$MULTI_MC" != "1" ]; then
    add_finding "per-mc-modid-consistency" "hard_fail" "skip" "" "" \
      "skipped: multi-MC-only check (layout=$LAYOUT)" ""
    return 0
  fi
  # Collect every (mc, loader, manifest, modid) tuple.
  local first_id=""
  local first_src=""
  local any_fail=0
  local checked=0
  local i=0
  local n=${#T_LOADER[@]}
  while [ $i -lt $n ]; do
    local loader="${T_LOADER[$i]}"
    local subdir
    subdir=$(subproject_dir "${T_SUBPROJECT[$i]}")
    local mc="${T_MC[$i]}"
    i=$((i + 1))
    [ -z "$subdir" ] && continue
    local manifest=""
    local mid=""
    if [ "$loader" = "fabric" ] && [ -f "$subdir/src/main/resources/fabric.mod.json" ]; then
      manifest="$subdir/src/main/resources/fabric.mod.json"
      mid=$(read_json_string_field "$manifest" "id")
    elif [ "$loader" = "neoforge" ] || [ "$loader" = "forge" ]; then
      if [ -f "$subdir/src/main/resources/META-INF/neoforge.mods.toml" ]; then
        manifest="$subdir/src/main/resources/META-INF/neoforge.mods.toml"
      elif [ -f "$subdir/src/main/resources/META-INF/mods.toml" ]; then
        manifest="$subdir/src/main/resources/META-INF/mods.toml"
      fi
      if [ -n "$manifest" ]; then
        mid=$(read_toml_modid "$manifest")
      fi
    fi
    [ -z "$manifest" ] && continue
    # Treat ${mod_id}-style placeholders as "matches" — they're expanded later.
    if printf '%s' "$mid" | grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*\}'; then
      continue
    fi
    [ -z "$mid" ] && continue
    checked=1
    if [ -z "$first_id" ]; then
      first_id="$mid"
      first_src="$manifest"
    elif [ "$first_id" != "$mid" ]; then
      add_finding "per-mc-modid-consistency" "hard_fail" "fail" \
        "$manifest" "" \
        "modid mismatch in (MC $mc, $loader): manifest modId=$mid but ($first_src) had $first_id" \
        "Every per-MC, per-loader manifest must share a single modid. Pick one (likely the gradle.properties value) and update every manifest."
      any_fail=1
    fi
  done
  if [ $checked -eq 0 ]; then
    add_finding "per-mc-modid-consistency" "hard_fail" "skip" "" "" \
      "skipped: no per-MC manifests found with literal modids (all use \${mod_id} placeholders)" ""
    return 0
  fi
  if [ $any_fail -eq 0 ]; then
    add_finding "per-mc-modid-consistency" "hard_fail" "pass" "" "" \
      "every (MC, loader) manifest shares the same modid ($first_id)" ""
  fi
}

# ----------------------------------------------------------------------------
# Run all checks.
# ----------------------------------------------------------------------------

check_common_no_loader_imports
check_platform_coverage_and_services
check_common_no_loader_deps
check_gradle_props_source_of_truth
check_neoforge_mods_toml_name
check_java_toolchain
check_refmap_config
check_mixin_config_references
check_modid_consistent
check_pack_mcmeta_present
check_pinned_versions_fresh
check_forge_deps_via_modimpl
check_at_aw_parity
check_event_bus_heuristic
check_single_loader_upgrade

# Multi-MC specific checks.
check_top_common_pure_java
check_per_mc_subproject_coverage
check_per_mc_java_toolchain_keyed
check_top_common_no_loader_deps
check_per_mc_modid_consistency

# ----------------------------------------------------------------------------
# Emit JSON.
# ----------------------------------------------------------------------------

verdict() {
  if [ $HARD_FAIL_COUNT -gt 0 ]; then
    printf 'fail'
  elif [ $WARN_COUNT -gt 0 ]; then
    printf 'pass_with_warnings'
  else
    printf 'pass'
  fi
}

emit_findings() {
  printf '"findings":['
  local i=0
  local n=${#F_CHECK[@]}
  while [ $i -lt $n ]; do
    [ $i -gt 0 ] && printf ','
    local file_field
    local line_field
    if [ -z "${F_FILE[$i]}" ]; then
      file_field='null'
    else
      file_field="\"$(json_escape "${F_FILE[$i]}")\""
    fi
    if [ -z "${F_LINE[$i]}" ]; then
      line_field='null'
    else
      line_field="${F_LINE[$i]}"
    fi
    printf '{"check":"%s","severity":"%s","status":"%s","file":%s,"line":%s,"message":"%s","fix_hint":"%s"}' \
      "$(json_escape "${F_CHECK[$i]}")" \
      "$(json_escape "${F_SEVERITY[$i]}")" \
      "$(json_escape "${F_STATUS[$i]}")" \
      "$file_field" \
      "$line_field" \
      "$(json_escape "${F_MESSAGE[$i]}")" \
      "$(json_escape "${F_HINT[$i]}")"
    i=$((i + 1))
  done
  printf ']'
}

{
  printf '{'
  printf '"summary":{'
  printf '"hard_fail_count":%d,' "$HARD_FAIL_COUNT"
  printf '"warn_count":%d,' "$WARN_COUNT"
  printf '"passed_count":%d,' "$PASSED_COUNT"
  printf '"verdict":"%s"' "$(verdict)"
  printf '},'
  emit_findings
  printf '}\n'
}

if [ $HARD_FAIL_COUNT -gt 0 ]; then
  exit 1
fi
exit 0
