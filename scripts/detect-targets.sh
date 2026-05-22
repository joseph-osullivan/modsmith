#!/bin/bash
# detect-targets.sh — emit a structured JSON matrix of (loader, mc_version,
# loader_version, subproject) targets for the Minecraft mod repo at cwd.
#
# Usage:
#   detect-targets.sh                # detect from cwd
#   detect-targets.sh <repo_root>    # detect from explicit path
#
# Stdout: one JSON document. Schema:
#   {
#     "layout": "multiloader" | "single-loader" | "monolith" | "unknown",
#     "common_subproject": ":common" | null,
#     "targets": [
#       { "loader": "fabric" | "neoforge" | "forge" | "quilt",
#         "mc_version": "26.1.2",
#         "loader_version": "0.18.6",
#         "subproject": ":fabric",
#         "java_toolchain": 25 }
#     ],
#     "java_toolchain": 25,
#     "detection_notes": ["..."]
#   }
#
# Exit codes:
#   0 — at least one target detected
#   1 — layout is "unknown" (no recognizable Minecraft build)
#   2 — usage error

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

ROOT="${1:-$(pwd)}"
if [ ! -d "$ROOT" ]; then
  warn "not a directory: $ROOT"
  exit 2
fi
cd "$ROOT"

# ----------------------------------------------------------------------------
# JSON emission helpers (manual — avoids jq dependency).
# Strings are escaped for quote, backslash, and ASCII control bytes.
# ----------------------------------------------------------------------------

json_escape() {
  # Escape a single string for JSON. Input via $1.
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# ----------------------------------------------------------------------------
# Detection state (filled in below).
# ----------------------------------------------------------------------------

LAYOUT="unknown"
COMMON_SUBPROJECT=""    # "" means null in output
JAVA_TOOLCHAIN=""       # integer (e.g. 21, 25); empty if unknown
NOTES=()                # array of detection notes

# Per-target parallel arrays so we don't rely on associative arrays in bash 3.x.
TGT_LOADER=()
TGT_MC=()
TGT_LOADER_VER=()
TGT_SUBPROJECT=()
TGT_JAVA=()

add_note() {
  NOTES+=("$1")
}

# ----------------------------------------------------------------------------
# Property lookup helpers — read `key=value` from a gradle.properties file.
# ----------------------------------------------------------------------------

# Find first matching line "<key>=<value>" in a gradle.properties; print value.
# Comments and blank lines ignored. Whitespace around `=` trimmed.
# Always returns 0; prints empty when file is absent or key is missing.
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
          line=$0
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

# Walk up from a subproject directory to find an effective gradle.properties
# value, preferring per-subproject over root. Always returns 0.
prop_with_fallback() {
  local sub_dir="$1"
  local key="$2"
  local v=""
  if [ -n "$sub_dir" ] && [ -f "$sub_dir/gradle.properties" ]; then
    v=$(read_gradle_prop "$sub_dir/gradle.properties" "$key")
  fi
  if [ -z "$v" ]; then
    v=$(read_gradle_prop "gradle.properties" "$key")
  fi
  printf '%s' "$v"
  return 0
}

# ----------------------------------------------------------------------------
# Detect subprojects from settings.gradle / settings.gradle.kts.
# Captures everything in include('...') / include(":...") forms.
# ----------------------------------------------------------------------------

SETTINGS_FILE=""
if [ -f settings.gradle ]; then
  SETTINGS_FILE="settings.gradle"
elif [ -f settings.gradle.kts ]; then
  SETTINGS_FILE="settings.gradle.kts"
fi

INCLUDED_PROJECTS=()
if [ -n "$SETTINGS_FILE" ]; then
  # Pull out any name inside include('...'), include("..."), include(:...) forms.
  while IFS= read -r line; do
    [ -n "$line" ] && INCLUDED_PROJECTS+=("$line")
  done < <(awk '
    /^[[:space:]]*include[[:space:]]*\(/ {
      s=$0
      # Strip any in-line comments.
      sub(/\/\/.*/, "", s)
      while (match(s, /["'\''][^"'\'']+["'\'']/)) {
        m = substr(s, RSTART, RLENGTH)
        gsub(/["'\'']/, "", m)
        # Normalize leading ":".
        if (substr(m, 1, 1) != ":") m = ":" m
        # Collapse path separators.
        gsub(/\//, ":", m)
        print m
        s = substr(s, RSTART + RLENGTH)
      }
    }
  ' "$SETTINGS_FILE")
fi

has_subproject() {
  local needle="$1"
  for p in "${INCLUDED_PROJECTS[@]:-}"; do
    [ "$p" = "$needle" ] && return 0
  done
  return 1
}

# Map a Gradle subproject path (":fabric") to a filesystem directory.
# Strips leading ":", replaces ":" with "/". Prints empty if the dir is absent.
# Always returns 0 so callers with `set -e` aren't aborted by an absent dir.
subproject_dir() {
  local p="$1"
  local rel="${p#:}"
  rel="${rel//://}"
  if [ -d "$rel" ]; then
    printf '%s' "$rel"
  fi
  return 0
}

# ----------------------------------------------------------------------------
# Plugin presence checks on a build.gradle / build.gradle.kts.
# Looks for the canonical plugin ids.
# ----------------------------------------------------------------------------

# Returns 0 if the file references a Fabric Loom plugin.
file_has_fabric_loom() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -E "(net\.fabricmc\.fabric-loom|fabric-loom|dev\.architectury\.loom)" "$f" >/dev/null 2>&1
}

# Returns 0 if the file references the NeoForge ModDevGradle plugin.
file_has_neoforge_moddev() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -E "(net\.neoforged\.moddev|net\.neoforged\.gradle|userdev)" "$f" >/dev/null 2>&1
}

# Returns 0 if file references legacy Forge plugins (ForgeGradle).
file_has_forge_gradle() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -E "(net\.minecraftforge\.gradle|ForgeGradle)" "$f" >/dev/null 2>&1
}

# Returns 0 if file references a Quilt plugin (Quilt Loom).
file_has_quilt_loom() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -E "(org\.quiltmc\.loom|quilt-loom)" "$f" >/dev/null 2>&1
}

# Locate the build.gradle(.kts) for a subproject. Prints path or empty.
# Always exits 0 so the caller's `set -e` doesn't abort on a missing subproject.
subproject_build_file() {
  local dir="$1"
  if [ -n "$dir" ]; then
    if [ -f "$dir/build.gradle" ]; then
      printf '%s' "$dir/build.gradle"
    elif [ -f "$dir/build.gradle.kts" ]; then
      printf '%s' "$dir/build.gradle.kts"
    fi
  fi
  return 0
}

# ----------------------------------------------------------------------------
# Loader-version resolvers — look at common keys in root gradle.properties.
# ----------------------------------------------------------------------------

# For fabric, look for fabric_loader_version (MultiLoader-Template canon).
# Fall back to "loader_version" if no loader-specific key. Always exits 0.
resolve_fabric_loader_version() {
  local sub_dir="$1"
  local v=""
  for k in fabric_loader_version fabric_version loader_version; do
    v=$(prop_with_fallback "$sub_dir" "$k")
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  done
  return 0
}

# For neoforge: prefer neoforge_version (the canonical pin), fall back.
resolve_neoforge_version() {
  local sub_dir="$1"
  local v=""
  for k in neoforge_version neoforge_loader_version loader_version; do
    v=$(prop_with_fallback "$sub_dir" "$k")
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  done
  return 0
}

# For legacy Forge.
resolve_forge_version() {
  local sub_dir="$1"
  local v=""
  for k in forge_version loader_version; do
    v=$(prop_with_fallback "$sub_dir" "$k")
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  done
  return 0
}

# For Quilt.
resolve_quilt_version() {
  local sub_dir="$1"
  local v=""
  for k in quilt_loader_version loader_version; do
    v=$(prop_with_fallback "$sub_dir" "$k")
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  done
  return 0
}

# ----------------------------------------------------------------------------
# Java toolchain resolution. Prefers gradle.properties `java_version`; else
# derives from MC version (21 for 1.21.x, 25 for 26.x; otherwise empty).
# ----------------------------------------------------------------------------

derive_java_from_mc() {
  local mc="$1"
  case "$mc" in
    1.21*|1.21) printf '21' ;;
    26.*)       printf '25' ;;
    *)          printf '' ;;
  esac
}

# ----------------------------------------------------------------------------
# Build a single target row.
# ----------------------------------------------------------------------------

add_target() {
  local loader="$1"
  local mc="$2"
  local loader_ver="$3"
  local subproject="$4"
  local sub_dir="$5"

  local toolchain
  toolchain=$(prop_with_fallback "$sub_dir" "java_version")
  if [ -z "$toolchain" ]; then
    toolchain=$(derive_java_from_mc "$mc")
  fi
  if [ -z "$toolchain" ] && [ -n "$JAVA_TOOLCHAIN" ]; then
    toolchain="$JAVA_TOOLCHAIN"
  fi

  if [ -z "$mc" ]; then
    add_note "target $loader ($subproject): mc_version not found in gradle.properties"
  fi
  if [ -z "$loader_ver" ]; then
    add_note "target $loader ($subproject): loader_version not found in gradle.properties"
  fi

  TGT_LOADER+=("$loader")
  TGT_MC+=("$mc")
  TGT_LOADER_VER+=("$loader_ver")
  TGT_SUBPROJECT+=("$subproject")
  TGT_JAVA+=("$toolchain")
}

# ----------------------------------------------------------------------------
# Detection algorithm.
# ----------------------------------------------------------------------------

# Pre-compute root-level signals.
ROOT_BUILD=""
if [ -f build.gradle ]; then
  ROOT_BUILD="build.gradle"
elif [ -f build.gradle.kts ]; then
  ROOT_BUILD="build.gradle.kts"
fi

ROOT_MC=$(read_gradle_prop "gradle.properties" "minecraft_version")
ROOT_JAVA=$(read_gradle_prop "gradle.properties" "java_version")
if [ -n "$ROOT_JAVA" ]; then
  JAVA_TOOLCHAIN="$ROOT_JAVA"
elif [ -n "$ROOT_MC" ]; then
  JAVA_TOOLCHAIN=$(derive_java_from_mc "$ROOT_MC")
fi

# Step 1: multi-loader detection via settings.gradle subprojects.
HAS_FABRIC_SUB=0; HAS_NEOFORGE_SUB=0; HAS_FORGE_SUB=0; HAS_QUILT_SUB=0; HAS_COMMON_SUB=0
has_subproject ":fabric"   && HAS_FABRIC_SUB=1
has_subproject ":neoforge" && HAS_NEOFORGE_SUB=1
has_subproject ":forge"    && HAS_FORGE_SUB=1
has_subproject ":quilt"    && HAS_QUILT_SUB=1
has_subproject ":common"   && HAS_COMMON_SUB=1

LOADER_SUB_COUNT=$((HAS_FABRIC_SUB + HAS_NEOFORGE_SUB + HAS_FORGE_SUB + HAS_QUILT_SUB))

if [ "$LOADER_SUB_COUNT" -ge 1 ] && [ -n "$SETTINGS_FILE" ]; then
  LAYOUT="multiloader"
  if [ $HAS_COMMON_SUB -eq 1 ]; then
    COMMON_SUBPROJECT=":common"
  else
    add_note "multi-loader layout detected but no :common subproject; shared code location is ambiguous"
  fi

  # Fabric subproject.
  if [ $HAS_FABRIC_SUB -eq 1 ]; then
    sub_dir=$(subproject_dir ":fabric")
    build_file=$(subproject_build_file "$sub_dir")
    if [ -n "$build_file" ] && file_has_fabric_loom "$build_file"; then
      mc=$(prop_with_fallback "$sub_dir" "minecraft_version")
      lver=$(resolve_fabric_loader_version "$sub_dir")
      add_target "fabric" "$mc" "$lver" ":fabric" "$sub_dir"
    else
      add_note ":fabric subproject is included but its build file does not apply fabric-loom"
    fi
  fi

  # NeoForge subproject.
  if [ $HAS_NEOFORGE_SUB -eq 1 ]; then
    sub_dir=$(subproject_dir ":neoforge")
    build_file=$(subproject_build_file "$sub_dir")
    if [ -n "$build_file" ] && file_has_neoforge_moddev "$build_file"; then
      mc=$(prop_with_fallback "$sub_dir" "minecraft_version")
      lver=$(resolve_neoforge_version "$sub_dir")
      add_target "neoforge" "$mc" "$lver" ":neoforge" "$sub_dir"
    else
      add_note ":neoforge subproject is included but its build file does not apply net.neoforged.moddev"
    fi
  fi

  # Forge subproject (legacy).
  if [ $HAS_FORGE_SUB -eq 1 ]; then
    sub_dir=$(subproject_dir ":forge")
    build_file=$(subproject_build_file "$sub_dir")
    if [ -n "$build_file" ] && file_has_forge_gradle "$build_file"; then
      mc=$(prop_with_fallback "$sub_dir" "minecraft_version")
      lver=$(resolve_forge_version "$sub_dir")
      add_target "forge" "$mc" "$lver" ":forge" "$sub_dir"
    else
      add_note ":forge subproject is included but its build file does not apply ForgeGradle"
    fi
  fi

  # Quilt subproject.
  if [ $HAS_QUILT_SUB -eq 1 ]; then
    sub_dir=$(subproject_dir ":quilt")
    build_file=$(subproject_build_file "$sub_dir")
    if [ -n "$build_file" ] && file_has_quilt_loom "$build_file"; then
      mc=$(prop_with_fallback "$sub_dir" "minecraft_version")
      lver=$(resolve_quilt_version "$sub_dir")
      add_target "quilt" "$mc" "$lver" ":quilt" "$sub_dir"
    else
      add_note ":quilt subproject is included but its build file does not apply Quilt Loom"
    fi
  fi

# Step 2: single-loader Fabric at root.
elif [ -n "$ROOT_BUILD" ] && file_has_fabric_loom "$ROOT_BUILD"; then
  LAYOUT="single-loader"
  mc=$(read_gradle_prop "gradle.properties" "minecraft_version")
  lver=$(resolve_fabric_loader_version "")
  add_target "fabric" "$mc" "$lver" ":" ""

# Step 3: single-loader NeoForge at root (this is lord-of-lands today).
elif [ -n "$ROOT_BUILD" ] && file_has_neoforge_moddev "$ROOT_BUILD"; then
  LAYOUT="single-loader"
  mc=$(read_gradle_prop "gradle.properties" "minecraft_version")
  lver=$(resolve_neoforge_version "")
  add_target "neoforge" "$mc" "$lver" ":" ""

# Step 4: single-loader legacy Forge at root.
elif [ -n "$ROOT_BUILD" ] && file_has_forge_gradle "$ROOT_BUILD"; then
  LAYOUT="single-loader"
  mc=$(read_gradle_prop "gradle.properties" "minecraft_version")
  lver=$(resolve_forge_version "")
  add_target "forge" "$mc" "$lver" ":" ""

# Step 5: single-loader Quilt at root.
elif [ -n "$ROOT_BUILD" ] && file_has_quilt_loom "$ROOT_BUILD"; then
  LAYOUT="single-loader"
  mc=$(read_gradle_prop "gradle.properties" "minecraft_version")
  lver=$(resolve_quilt_version "")
  add_target "quilt" "$mc" "$lver" ":" ""

# Step 6: root build exists but no known loader plugin. Likely a non-MC repo
# or a pre-modlauncher monolith; we mark "monolith" if we still see an MC
# version pin, else "unknown".
else
  if [ -n "$ROOT_MC" ]; then
    LAYOUT="monolith"
    add_note "root build defines minecraft_version=$ROOT_MC but no recognized loader plugin"
  else
    LAYOUT="unknown"
    if [ -z "$ROOT_BUILD" ] && [ -z "$SETTINGS_FILE" ]; then
      add_note "no build.gradle / settings.gradle present — not a Gradle project"
    else
      add_note "no recognized loader plugin (fabric-loom / neoforged.moddev / forge / quilt-loom) and no minecraft_version pin"
    fi
  fi
fi

# ----------------------------------------------------------------------------
# Emit JSON.
# ----------------------------------------------------------------------------

emit_layout_field() {
  printf '"layout":"%s"' "$(json_escape "$LAYOUT")"
}

emit_common_field() {
  if [ -z "$COMMON_SUBPROJECT" ]; then
    printf '"common_subproject":null'
  else
    printf '"common_subproject":"%s"' "$(json_escape "$COMMON_SUBPROJECT")"
  fi
}

emit_targets_field() {
  printf '"targets":['
  local n=${#TGT_LOADER[@]}
  local i=0
  while [ $i -lt "$n" ]; do
    [ $i -gt 0 ] && printf ','
    local java_field
    if [ -z "${TGT_JAVA[$i]}" ]; then
      java_field='null'
    else
      java_field="${TGT_JAVA[$i]}"
    fi
    printf '{"loader":"%s","mc_version":"%s","loader_version":"%s","subproject":"%s","java_toolchain":%s}' \
      "$(json_escape "${TGT_LOADER[$i]}")" \
      "$(json_escape "${TGT_MC[$i]}")" \
      "$(json_escape "${TGT_LOADER_VER[$i]}")" \
      "$(json_escape "${TGT_SUBPROJECT[$i]}")" \
      "$java_field"
    i=$((i + 1))
  done
  printf ']'
}

emit_java_field() {
  if [ -z "$JAVA_TOOLCHAIN" ]; then
    printf '"java_toolchain":null'
  else
    printf '"java_toolchain":%s' "$JAVA_TOOLCHAIN"
  fi
}

emit_notes_field() {
  printf '"detection_notes":['
  local i=0
  local n=${#NOTES[@]}
  while [ $i -lt "$n" ]; do
    [ $i -gt 0 ] && printf ','
    printf '"%s"' "$(json_escape "${NOTES[$i]}")"
    i=$((i + 1))
  done
  printf ']'
}

{
  printf '{'
  emit_layout_field;       printf ','
  emit_common_field;       printf ','
  emit_targets_field;      printf ','
  emit_java_field;         printf ','
  emit_notes_field
  printf '}\n'
}

# Exit code: 0 if at least one target, 1 if unknown.
if [ ${#TGT_LOADER[@]} -gt 0 ]; then
  exit 0
fi
if [ "$LAYOUT" = "unknown" ] || [ "$LAYOUT" = "monolith" ]; then
  exit 1
fi
exit 1
