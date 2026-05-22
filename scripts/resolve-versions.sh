#!/bin/bash
# resolve-versions.sh — convert symbolic version tokens to concrete MC + loader
# version pins suitable for writing into gradle.properties.
#
# Usage:
#   resolve-versions.sh --mc "<tok1>,<tok2>,..." --loaders "<lo1>,<lo2>,..."
#
# Stdout: a single JSON document with the schema documented in
# skills/init/SKILL.md and the modsmith plan. Example:
#
#   {
#     "resolved": [
#       {
#         "input_mc_token": "latest",
#         "mc_version": "26.1.2",
#         "java_toolchain": 25,
#         "loaders": {
#           "fabric":   { "loader_version": "0.19.2",
#                         "fabric_api_version": "0.145.4+26.1.2" },
#           "neoforge": { "loader_version": "26.1.2.64-beta" }
#         },
#         "parchment": { "mc": "1.21.1", "version": "2024.11.17" },
#         "notes": ["..."]
#       }
#     ],
#     "warnings": ["..."]
#   }
#
# Exit codes:
#   0 — every token resolved
#   1 — at least one token failed (still emits JSON with `warnings`)
#   2 — usage error

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

FABRIC_META_GAME="https://meta.fabricmc.net/v2/versions/game"
FABRIC_META_LOADER="https://meta.fabricmc.net/v2/versions/loader"
NEOFORGE_MAVEN_METADATA="https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"
PARCHMENT_MAVEN_METADATA_TPL="https://maven.parchmentmc.org/org/parchmentmc/data/parchment-%s/maven-metadata.xml"
MODRINTH_FABRIC_API_TPL='https://api.modrinth.com/v2/project/fabric-api/version?game_versions=%%5B%%22%s%%22%%5D'

CACHE_DIR="${MODSMITH_CACHE_DIR:-$HOME/.cache/modsmith/version-meta}"
CACHE_TTL_SECONDS="${MODSMITH_CACHE_TTL:-3600}"   # 1h
LTS_DEFAULT_MC="1.21.1"                            # community-LTS fallback

mkdir -p "$CACHE_DIR"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

MC_TOKENS=""
LOADERS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --mc)       MC_TOKENS="$2";  shift 2 ;;
    --loaders)  LOADERS="$2";    shift 2 ;;
    -h|--help)
      grep -E '^# ' "$0" | sed -E 's/^# ?//'
      exit 0
      ;;
    *)
      warn "unknown argument: $1"
      exit 2
      ;;
  esac
done

if [ -z "$MC_TOKENS" ] || [ -z "$LOADERS" ]; then
  warn "usage: resolve-versions.sh --mc <tokens> --loaders <list>"
  exit 2
fi

# ---------------------------------------------------------------------------
# JSON helpers (string-only — jq writes the final document)
# ---------------------------------------------------------------------------

# Print a JSON-quoted string for a given input.
json_str() {
  printf '%s' "$1" | jq -Rs .
}

# Cache + fetch a URL. Returns the cached body on stdout, fetching fresh if the
# cached file is older than CACHE_TTL_SECONDS or missing.
fetch_cached() {
  local url="$1"
  local key
  key=$(printf '%s' "$url" | shasum -a 256 | awk '{print $1}')
  local cache_file="$CACHE_DIR/$key"

  if [ -f "$cache_file" ]; then
    local age
    if stat -f '%m' "$cache_file" >/dev/null 2>&1; then
      # macOS / BSD stat
      local mtime now
      mtime=$(stat -f '%m' "$cache_file")
      now=$(date +%s)
      age=$((now - mtime))
    else
      # GNU stat
      local mtime now
      mtime=$(stat -c '%Y' "$cache_file")
      now=$(date +%s)
      age=$((now - mtime))
    fi
    if [ "$age" -lt "$CACHE_TTL_SECONDS" ]; then
      cat "$cache_file"
      return 0
    fi
  fi

  if curl -sSLf --max-time 30 "$url" -o "$cache_file.tmp"; then
    mv "$cache_file.tmp" "$cache_file"
    cat "$cache_file"
    return 0
  else
    rm -f "$cache_file.tmp"
    # Fall back to stale cache if any — better stale data than nothing.
    if [ -f "$cache_file" ]; then
      cat "$cache_file"
      return 0
    fi
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Per-source resolvers
# ---------------------------------------------------------------------------

# State arrays for the final JSON. Parallel.
TOKEN_INPUT=()        # original token
TOKEN_MC=()           # concrete MC version
TOKEN_JAVA=()         # 21 / 25
TOKEN_FAB_LOADER=()   # fabric loader version (or "")
TOKEN_FAB_API=()      # fabric-api version (or "")
TOKEN_NEO_LOADER=()   # neoforge loader version (or "")
TOKEN_PARCH_MC=()     # parchment minecraftVersion (or "")
TOKEN_PARCH_VER=()    # parchment mappingsVersion (or "")
TOKEN_NOTES_JSON=()   # JSON array literal of per-token notes
WARNINGS=()           # global warnings

want_fabric=0
want_neoforge=0
for lo in $(printf '%s' "$LOADERS" | tr ',' ' '); do
  case "$lo" in
    fabric)   want_fabric=1 ;;
    neoforge) want_neoforge=1 ;;
    "" )      : ;;
    *) WARNINGS+=("unknown loader: $lo (expected fabric or neoforge)") ;;
  esac
done

# Pre-fetch shared metadata (used by multiple tokens).
GAMES_JSON=""
if ! GAMES_JSON=$(fetch_cached "$FABRIC_META_GAME"); then
  WARNINGS+=("could not fetch fabric meta game versions; symbolic tokens may fail")
fi

NEO_META_XML=""
if [ $want_neoforge -eq 1 ]; then
  if ! NEO_META_XML=$(fetch_cached "$NEOFORGE_MAVEN_METADATA"); then
    WARNINGS+=("could not fetch NeoForge maven-metadata.xml; neoforge versions will be null")
  fi
fi

# Derive Java toolchain from MC version.
derive_java() {
  case "$1" in
    1.21*|1.21) printf '21' ;;
    26.*)       printf '25' ;;
    *)          printf '' ;;
  esac
}

# Validate that a given MC version string is published (best-effort).
validate_mc() {
  local mc="$1"
  [ -n "$GAMES_JSON" ] || return 0    # can't validate; assume caller is right
  printf '%s' "$GAMES_JSON" | jq -e --arg v "$mc" 'any(.[]; .version == $v)' >/dev/null
}

# Resolve a single MC token to a concrete version. Echoes the version (or empty).
resolve_mc_token() {
  local tok="$1"
  case "$tok" in
    latest)
      if [ -z "$GAMES_JSON" ]; then return 1; fi
      printf '%s' "$GAMES_JSON" | jq -r 'map(select(.stable==true)) | .[0].version' \
        | grep -v '^null$'
      ;;
    next)
      if [ -z "$GAMES_JSON" ]; then return 1; fi
      printf '%s' "$GAMES_JSON" | jq -r '.[0].version' | grep -v '^null$'
      ;;
    lts)
      printf '%s' "$LTS_DEFAULT_MC"
      ;;
    recommended)
      # NeoForge has a "recommended" concept; we fall back to LTS for the
      # cross-loader case since Fabric doesn't ship recommended channels.
      printf '%s' "$LTS_DEFAULT_MC"
      ;;
    [0-9]*.[0-9]*.[0-9]*|[0-9]*.[0-9]*)
      # Exact or partial pin.
      if printf '%s' "$tok" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        if validate_mc "$tok"; then printf '%s' "$tok"; else return 1; fi
      else
        # Partial like "1.21" → newest "1.21.X" patch.
        if [ -z "$GAMES_JSON" ]; then return 1; fi
        local prefix="${tok}."
        printf '%s' "$GAMES_JSON" \
          | jq -r --arg p "$prefix" --arg t "$tok" '
              map(select(.stable==true))
              | map(.version)
              | map(select(. == $t or startswith($p)))
              | .[0]' \
          | grep -v '^null$'
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

# Resolve the latest stable Fabric loader version (global, not MC-specific —
# loader versions are not pinned per MC by Fabric).
resolve_fabric_loader() {
  local body
  body=$(fetch_cached "$FABRIC_META_LOADER") || return 1
  printf '%s' "$body" | jq -r 'map(select(.stable==true)) | .[0].version' \
    | grep -v '^null$'
}

# Resolve the newest Fabric API version for a given MC. Uses Modrinth.
resolve_fabric_api() {
  local mc="$1"
  local url
  url=$(printf "$MODRINTH_FABRIC_API_TPL" "$mc")
  local body
  body=$(fetch_cached "$url") || return 1
  # Modrinth lists newest first.
  printf '%s' "$body" \
    | jq -r --arg mc "$mc" '
        [ .[] | select(.game_versions | index($mc)) ]
        | .[0].version_number' \
    | grep -v '^null$'
}

# Resolve the newest NeoForge build for a given MC line.
# - 26.1.x  → versions matching ^26\.1\.x\.  (e.g. 26.1.2.64-beta)
# - 1.21.1  → versions matching ^21\.1\.     (NeoForge drops MC's leading 1.)
resolve_neoforge() {
  local mc="$1"
  [ -n "$NEO_META_XML" ] || return 1

  # Decide the NeoForge line prefix from the MC version.
  local prefix=""
  case "$mc" in
    1.21.1) prefix="21.1." ;;
    1.20.1) prefix="20.1." ;;
    26.1.0|26.1|26.1.*) prefix="26.1." ;;
    26.2.*|26.2) prefix="26.2." ;;
    *)
      # Fallback: try mapping "X.Y.Z" → "Y.Z." (drop leading 1.)
      if printf '%s' "$mc" | grep -qE '^1\.[0-9]+\.[0-9]+$'; then
        prefix=$(printf '%s' "$mc" | sed -E 's/^1\.([0-9]+)\.([0-9]+)$/\1.\2./')
      elif printf '%s' "$mc" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        prefix=$(printf '%s' "$mc" | awk -F. '{print $1"."$2"."}')
      fi
      ;;
  esac
  [ -n "$prefix" ] || return 1

  # Extract <version>...</version> entries and pick the highest matching prefix.
  printf '%s' "$NEO_META_XML" \
    | grep -oE '<version>[^<]+</version>' \
    | sed -E 's|</?version>||g' \
    | grep "^${prefix//./\\.}" \
    | tail -1
}

# Resolve Parchment mapping for an MC version. Echoes "<mc>|<mappingsVersion>"
# or empty if unresolved. Parchment publishes per-MC artifacts, so if there is
# no artifact for the given MC, we attempt the closest LTS line.
resolve_parchment() {
  local mc="$1"
  local url body

  # Try requested MC first, then fall back to LTS.
  for try_mc in "$mc" "$LTS_DEFAULT_MC"; do
    url=$(printf "$PARCHMENT_MAVEN_METADATA_TPL" "$try_mc")
    if body=$(fetch_cached "$url" 2>/dev/null); then
      local release
      release=$(printf '%s' "$body" \
        | grep -oE '<release>[^<]+</release>' \
        | head -1 \
        | sed -E 's|</?release>||g')
      if [ -n "$release" ]; then
        printf '%s|%s' "$try_mc" "$release"
        return 0
      fi
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Resolve each MC token
# ---------------------------------------------------------------------------

IFS=',' read -r -a mc_arr <<< "$MC_TOKENS"
for tok in "${mc_arr[@]}"; do
  tok="$(printf '%s' "$tok" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  [ -z "$tok" ] && continue

  notes=()
  mc=""
  if mc=$(resolve_mc_token "$tok"); then
    : # ok
  else
    WARNINGS+=("could not resolve MC token '$tok'")
    TOKEN_INPUT+=("$tok")
    TOKEN_MC+=("")
    TOKEN_JAVA+=("")
    TOKEN_FAB_LOADER+=("")
    TOKEN_FAB_API+=("")
    TOKEN_NEO_LOADER+=("")
    TOKEN_PARCH_MC+=("")
    TOKEN_PARCH_VER+=("")
    TOKEN_NOTES_JSON+=('["unresolved"]')
    continue
  fi

  if [ -z "$mc" ]; then
    WARNINGS+=("token '$tok' resolved to empty MC version")
    TOKEN_INPUT+=("$tok")
    TOKEN_MC+=("")
    TOKEN_JAVA+=("")
    TOKEN_FAB_LOADER+=("")
    TOKEN_FAB_API+=("")
    TOKEN_NEO_LOADER+=("")
    TOKEN_PARCH_MC+=("")
    TOKEN_PARCH_VER+=("")
    TOKEN_NOTES_JSON+=('["unresolved"]')
    continue
  fi

  java=$(derive_java "$mc")
  if [ -z "$java" ]; then
    notes+=("could not derive Java toolchain from MC $mc; defaulting to 21")
    java=21
  fi

  if [ "$tok" = "lts" ]; then
    notes+=("lts resolved to community LTS MC line $LTS_DEFAULT_MC; bump LTS_DEFAULT_MC in resolve-versions.sh as the community line shifts")
  fi
  if [ "$tok" = "recommended" ]; then
    notes+=("'recommended' is NeoForge-only; falling back to LTS MC $LTS_DEFAULT_MC for the cross-loader scaffold")
  fi

  fab_loader=""
  fab_api=""
  if [ $want_fabric -eq 1 ]; then
    if v=$(resolve_fabric_loader); then
      fab_loader="$v"
    else
      notes+=("could not resolve latest fabric loader; leaving null")
    fi
    if v=$(resolve_fabric_api "$mc"); then
      fab_api="$v"
    else
      notes+=("no Modrinth fabric-api artifact for MC $mc; leaving null (you may need to set fabric_api_version manually)")
    fi
  fi

  neo_loader=""
  if [ $want_neoforge -eq 1 ]; then
    if v=$(resolve_neoforge "$mc"); then
      neo_loader="$v"
    else
      notes+=("could not resolve NeoForge build for MC $mc; leaving null")
    fi
  fi

  parch_mc=""
  parch_ver=""
  if pair=$(resolve_parchment "$mc"); then
    parch_mc="${pair%%|*}"
    parch_ver="${pair##*|}"
    if [ "$parch_mc" != "$mc" ]; then
      notes+=("parchment has no artifact for MC $mc; falling back to mappings published for $parch_mc")
    fi
  else
    notes+=("could not resolve parchment mappings for MC $mc; build files will use 'null' and gradle will treat parchment as optional")
  fi

  # Build notes JSON.
  if [ ${#notes[@]} -eq 0 ]; then
    notes_json='[]'
  else
    notes_json=$(printf '%s\n' "${notes[@]}" | jq -R . | jq -s .)
  fi

  TOKEN_INPUT+=("$tok")
  TOKEN_MC+=("$mc")
  TOKEN_JAVA+=("$java")
  TOKEN_FAB_LOADER+=("$fab_loader")
  TOKEN_FAB_API+=("$fab_api")
  TOKEN_NEO_LOADER+=("$neo_loader")
  TOKEN_PARCH_MC+=("$parch_mc")
  TOKEN_PARCH_VER+=("$parch_ver")
  TOKEN_NOTES_JSON+=("$notes_json")
done

# ---------------------------------------------------------------------------
# Emit JSON via jq
# ---------------------------------------------------------------------------

build_resolved_array() {
  local n=${#TOKEN_INPUT[@]}
  printf '['
  local i=0
  while [ $i -lt "$n" ]; do
    [ $i -gt 0 ] && printf ','

    local mc_json java_json fab_obj neo_obj parch_obj
    mc_json=$(json_str "${TOKEN_MC[$i]}")

    if [ -z "${TOKEN_JAVA[$i]}" ]; then
      java_json=null
    else
      java_json="${TOKEN_JAVA[$i]}"
    fi

    # Fabric loader object.
    fab_obj=""
    if [ $want_fabric -eq 1 ]; then
      local lv av
      if [ -z "${TOKEN_FAB_LOADER[$i]}" ]; then lv=null; else lv=$(json_str "${TOKEN_FAB_LOADER[$i]}"); fi
      if [ -z "${TOKEN_FAB_API[$i]}" ];    then av=null; else av=$(json_str "${TOKEN_FAB_API[$i]}");    fi
      fab_obj=$(printf '"fabric":{"loader_version":%s,"fabric_api_version":%s}' "$lv" "$av")
    fi

    # NeoForge loader object.
    neo_obj=""
    if [ $want_neoforge -eq 1 ]; then
      local nv
      if [ -z "${TOKEN_NEO_LOADER[$i]}" ]; then nv=null; else nv=$(json_str "${TOKEN_NEO_LOADER[$i]}"); fi
      neo_obj=$(printf '"neoforge":{"loader_version":%s}' "$nv")
    fi

    local loaders_obj="{"
    if [ -n "$fab_obj" ] && [ -n "$neo_obj" ]; then
      loaders_obj+="$fab_obj,$neo_obj"
    else
      loaders_obj+="$fab_obj$neo_obj"
    fi
    loaders_obj+="}"

    # Parchment object.
    if [ -z "${TOKEN_PARCH_MC[$i]}" ]; then
      parch_obj=null
    else
      parch_obj=$(printf '{"mc":%s,"version":%s}' \
        "$(json_str "${TOKEN_PARCH_MC[$i]}")" \
        "$(json_str "${TOKEN_PARCH_VER[$i]}")")
    fi

    printf '{"input_mc_token":%s,"mc_version":%s,"java_toolchain":%s,"loaders":%s,"parchment":%s,"notes":%s}' \
      "$(json_str "${TOKEN_INPUT[$i]}")" \
      "$mc_json" \
      "$java_json" \
      "$loaders_obj" \
      "$parch_obj" \
      "${TOKEN_NOTES_JSON[$i]}"

    i=$((i + 1))
  done
  printf ']'
}

build_warnings_array() {
  if [ ${#WARNINGS[@]} -eq 0 ]; then
    printf '[]'
  else
    printf '%s\n' "${WARNINGS[@]}" | jq -R . | jq -sc .
  fi
}

resolved=$(build_resolved_array)
warns=$(build_warnings_array)
printf '{"resolved":%s,"warnings":%s}\n' "$resolved" "$warns" | jq .

# Exit 1 if any token left mc_version empty.
fail=0
for v in "${TOKEN_MC[@]}"; do
  [ -z "$v" ] && fail=1
done
exit $fail
