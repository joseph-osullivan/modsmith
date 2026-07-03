#!/bin/bash
# expand-templates.sh — render every template in $MODSMITH_DIR/templates/ to
# its canonical target path under <out>, substituting `{{var}}` tokens and
# `{{#section}}...{{/section}}` blocks from the supplied vars JSON.
#
# Usage:
#   expand-templates.sh --vars <path/to/vars.json> --out <target_dir>
#
# Mode detection:
#   The renderer operates in one of two modes, chosen automatically by
#   inspecting `vars.json`:
#
#   - **single-MC**  — selected when vars has no `mc_versions` array OR the
#     array has exactly one entry. Renders the flat top-level layout
#     (modid/common, modid/fabric, modid/neoforge) using the
#     templates at $MODSMITH_DIR/templates/*.mustache. This is the
#     unchanged v0.1.0 behavior.
#
#   - **multi-MC**   — selected when vars has `mc_versions` array with 2+
#     entries. Renders the multi-MC layout:
#         common/                              # pure-Java, MC-agnostic
#         versions/<mc>/common/                # MC-touching shared per MC
#         versions/<mc>/fabric/                # Loom per MC
#         versions/<mc>/neoforge/              # MDG per MC
#     using templates at $MODSMITH_DIR/templates/multimc/*.mustache for
#     the build/settings/properties files, and the same per-loader
#     templates for Java sources + manifests (each rendered per MC ×
#     loader with that MC's pins flattened into the context).
#
# vars.json (single-MC schema). Produced by
# `scripts/_init_translate_resolver.py --single-mc` (or hand-written):
#   {
#     "modid": "testmod", "mod_name": "Test Mod", ...,
#     "mc_version": "26.2", "java_version": "25",
#     "neoform_version": "26.2-1",
#     "fabric_loader_version": "0.19.3", "fabric_api_version": "0.154.0+26.2",
#     "neoforge_version": "26.2.0.7-beta",
#     "parchment_mc_version": "1.21.1", "parchment_version": "2024.11.17",
#     "has_parchment": true,
#     "is_unobfuscated": true,        // MC >= 26: Loom no-remap plugin id, no
#                                     // mappings block, plain `implementation`
#     "fml_has_getcurrent": true,     // MC >= 26: FMLLoader.getCurrent() exists
#     "loaders": ["fabric","neoforge"]
#   }
#   (`has_parchment`, `is_unobfuscated`, `fml_has_getcurrent`, and
#    `neoform_version` are derived from `mc_version` by the renderer when
#    absent, so pre-v0.2.1 hand-written vars files still render.)
#
# vars.json (multi-MC schema). Produced by scripts/_init_translate_resolver.py:
#   {
#     "modid": "testmod", "mod_name": "Test Mod", ...,
#     "java_version_shared": "21",   // MIN Java across MC lines: every line
#                                    // consumes :common's bytecode and an older
#                                    // JVM cannot load newer bytecode
#     "primary_mc_version": "26.2",  // first MC line; written to
#                                    // gradle.properties as minecraft_version=
#                                    // for repo-detection tooling
#     "loaders": ["fabric","neoforge"],
#     "mc_versions": [
#       {
#         "mc_version": "1.21.1",
#         "mc_suffix":  "1_21_1",          // dots→underscores, used for gradle.properties keys
#         "java_version": "21",
#         "neoform_version": "1.21.1-20240808.144430",
#         "neoforge_version": "21.1.235",
#         "fabric_loader_version": "0.19.3",
#         "fabric_api_version": "0.116.13+1.21.1",
#         "parchment_mc_version": "1.21.1",
#         "parchment_version": "2024.11.17",
#         "has_fabric": true,
#         "has_neoforge": true,
#         "has_parchment": true,
#         "is_unobfuscated": false,        // MC < 26 (obfuscated): legacy
#                                          // fabric-loom id + mappings block
#         "fml_has_getcurrent": false      // NeoForge 21.x: static FMLLoader API
#       },
#       {
#         "mc_version": "26.2",
#         "mc_suffix": "26_2",
#         "is_unobfuscated": true,
#         "fml_has_getcurrent": true,
#         ...
#       }
#     ]
#   }
#
# Mustache subset implementation: a small custom renderer at
# scripts/_mustache.py supporting `{{var}}`, `{{#section}}...{{/section}}`,
# and `{{^section}}...{{/section}}`. Hand-rolled to keep modsmith's
# install surface to (jq, python3) only — no pip, no chevron, no mustache
# binary. See _mustache.py for details.
#
# Exit codes:
#   0 — every template rendered, no unresolved {{...}} tokens remain
#   1 — render failure
#   2 — usage error

. "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

MODSMITH_DIR="${MODSMITH_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
TEMPLATES_DIR="${MODSMITH_TEMPLATES_DIR:-$MODSMITH_DIR/templates}"
MULTIMC_TEMPLATES_DIR="$TEMPLATES_DIR/multimc"
SCRIPTS_DIR="$(dirname "${BASH_SOURCE[0]}")"

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

if ! jq -e . "$VARS_FILE" >/dev/null 2>&1; then
  warn "vars file is not valid JSON: $VARS_FILE"
  exit 2
fi

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# Mode detection
# ---------------------------------------------------------------------------

MC_COUNT=$(jq -r '
  if has("mc_versions") and (.mc_versions | type) == "array"
  then (.mc_versions | length)
  else 0
  end' "$VARS_FILE")

if [ "$MC_COUNT" -ge 2 ]; then
  MODE="multimc"
else
  MODE="single"
fi

# Shared values we need in shell for path construction.
PACKAGE_BASE=$(jq -r '.package_base // ""' "$VARS_FILE")
PACKAGE_BASE_PATH=$(jq -r '.package_base_path // ""' "$VARS_FILE")
if [ -z "$PACKAGE_BASE_PATH" ] && [ -n "$PACKAGE_BASE" ]; then
  PACKAGE_BASE_PATH=$(printf '%s' "$PACKAGE_BASE" | tr '.' '/')
fi
MODID=$(jq -r '.modid // ""' "$VARS_FILE")
LOADERS_LIST=$(jq -r '.loaders | if type == "array" then join(" ") else "fabric neoforge" end' "$VARS_FILE")

want_loader() {
  local lo="$1"
  for l in $LOADERS_LIST; do
    [ "$l" = "$lo" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Renderer wrappers
# ---------------------------------------------------------------------------

RENDERED=()

# render <src_template> <dst_path> [<inner_context.json>]
render() {
  local src="$1" dst="$2" inner="${3:-}"
  if [ ! -f "$src" ]; then
    warn "template missing: $src"
    return 1
  fi
  mkdir -p "$(dirname "$dst")"
  if [ -n "$inner" ]; then
    python3 "$SCRIPTS_DIR/_render_template.py" "$src" "$dst" "$VARS_FILE" "$inner" \
      || { warn "render failed: $src -> $dst"; return 1; }
  else
    python3 "$SCRIPTS_DIR/_render_template.py" "$src" "$dst" "$VARS_FILE" \
      || { warn "render failed: $src -> $dst"; return 1; }
  fi
  RENDERED+=("$dst")
}

# ---------------------------------------------------------------------------
# Single-MC render plan (unchanged behavior)
# ---------------------------------------------------------------------------

render_single_mc() {
  render "$TEMPLATES_DIR/gradle.properties.mustache" "$OUT_DIR/gradle.properties"
  render "$TEMPLATES_DIR/settings.gradle.mustache"   "$OUT_DIR/settings.gradle"
  render "$TEMPLATES_DIR/root.build.gradle.mustache" "$OUT_DIR/build.gradle"
  render "$TEMPLATES_DIR/CLAUDE.md.mustache"         "$OUT_DIR/CLAUDE.md"
  render "$TEMPLATES_DIR/common.build.gradle.mustache" "$OUT_DIR/common/build.gradle"

  local common_java_dir="$OUT_DIR/common/src/main/java/$PACKAGE_BASE_PATH"
  render "$TEMPLATES_DIR/PlatformHelper.java.mustache" "$common_java_dir/platform/IPlatformHelper.java"
  render "$TEMPLATES_DIR/Services.java.mustache"        "$common_java_dir/platform/Services.java"
  render "$TEMPLATES_DIR/ModInit.java.mustache"         "$common_java_dir/ModInit.java"

  # Tier-1 test tree: JUnit wiring lives in common/build.gradle; ship a
  # trivial sample test so the red-first test pattern exists on day one.
  render "$TEMPLATES_DIR/ScaffoldSmokeTest.java.mustache" \
    "$OUT_DIR/common/src/test/java/$PACKAGE_BASE_PATH/unit/ScaffoldSmokeTest.java"

  local common_res="$OUT_DIR/common/src/main/resources"
  render "$TEMPLATES_DIR/accesstransformer.cfg.mustache" "$common_res/META-INF/accesstransformer.cfg"
  render "$TEMPLATES_DIR/mixins.json.mustache"           "$common_res/${MODID}.mixins.json"

  if want_loader fabric; then
    render "$TEMPLATES_DIR/fabric.build.gradle.mustache" "$OUT_DIR/fabric/build.gradle"
    local fab_java="$OUT_DIR/fabric/src/main/java/$PACKAGE_BASE_PATH/fabric"
    render "$TEMPLATES_DIR/FabricModInit.java.mustache"       "$fab_java/FabricModInit.java"
    render "$TEMPLATES_DIR/FabricPlatformHelper.java.mustache" "$fab_java/platform/FabricPlatformHelper.java"

    local fab_res="$OUT_DIR/fabric/src/main/resources"
    render "$TEMPLATES_DIR/fabric.mod.json.mustache" "$fab_res/fabric.mod.json"
    render "$TEMPLATES_DIR/fabric-services.txt.mustache" \
      "$fab_res/META-INF/services/${PACKAGE_BASE}.platform.IPlatformHelper"
  fi

  if want_loader neoforge; then
    render "$TEMPLATES_DIR/neoforge.build.gradle.mustache" "$OUT_DIR/neoforge/build.gradle"
    local neo_java="$OUT_DIR/neoforge/src/main/java/$PACKAGE_BASE_PATH/neoforge"
    render "$TEMPLATES_DIR/NeoForgeModInit.java.mustache"       "$neo_java/NeoForgeModInit.java"
    render "$TEMPLATES_DIR/NeoForgePlatformHelper.java.mustache" "$neo_java/platform/NeoForgePlatformHelper.java"

    local neo_res="$OUT_DIR/neoforge/src/main/resources"
    render "$TEMPLATES_DIR/neoforge.mods.toml.mustache" "$neo_res/META-INF/neoforge.mods.toml"
    render "$TEMPLATES_DIR/neoforge-services.txt.mustache" \
      "$neo_res/META-INF/services/${PACKAGE_BASE}.platform.IPlatformHelper"
  fi

  # GitHub Actions CI workflow (matrix over loaders).
  render "$TEMPLATES_DIR/github/workflows/ci.yml.mustache" "$OUT_DIR/.github/workflows/ci.yml"
}

# ---------------------------------------------------------------------------
# Multi-MC render plan
# ---------------------------------------------------------------------------

render_multimc() {
  if [ ! -d "$MULTIMC_TEMPLATES_DIR" ]; then
    warn "multi-MC templates dir not found: $MULTIMC_TEMPLATES_DIR"
    return 1
  fi

  # Root files use the full vars context (Mustache iterates mc_versions
  # inside settings.gradle / gradle.properties).
  render "$MULTIMC_TEMPLATES_DIR/gradle.properties.mustache" "$OUT_DIR/gradle.properties"
  render "$MULTIMC_TEMPLATES_DIR/settings.gradle.mustache"   "$OUT_DIR/settings.gradle"
  render "$MULTIMC_TEMPLATES_DIR/root.build.gradle.mustache" "$OUT_DIR/build.gradle"
  render "$TEMPLATES_DIR/CLAUDE.md.mustache"                 "$OUT_DIR/CLAUDE.md"

  # Top-level :common — pure Java, MC-agnostic.
  render "$MULTIMC_TEMPLATES_DIR/common.build.gradle.mustache" "$OUT_DIR/common/build.gradle"
  # The top-level common has its OWN package-base-rooted directory tree for
  # any pure-Java shared code the user adds. We don't ship any sources by
  # default (the per-MC common modules hold the IPlatformHelper +
  # ModInit + Services entry points), but we do ensure the source root
  # exists so IDEs pick it up.
  mkdir -p "$OUT_DIR/common/src/main/java/$PACKAGE_BASE_PATH"
  mkdir -p "$OUT_DIR/common/src/main/resources"

  # Tier-1 test tree: JUnit wiring lives in common/build.gradle; ship a
  # trivial sample test so the red-first test pattern exists on day one.
  render "$TEMPLATES_DIR/ScaffoldSmokeTest.java.mustache" \
    "$OUT_DIR/common/src/test/java/$PACKAGE_BASE_PATH/unit/ScaffoldSmokeTest.java"

  # For each MC row, render the per-MC subprojects.
  local mc_count
  mc_count=$(jq -r '.mc_versions | length' "$VARS_FILE")
  local i=0
  while [ "$i" -lt "$mc_count" ]; do
    # Extract a flat per-MC context to a temp file. This includes the
    # per-MC fields PLUS a copy of every top-level scalar from the global
    # context (modid, package_base, mod_name, etc.), so the Java +
    # manifest templates that reference {{modid}}, {{package_base}},
    # {{mc_version}}, {{neoforge_version}}, etc. resolve cleanly.
    local inner_ctx
    inner_ctx=$(mktemp /tmp/modsmith-mc-ctx.XXXXXX.json)

    jq --argjson idx "$i" '
      .mc_versions[$idx] as $row
      | (. | to_entries | map(select(.value | type == "string" or type == "number")) | from_entries) as $globals
      | $globals + $row
    ' "$VARS_FILE" > "$inner_ctx"

    local mc_version mc_suffix
    mc_version=$(jq -r '.mc_version' "$inner_ctx")
    mc_suffix=$(jq -r '.mc_suffix' "$inner_ctx")

    if [ -z "$mc_version" ] || [ "$mc_version" = "null" ]; then
      warn "mc_versions[$i].mc_version is missing"
      rm -f "$inner_ctx"
      return 1
    fi
    if [ -z "$mc_suffix" ] || [ "$mc_suffix" = "null" ]; then
      warn "mc_versions[$i].mc_suffix is missing"
      rm -f "$inner_ctx"
      return 1
    fi

    local mc_root="$OUT_DIR/versions/$mc_version"

    # ---- versions/<mc>/common ----
    render "$MULTIMC_TEMPLATES_DIR/versions.common.build.gradle.mustache" \
      "$mc_root/common/build.gradle" "$inner_ctx"

    local mc_common_java="$mc_root/common/src/main/java/$PACKAGE_BASE_PATH"
    render "$TEMPLATES_DIR/ModInit.java.mustache"           "$mc_common_java/ModInit.java"           "$inner_ctx"
    render "$TEMPLATES_DIR/PlatformHelper.java.mustache"     "$mc_common_java/platform/IPlatformHelper.java" "$inner_ctx"
    render "$TEMPLATES_DIR/Services.java.mustache"           "$mc_common_java/platform/Services.java"        "$inner_ctx"

    local mc_common_res="$mc_root/common/src/main/resources"
    render "$TEMPLATES_DIR/accesstransformer.cfg.mustache" "$mc_common_res/META-INF/accesstransformer.cfg" "$inner_ctx"
    render "$TEMPLATES_DIR/mixins.json.mustache"           "$mc_common_res/${MODID}.mixins.json"             "$inner_ctx"

    # ---- versions/<mc>/fabric ----
    if want_loader fabric; then
      render "$MULTIMC_TEMPLATES_DIR/versions.fabric.build.gradle.mustache" \
        "$mc_root/fabric/build.gradle" "$inner_ctx"
      local fab_java="$mc_root/fabric/src/main/java/$PACKAGE_BASE_PATH/fabric"
      render "$TEMPLATES_DIR/FabricModInit.java.mustache"       "$fab_java/FabricModInit.java"       "$inner_ctx"
      render "$TEMPLATES_DIR/FabricPlatformHelper.java.mustache" "$fab_java/platform/FabricPlatformHelper.java" "$inner_ctx"

      local fab_res="$mc_root/fabric/src/main/resources"
      render "$TEMPLATES_DIR/fabric.mod.json.mustache" "$fab_res/fabric.mod.json" "$inner_ctx"
      render "$TEMPLATES_DIR/fabric-services.txt.mustache" \
        "$fab_res/META-INF/services/${PACKAGE_BASE}.platform.IPlatformHelper" "$inner_ctx"
    fi

    # ---- versions/<mc>/neoforge ----
    if want_loader neoforge; then
      render "$MULTIMC_TEMPLATES_DIR/versions.neoforge.build.gradle.mustache" \
        "$mc_root/neoforge/build.gradle" "$inner_ctx"
      local neo_java="$mc_root/neoforge/src/main/java/$PACKAGE_BASE_PATH/neoforge"
      render "$TEMPLATES_DIR/NeoForgeModInit.java.mustache"       "$neo_java/NeoForgeModInit.java"       "$inner_ctx"
      render "$TEMPLATES_DIR/NeoForgePlatformHelper.java.mustache" "$neo_java/platform/NeoForgePlatformHelper.java" "$inner_ctx"

      local neo_res="$mc_root/neoforge/src/main/resources"
      render "$TEMPLATES_DIR/neoforge.mods.toml.mustache" "$neo_res/META-INF/neoforge.mods.toml" "$inner_ctx"
      render "$TEMPLATES_DIR/neoforge-services.txt.mustache" \
        "$neo_res/META-INF/services/${PACKAGE_BASE}.platform.IPlatformHelper" "$inner_ctx"
    fi

    rm -f "$inner_ctx"
    i=$((i + 1))
  done

  # GitHub Actions CI workflow (matrix over MC × loader).
  render "$MULTIMC_TEMPLATES_DIR/github/workflows/ci.yml.mustache" "$OUT_DIR/.github/workflows/ci.yml"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

if [ "$MODE" = "multimc" ]; then
  warn "multi-MC mode: rendering $MC_COUNT MC lines × loaders [$LOADERS_LIST]"
  if ! render_multimc; then
    warn "multi-MC render failed"
    exit 1
  fi
else
  warn "single-MC mode"
  if ! render_single_mc; then
    warn "single-MC render failed"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Gradle wrapper — copy the pinned wrapper bundled at templates/gradle-wrapper/.
# Applies to both single-MC and multi-MC modes (wrapper is the same).
# Users no longer need `gradle` on PATH to bootstrap a scaffold.
# ---------------------------------------------------------------------------

WRAPPER_SRC="$MODSMITH_DIR/templates/gradle-wrapper"
WRAPPER_FILES=(
  "gradle/wrapper/gradle-wrapper.jar"
  "gradle/wrapper/gradle-wrapper.properties"
  "gradlew"
  "gradlew.bat"
)

if [ ! -d "$WRAPPER_SRC" ]; then
  warn "templates/gradle-wrapper/ is missing from $MODSMITH_DIR; scaffold will not be self-bootstrapping"
  exit 1
fi

for rel in "${WRAPPER_FILES[@]}"; do
  src="$WRAPPER_SRC/$rel"
  dst="$OUT_DIR/$rel"
  if [ ! -f "$src" ]; then
    warn "wrapper file missing from templates/gradle-wrapper/: $rel"
    exit 1
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
done

# Preserve the executable bit on gradlew (cp inherits source perms on most
# platforms, but force it here so a chmod-stripped source still works).
chmod +x "$OUT_DIR/gradlew"

# ---------------------------------------------------------------------------
# Post-check: assert no `{{name}}` placeholders survived in rendered files.
# (Section markers should never survive either; the renderer strips them.)
# ---------------------------------------------------------------------------

UNRESOLVED=()
for f in "${RENDERED[@]}"; do
  matches=$(grep -onE '\{\{[ ]*[#^/]?[ ]*[a-zA-Z_][a-zA-Z0-9_]*[ ]*\}\}' "$f" 2>/dev/null || true)
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

warn "rendered ${#RENDERED[@]} files into $OUT_DIR ($MODE mode)"
exit 0
