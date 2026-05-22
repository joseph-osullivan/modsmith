#!/bin/bash
# expand-templates.sh — render every template in $MODSMITH_DIR/templates/ to
# its canonical target path under <out>, substituting `{{var}}` tokens from
# the supplied vars JSON.
#
# Usage:
#   expand-templates.sh --vars <path/to/vars.json> --out <target_dir>
#
# vars.json schema (single object — all values are strings unless noted):
#   {
#     "modid":                "testmod",
#     "mod_name":             "Test Mod",
#     "mod_version":          "0.1.0",
#     "description":          "An example mod",
#     "license":              "MIT",
#     "authors":              "alice",
#     "package_base":         "com.example.testmod",
#     "package_base_path":    "com/example/testmod",   // derived
#     "mc_version":           "26.1.2",
#     "mc_version_range":     "[26.1.2,)",              // derived
#     "java_version":         "25",                     // string
#     "fabric_loader_version":   "0.19.2",
#     "fabric_api_version":      "0.149.1+26.1.2",
#     "neoforge_version":        "26.1.2.64-beta",
#     "neoforge_loader_version_range": "[4,)",
#     "parchment_mc_version":    "1.21.1",
#     "parchment_version":       "2024.11.17",
#     "loaders":              ["fabric","neoforge"]      // array — controls skips
#   }
#
# `loaders` controls which loader-specific templates are rendered. Common
# templates are always rendered.
#
# Exit codes:
#   0 — every template rendered, no unresolved {{...}} tokens remain
#   1 — render failure
#   2 — usage error

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

MODSMITH_DIR="${MODSMITH_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
TEMPLATES_DIR="${MODSMITH_TEMPLATES_DIR:-$MODSMITH_DIR/templates}"

VARS_FILE=""
OUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --vars) VARS_FILE="$2"; shift 2 ;;
    --out)  OUT_DIR="$2";   shift 2 ;;
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

if [ -z "$VARS_FILE" ] || [ -z "$OUT_DIR" ]; then
  warn "usage: expand-templates.sh --vars <vars.json> --out <target_dir>"
  exit 2
fi

if [ ! -f "$VARS_FILE" ]; then
  warn "vars file not found: $VARS_FILE"
  exit 2
fi

if [ ! -d "$TEMPLATES_DIR" ]; then
  warn "templates dir not found: $TEMPLATES_DIR"
  exit 1
fi

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# Load + derive vars
# ---------------------------------------------------------------------------

# Validate JSON.
if ! jq -e . "$VARS_FILE" >/dev/null 2>&1; then
  warn "vars file is not valid JSON: $VARS_FILE"
  exit 2
fi

# Pull all string-typed scalars into a flat KEY=VALUE map for sed-substitution.
# Object/array values are skipped here (loaders[] handled separately).
declare -a VAR_KEYS=()
declare -a VAR_VALUES=()

while IFS=$'\t' read -r k v; do
  VAR_KEYS+=("$k")
  VAR_VALUES+=("$v")
done < <(jq -r '
  to_entries
  | map(select(.value | type == "string" or type == "number"))
  | .[]
  | "\(.key)\t\(.value | tostring)"
' "$VARS_FILE")

# Loaders array as a space-separated list.
LOADERS_LIST=$(jq -r '.loaders | if type == "array" then join(" ") else "fabric neoforge" end' "$VARS_FILE")

# Derive package_base_path from package_base if not already present.
PACKAGE_BASE=$(jq -r '.package_base // ""' "$VARS_FILE")
PACKAGE_BASE_PATH=$(jq -r '.package_base_path // ""' "$VARS_FILE")
if [ -z "$PACKAGE_BASE_PATH" ] && [ -n "$PACKAGE_BASE" ]; then
  PACKAGE_BASE_PATH=$(printf '%s' "$PACKAGE_BASE" | tr '.' '/')
  VAR_KEYS+=("package_base_path")
  VAR_VALUES+=("$PACKAGE_BASE_PATH")
fi

# Derive mc_version_range if absent.
MC_VERSION=$(jq -r '.mc_version // ""' "$VARS_FILE")
MC_VERSION_RANGE=$(jq -r '.mc_version_range // ""' "$VARS_FILE")
if [ -z "$MC_VERSION_RANGE" ] && [ -n "$MC_VERSION" ]; then
  VAR_KEYS+=("mc_version_range")
  VAR_VALUES+=("[$MC_VERSION,)")
fi

# Derive neoforge_loader_version_range if absent.
NEO_RANGE=$(jq -r '.neoforge_loader_version_range // ""' "$VARS_FILE")
if [ -z "$NEO_RANGE" ]; then
  VAR_KEYS+=("neoforge_loader_version_range")
  VAR_VALUES+=("[4,)")
fi

# ---------------------------------------------------------------------------
# Renderer — substitute every {{var}} using the flat key/value arrays.
# ---------------------------------------------------------------------------

want_loader() {
  local lo="$1"
  for l in $LOADERS_LIST; do
    [ "$l" = "$lo" ] && return 0
  done
  return 1
}

# Render a single template file to a target path.
render_template() {
  local src="$1"
  local dst="$2"

  if [ ! -f "$src" ]; then
    warn "template missing: $src"
    return 1
  fi

  mkdir -p "$(dirname "$dst")"

  # Use python for substitution — handles JSON-safe content cleanly without
  # sed-escaping headaches around slashes, ampersands, and newlines in values.
  python3 - "$src" "$dst" "$VARS_FILE" "$PACKAGE_BASE_PATH" "$MC_VERSION" <<'PYEOF'
import json, os, re, sys

src, dst, vars_path, package_base_path, mc_version = sys.argv[1:6]

with open(vars_path, encoding="utf-8") as f:
    raw = json.load(f)

# Build the substitution map: include only scalar keys; add derived ones.
subs = {}
for k, v in raw.items():
    if isinstance(v, (str, int, float)):
        subs[k] = str(v)

if "package_base_path" not in subs and package_base_path:
    subs["package_base_path"] = package_base_path

if "mc_version_range" not in subs and mc_version:
    subs["mc_version_range"] = f"[{mc_version},)"

if "neoforge_loader_version_range" not in subs:
    subs["neoforge_loader_version_range"] = "[4,)"

with open(src, encoding="utf-8") as f:
    text = f.read()

def replace(m):
    key = m.group(1).strip()
    if key in subs:
        return subs[key]
    # Leave unresolved tokens in place so the caller's post-check can flag them.
    return m.group(0)

# Match {{ key }} but NOT ${var} (gradle expand) or ${file.jarVersion}.
out = re.sub(r"\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}", replace, text)

os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
with open(dst, "w", encoding="utf-8") as f:
    f.write(out)
PYEOF
}

# Render + record the path so the post-check can scan all outputs.
RENDERED=()
render() {
  local src="$1" dst="$2"
  if render_template "$src" "$dst"; then
    RENDERED+=("$dst")
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Render plan
# ---------------------------------------------------------------------------

# Common / root templates (always rendered).
render "$TEMPLATES_DIR/gradle.properties.mustache" "$OUT_DIR/gradle.properties"
render "$TEMPLATES_DIR/settings.gradle.mustache"   "$OUT_DIR/settings.gradle"
render "$TEMPLATES_DIR/root.build.gradle.mustache" "$OUT_DIR/build.gradle"
render "$TEMPLATES_DIR/common.build.gradle.mustache" "$OUT_DIR/common/build.gradle"

# Common Java sources.
COMMON_JAVA_DIR="$OUT_DIR/common/src/main/java/$PACKAGE_BASE_PATH"
render "$TEMPLATES_DIR/PlatformHelper.java.mustache" "$COMMON_JAVA_DIR/platform/IPlatformHelper.java"
render "$TEMPLATES_DIR/Services.java.mustache"        "$COMMON_JAVA_DIR/platform/Services.java"
render "$TEMPLATES_DIR/ModInit.java.mustache"         "$COMMON_JAVA_DIR/ModInit.java"

# Common resources.
COMMON_RES="$OUT_DIR/common/src/main/resources"
render "$TEMPLATES_DIR/accesstransformer.cfg.mustache" "$COMMON_RES/META-INF/accesstransformer.cfg"
render "$TEMPLATES_DIR/mixins.json.mustache"           "$COMMON_RES/$(jq -r .modid "$VARS_FILE").mixins.json"

# Fabric.
if want_loader fabric; then
  render "$TEMPLATES_DIR/fabric.build.gradle.mustache" "$OUT_DIR/fabric/build.gradle"
  FAB_JAVA="$OUT_DIR/fabric/src/main/java/$PACKAGE_BASE_PATH/fabric"
  render "$TEMPLATES_DIR/FabricModInit.java.mustache"       "$FAB_JAVA/FabricModInit.java"
  render "$TEMPLATES_DIR/FabricPlatformHelper.java.mustache" "$FAB_JAVA/platform/FabricPlatformHelper.java"

  FAB_RES="$OUT_DIR/fabric/src/main/resources"
  render "$TEMPLATES_DIR/fabric.mod.json.mustache" "$FAB_RES/fabric.mod.json"

  # ServiceLoader registration. The filename IS the FQCN of the interface.
  render "$TEMPLATES_DIR/fabric-services.txt.mustache" \
    "$FAB_RES/META-INF/services/${PACKAGE_BASE}.platform.IPlatformHelper"
fi

# NeoForge.
if want_loader neoforge; then
  render "$TEMPLATES_DIR/neoforge.build.gradle.mustache" "$OUT_DIR/neoforge/build.gradle"
  NEO_JAVA="$OUT_DIR/neoforge/src/main/java/$PACKAGE_BASE_PATH/neoforge"
  render "$TEMPLATES_DIR/NeoForgeModInit.java.mustache"       "$NEO_JAVA/NeoForgeModInit.java"
  render "$TEMPLATES_DIR/NeoForgePlatformHelper.java.mustache" "$NEO_JAVA/platform/NeoForgePlatformHelper.java"

  NEO_RES="$OUT_DIR/neoforge/src/main/resources"
  render "$TEMPLATES_DIR/neoforge.mods.toml.mustache" "$NEO_RES/META-INF/neoforge.mods.toml"

  render "$TEMPLATES_DIR/neoforge-services.txt.mustache" \
    "$NEO_RES/META-INF/services/${PACKAGE_BASE}.platform.IPlatformHelper"
fi

# ---------------------------------------------------------------------------
# Gradle wrapper — copy verbatim if present, else `gradle wrapper`.
# ---------------------------------------------------------------------------

WRAPPER_SRC="$MODSMITH_DIR/templates/gradle-wrapper"
if [ -d "$WRAPPER_SRC" ]; then
  # Copy entire wrapper directory.
  mkdir -p "$OUT_DIR/gradle/wrapper"
  cp -R "$WRAPPER_SRC/gradle/wrapper/." "$OUT_DIR/gradle/wrapper/" 2>/dev/null || true
  for f in gradlew gradlew.bat; do
    if [ -f "$WRAPPER_SRC/$f" ]; then
      cp "$WRAPPER_SRC/$f" "$OUT_DIR/$f"
      chmod +x "$OUT_DIR/$f" 2>/dev/null || true
    fi
  done
elif command -v gradle >/dev/null 2>&1; then
  # No stub wrapper; ask the local gradle to bootstrap one. This produces the
  # canonical gradlew/gradlew.bat + gradle/wrapper/gradle-wrapper.jar set.
  (
    cd "$OUT_DIR" || exit 1
    # Use a tiny placeholder settings.gradle so `gradle wrapper` doesn't try
    # to resolve our actual plugins (which would fail before the build runs).
    if [ ! -f settings.gradle.bak ]; then cp settings.gradle settings.gradle.bak; fi
    printf "rootProject.name = '%s'\n" "$(jq -r .modid "$VARS_FILE")" > settings.gradle
    gradle wrapper --gradle-version 9.2 --no-daemon -q || true
    mv settings.gradle.bak settings.gradle
  )
else
  warn "no gradle binary on PATH and no templates/gradle-wrapper/ stub; the scaffold will be missing ./gradlew. Run \`gradle wrapper --gradle-version 9.2\` in $OUT_DIR after install."
fi

# ---------------------------------------------------------------------------
# Post-check: assert no `{{name}}` placeholders survived in rendered files.
# ---------------------------------------------------------------------------

UNRESOLVED=()
for f in "${RENDERED[@]}"; do
  # Use grep with -E; tolerate files without trailing newline.
  matches=$(grep -onE '\{\{[ ]*[a-zA-Z_][a-zA-Z0-9_]*[ ]*\}\}' "$f" 2>/dev/null || true)
  if [ -n "$matches" ]; then
    while IFS= read -r m; do
      UNRESOLVED+=("$f:$m")
    done <<< "$matches"
  fi
done

if [ ${#UNRESOLVED[@]} -gt 0 ]; then
  warn "unresolved template tokens:"
  for u in "${UNRESOLVED[@]}"; do warn "  $u"; done
  exit 1
fi

# Emit a small summary line to stderr so callers can see progress in their
# transcripts. Stdout is reserved for callers that pipe.
warn "rendered ${#RENDERED[@]} files into $OUT_DIR"
exit 0
