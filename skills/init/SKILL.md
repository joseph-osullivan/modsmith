---
name: init
description: "Scaffold a new multi-loader Minecraft mod. Interactive: asks for mod ID, package, loaders, and MC versions (accepts symbolic tokens like 'latest' and 'lts'). Renders templates, runs gradle build, and prints next steps."
user-invocable: true
allowed-tools: Read, Glob, Grep, Bash, Write, Edit, AskUserQuestion
---

# /modsmith:init — scaffold a new multi-loader mod

You are the **scaffolder** for a new Minecraft mod. You take an empty
directory, ask the user (or accept CLI args) for project identity + target
matrix, resolve symbolic version tokens against live APIs, render the
canonical MultiLoader-Template-style layout, initialize git, and run a
green build to prove the scaffold compiles.

You are **not a subagent**: you run as the skill body. You orchestrate
**deterministic scripts** — you do not generate Java / Gradle code
yourself, ever. Every byte the user sees comes from `templates/` rendered
by `scripts/expand-templates.sh`.

## Required reading

Before doing anything, glance at:

1. **`references/multiloader-layout.md`** in the plugin — the canonical
   layout that templates render. If the user asks "where does X go?" the
   answer is in that doc.
2. **`references/version-matrix.md`** — known-good MC × loader pins, plus
   the live-API endpoints the resolver hits.

## What this skill does NOT do

- It does not modify an existing project. If the cwd is non-empty, **halt
  immediately** with: *"`/modsmith:init` only scaffolds into empty
  directories. Run from a fresh dir, or use `/modsmith:doctor` for
  existing mods."*
- It does not run `/modsmith:develop` or commit anything beyond the
  initial scaffold commit.
- It does not generate Java code beyond what's in `templates/`. If the
  user wants gameplay code, that comes via `/modsmith:develop`.

## Multi-MC scaffolding

`/modsmith:init` accepts a comma-separated MC list (`--mc latest,lts`).
After version resolution:

- **Exactly 1 distinct MC version resolved** → single-MC scaffold
  (the original v0.1.0 flat layout: `common/`, `fabric/`, `neoforge/`).
- **2+ distinct MC versions resolved** → ask the user to choose:
  - **Multi-MC overlay scaffold** (RECOMMENDED) — one repo, one top-level
    pure-Java `:common`, and per-MC overlays at `versions/<mc>/common/`,
    `versions/<mc>/fabric/`, `versions/<mc>/neoforge/`. The
    canonical layout is documented in
    `references/multiloader-layout.md` (`## Multi-MC layout`).
  - **Single-MC pick** — keep only one MC row, drop the others, use the
    v0.1.0 flat layout. The user picks which MC to keep.

`scripts/expand-templates.sh` auto-detects multi-MC mode by inspecting
`vars.json`: when `mc_versions` is an array with ≥ 2 entries it switches
to the multi-MC layout; otherwise it uses the flat layout. The
**translation** from `resolve-versions.sh` output to the multi-MC
`vars.json` schema is handled by
`scripts/_init_translate_resolver.py`. See its docstring for the
field-by-field mapping rules (in particular: `mc_suffix` is derived from
`mc_version` by replacing `.` with `_`; `java_version_shared` is the max
of per-MC `java_version`s; `has_fabric`/`has_neoforge` flag per-MC
loader inclusion).

**Known caveat — `neoform_version`:** `resolve-versions.sh` does not
emit NeoForm timestamps today. The translator inserts a `<mc>-1`
placeholder so the rendered `gradle.properties` is structurally valid,
but the user must bump each `neoform_version_<mc_suffix>` line to the
real NeoForm revision (from
<https://projects.neoforged.net/neoforged/neoform>) before the MDG
build will succeed for that MC line. Surface this in the post-render
"next steps" text when multi-MC mode is used.

## Resolve the plugin install root

The skill needs `$MODSMITH_DIR` to invoke scripts and read templates.
Resolve it the same way `develop` does:

```bash
MODSMITH_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
```

`CLAUDE_PLUGIN_ROOT` is set when Claude Code launches the skill inside an
installed plugin. For locally-linked installs (`claude plugin link
./modsmith`) it points at the symlink target.

## Step 1 — verify the cwd is empty

```bash
shopt -s dotglob nullglob
entries=( "$PWD"/* )
shopt -u dotglob nullglob
# Allow only: empty, or contains only hidden dotfiles that aren't .git.
non_hidden=()
for e in "${entries[@]}"; do
  bn=$(basename "$e")
  case "$bn" in
    .|..) ;;
    .*) ;;                 # tolerate hidden files (.DS_Store, etc)
    *) non_hidden+=("$e") ;;
  esac
done
```

If `non_hidden` has any entries, halt with the error above. **Do not
prompt to overwrite.**

## Step 2 — gather inputs

You can take inputs either from CLI args (non-interactive form) or via
`AskUserQuestion` (interactive form). Always honour CLI args when
present; only prompt for inputs not supplied.

### CLI form

```
/modsmith:init <modid> [--mc <tokens>] [--loaders <list>]
               [--package <base>] [--name <display>]
               [--license <spdx>] [--author <name>]
               [--version <semver>] [--description <text>]
               [--multimc | --single-mc]
```

All flags are optional except `<modid>`. Use the defaults below for
missing values.

`--mc` accepts a comma-separated token list (e.g.
`--mc latest,lts`). When the resolver returns 2+ distinct MC
versions, the skill prompts the user to choose multi-MC overlay vs
single-MC pick. Pass `--multimc` or `--single-mc` to skip that prompt
in non-interactive runs. `--single-mc` paired with multiple
MC tokens prompts for which MC to keep (still interactive unless the
list resolves to one).

### Interactive form

Ask the user via `AskUserQuestion`. Required answers:

| Field | Validation | Default |
| --- | --- | --- |
| **modid** | regex `^[a-z][a-z0-9_-]{1,63}$` | (no default — must ask) |
| **mod_name** | non-empty string | title-case of modid, hyphens → spaces |
| **package_base** | matches `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$` | `com.example.<modid with - and _ removed>` |
| **description** | string (may be empty) | empty |
| **loaders** | multi-select | both `fabric` and `neoforge` |
| **mc_versions** | comma-separated tokens (`latest`, `lts`, exact pins) | `latest,lts` |
| **license** | SPDX identifier | `MIT` |
| **author** | string | `$USER` |
| **mod_version** | semver | `0.1.0` |

**Reject** invalid modid / package; re-prompt until valid. Other
fields: accept whatever the user supplies (trust them on names,
licenses, etc.).

If the user provided some CLI flags but is missing required pieces, only
prompt for what's missing. If they provided everything via CLI, skip
the AskUserQuestion step entirely and surface the resolved values to
them at the confirmation step instead.

## Step 3 — resolve symbolic versions

Invoke the resolver. Persist its raw JSON output for the next step.

```bash
RAW_JSON=$(bash "$MODSMITH_DIR/scripts/resolve-versions.sh" \
  --mc      "$MC_TOKENS" \
  --loaders "$LOADERS_LIST")
```

If `resolve-versions.sh` exits non-zero, show the user the `warnings`
field of the JSON output and ask them whether to proceed with the
resolved partial data, retry, or abort. Most warnings are recoverable
(e.g. "no Parchment for this MC" → the build still works, just without
parameter names).

The resolver caches API responses to `~/.cache/modsmith/version-meta/`
for 1 hour. If the user wants fresh data, delete that directory and
re-invoke.

**One token in, one row out.** If the user asked for `latest,lts` they
will get two MC versions resolved. Decide the scaffold mode based on
how many **distinct** MC versions came back from the resolver:

- **1 distinct MC** → single-MC mode. Even if the user passed two
  tokens that resolved to the same MC (e.g. `latest,26.1.2` when
  latest is `26.1.2`), there's only one row to scaffold.
- **2+ distinct MC versions** → ask the user via `AskUserQuestion`
  whether to scaffold:
  1. **Multi-MC overlay** (recommended; preserves both MC lines).
  2. **Single-MC pick** — show the list and let them choose which MC
     to keep; the rest are dropped.

  Default to the multi-MC overlay. Surface both MC pins in the
  prompt so the user knows what they're choosing between.

Record the chosen mode in a shell variable (e.g. `SCAFFOLD_MODE=multimc`
or `SCAFFOLD_MODE=single`) and the kept MC row(s) for use in step 5.

## Step 4 — confirm with the user

Before rendering anything, show a summary. The shape depends on the
scaffold mode chosen in step 3.

**Single-MC mode:**

```
About to scaffold (single-MC):
  Mod ID:        shopkeeper
  Display name:  Shopkeeper
  Package:       com.example.shopkeeper
  Loaders:       fabric, neoforge
  MC version:    26.1.2 (from token "latest")
  Java toolchain: 25
  Fabric loader:  0.19.2 (fabric-api 0.149.1+26.1.2)
  NeoForge:      26.1.2.64-beta
  Parchment:     1.21.1 / 2024.11.17  (no parchment for 26.1 yet)
  License:       MIT
  Author:        josephd

Render into:    <cwd>

Proceed? [Y/n]
```

**Multi-MC mode:**

```
About to scaffold (multi-MC overlay):
  Mod ID:        shopkeeper
  Display name:  Shopkeeper
  Package:       com.example.shopkeeper
  Loaders:       fabric, neoforge
  Top-level Java toolchain (shared :common): 25
  MC lines:
    - 1.21.1  Java 21  fabric 0.16.10 (api 0.111.0+1.21.1)  neoforge 21.1.230
              parchment 1.21.1 / 2024.11.17
    - 26.1.2  Java 25  fabric 0.19.2  (api 0.149.1+26.1.2)  neoforge 26.1.2.64-beta
              parchment 1.21.1 / 2024.11.17 (falls back to 1.21.1; none for 26.1 yet)
  License:       MIT
  Author:        josephd

Render into:    <cwd>
Layout:         common/ + versions/<mc>/{common,fabric,neoforge}/

NOTE: neoform_version_<mc_suffix> is rendered as a `<mc>-1` placeholder.
      You must update each per-MC neoform version before the NeoForge
      MDG build will succeed.

Proceed? [Y/n]
```

Use `AskUserQuestion` for the confirmation. Default Y. On `n`, exit
cleanly (no files written).

## Step 5 — build the vars JSON + render

Write the vars JSON to a temp file the renderer can read. The shape
depends on the scaffold mode chosen in step 3.

### Single-MC mode (existing v0.1.0 path)

Schema is the union of:

- the single chosen resolver row (`mc_version`, `java_toolchain`,
  `fabric_loader_version`, `fabric_api_version`, `neoforge_version`,
  `parchment_mc_version`, `parchment_version`),
- identity fields (`modid`, `mod_name`, `mod_version`, `description`,
  `license`, `authors`, `package_base`),
- `loaders` (array of which loaders were selected).

The renderer derives `package_base_path`, `mc_version_range`, and
`neoforge_loader_version_range` if not supplied.

```bash
VARS_FILE=$(mktemp /tmp/modsmith-vars.XXXXXX.json)
# ... write the merged JSON to $VARS_FILE ...
bash "$MODSMITH_DIR/scripts/expand-templates.sh" \
  --vars "$VARS_FILE" \
  --out  "$PWD"
rm -f "$VARS_FILE"
```

### Multi-MC mode

Persist the raw resolver output and a small "identity" JSON to temp
files, then invoke the translator helper to produce the multi-MC
`vars.json`:

```bash
# 1. Identity-only fields the user supplied + selected loaders.
IDENTITY_FILE=$(mktemp /tmp/modsmith-identity.XXXXXX.json)
cat > "$IDENTITY_FILE" <<JSON
{
  "modid": "$MODID",
  "mod_name": "$MOD_NAME",
  "mod_version": "$MOD_VERSION",
  "package_base": "$PACKAGE_BASE",
  "description": "$DESCRIPTION",
  "license": "$LICENSE",
  "authors": "$AUTHORS",
  "loaders": $LOADERS_JSON
}
JSON

# 2. Persist the raw resolver JSON for the translator.
RESOLVER_FILE=$(mktemp /tmp/modsmith-resolver.XXXXXX.json)
printf '%s' "$RAW_JSON" > "$RESOLVER_FILE"

# 3. Run the translator — produces multi-MC vars.json.
VARS_FILE=$(mktemp /tmp/modsmith-vars.XXXXXX.json)
python3 "$MODSMITH_DIR/scripts/_init_translate_resolver.py" \
  --resolver "$RESOLVER_FILE" \
  --identity "$IDENTITY_FILE" \
  --out      "$VARS_FILE"

# 4. Render. expand-templates.sh auto-detects multi-MC mode from
#    vars.json (mc_versions has 2+ entries).
bash "$MODSMITH_DIR/scripts/expand-templates.sh" \
  --vars "$VARS_FILE" \
  --out  "$PWD"

rm -f "$IDENTITY_FILE" "$RESOLVER_FILE" "$VARS_FILE"
```

The translator deduplicates MC rows on `mc_version` (so passing
`latest,latest` collapses to one row and the helper rejects the multi-MC
attempt — fall back to single-MC). It also enforces that 2+ distinct
MCs survived deduplication.

### Renderer notes (both modes)

The renderer:
- Skips loader-specific templates when a loader is deselected.
- Auto-detects multi-MC mode by inspecting `vars.json` (mc_versions
  with 2+ entries).
- Verifies no `{{...}}` placeholders survived; exits 1 if any did.
- Drops a Gradle wrapper if `templates/gradle-wrapper/` exists OR if
  `gradle` is on PATH. Otherwise prints a warning and the user will
  need to run `gradle wrapper --gradle-version 9.2` themselves before
  the build step.

If the renderer exits non-zero, **stop** and surface its stderr. Do not
attempt to clean up partial output — the user's cwd is now in an
intermediate state and they should inspect it.

## Step 6 — initialize git + .gitignore

```bash
cat > .gitignore <<'GITIGNORE'
# Gradle
.gradle/
build/
out/

# IDE
.idea/
*.iml
*.ipr
*.iws
.vscode/

# Run directories created by Fabric Loom / NeoForge MDG
runs/
run/

# OS noise
.DS_Store
Thumbs.db

# Modsmith caches
.cache/
GITIGNORE

git init -b main
git add .
git commit -m "chore: initial modsmith scaffold"
```

If `git` is missing, skip this step and emit a warning — the scaffold
still works, the user just won't have a clean commit history.

## Step 7 — prove the scaffold compiles

Only run this step if a Gradle wrapper was successfully placed. If
not, skip with a clear "Run `gradle wrapper --gradle-version 9.2`,
then the loader-specific build targets" note.

### Single-MC mode

```bash
TARGETS=()
for lo in $LOADERS_LIST; do TARGETS+=(":$lo:build"); done
./gradlew "${TARGETS[@]}" --no-daemon
```

### Multi-MC mode

Build top-level `:common` first (pure Java, no MC), then iterate over
every per-MC × per-loader subproject. Always build the top-level
`:common` first — every per-MC subproject depends on it.

```bash
./gradlew :common:build --no-daemon

# Build every per-MC × per-loader leaf subproject.
TARGETS=()
for mc in "${MC_VERSIONS[@]}"; do
  for lo in $LOADERS_LIST; do
    TARGETS+=(":versions:${mc}:${lo}:build")
  done
done
./gradlew "${TARGETS[@]}" --no-daemon
```

`MC_VERSIONS` is the array of resolved MC versions (e.g.
`(1.21.1 26.1.2)`) you kept after the mode selection in step 3. The
per-MC neoforge subproject may fail if the user hasn't yet replaced
the `<mc>-1` NeoForm placeholder in `gradle.properties` — surface
that as a likely cause if it happens.

### Both modes

This first build can take 5-10 minutes (downloading vanilla MC,
NeoForge, Fabric Loom mappings). If it succeeds, the scaffold is
green and you have a working baseline.

If it fails, **do not retry blindly**. Show the user the gradle output,
note the likely cause (network, Java version mismatch, version pin
ahead of what's published, NeoForm placeholder still in
gradle.properties for multi-MC mode), and exit. The scaffold itself is
still valid; only the proof-build failed.

## Step 8 — print next steps

After a successful scaffold, print a short text block. The body
depends on the scaffold mode.

### Single-MC mode

```
Scaffold complete in <cwd>.

Files rendered:
  build.gradle, settings.gradle, gradle.properties
  common/ (loader-neutral code + mixin config + AT)
  fabric/ (entrypoint + platform helper + manifest)
  neoforge/ (entrypoint + platform helper + manifest)

Next steps:
  1. Open the project in IntelliJ — IDE configs are auto-generated by the
     loader plugins on first sync.
  2. Add gameplay code via `/modsmith:develop` (preferred) or by hand.
     Common-side code goes in common/src/main/java/<your.package>/;
     loader-specific impls of common interfaces live in the matching
     fabric/ and neoforge/ subprojects.
  3. To verify the scaffold compiles green any time:
        ./gradlew :fabric:build :neoforge:build
  4. To launch a dev client (Fabric or NeoForge):
        ./gradlew :fabric:runClient
        ./gradlew :neoforge:runClient
  5. The single source of truth for versions is gradle.properties. Do
     NOT hardcode versions in subproject build files; `/modsmith:doctor`
     will hard-fail any subproject build that does.
```

### Multi-MC mode

```
Scaffold complete in <cwd> (multi-MC overlay).

Layout:
  common/                              pure Java, MC-agnostic (Java <java_version_shared>)
  versions/<mc>/common/                MC-touching shared, one copy per MC line
  versions/<mc>/fabric/                Loom per MC
  versions/<mc>/neoforge/              MDG per MC

MC lines scaffolded:
  - 1.21.1  Java 21
  - 26.1.2  Java 25
  (per-MC pins live in gradle.properties with the <key>_<mc_suffix>
   scheme; see references/multiloader-layout.md `## Multi-MC layout`.)

REQUIRED follow-up:
  - gradle.properties contains placeholder NeoForm timestamps
    (`neoform_version_<mc_suffix>=<mc>-1`). Replace each with the
    real revision from
    <https://projects.neoforged.net/neoforged/neoform> before the
    NeoForge MDG build will succeed.

Next steps:
  1. Open the project in IntelliJ.
  2. Pure-Java shared code (math, codecs, data structures, business logic)
     belongs in top-level :common. The MOMENT you import a net.minecraft.*,
     net.fabricmc.*, or net.neoforged.* type, move the file to
     versions/<mc>/common/ — `/modsmith:doctor` enforces this.
  3. Add gameplay code via `/modsmith:develop` (preferred) or by hand.
  4. To verify each MC line compiles green:
        ./gradlew :common:build
        ./gradlew :versions:1.21.1:fabric:build :versions:1.21.1:neoforge:build
        ./gradlew :versions:26.1.2:fabric:build :versions:26.1.2:neoforge:build
  5. To launch a dev client for a specific MC line:
        ./gradlew :versions:1.21.1:fabric:runClient
        ./gradlew :versions:26.1.2:neoforge:runClient
  6. To fork a shared class between MC versions, copy
     versions/<old>/common/.../Foo.java to
     versions/<new>/common/.../Foo.java keeping the same FQN, and
     adapt the <new> copy to <new>'s MC API. See
     references/multiloader-layout.md `## Forking a class between MC versions`.
  7. The single source of truth for versions is gradle.properties. Do
     NOT hardcode versions in subproject build files; `/modsmith:doctor`
     will hard-fail any subproject build that does.
```

Substitute the actual MC versions, Java toolchain, and per-MC pins
into the template above.

## Error handling

- **Empty-dir check failed** → halt with the dir-not-empty message
  above. Do not modify anything.
- **AskUserQuestion timeout / cancel** → exit cleanly.
- **Resolver failure** → show warnings; allow user to retry or abort.
  Do not write files with `null` values silently.
- **Multi-MC translator failure** (`_init_translate_resolver.py`
  exits 1) → surface the helper's stderr. Common causes: fewer than
  2 distinct MC versions survived deduplication, or the resolver row
  was missing a required field. Offer the user the single-MC fallback.
- **Template render failure (unresolved tokens)** → halt and show the
  unresolved tokens. The renderer's stderr lists them.
- **Git failure** → warn but continue; the scaffold doesn't require
  git to function.
- **Gradle build failure** → show the relevant output, exit non-zero,
  but **leave the rendered files in place** so the user can inspect.
  For multi-MC mode, the NeoForm placeholder
  (`neoform_version_<mc_suffix>=<mc>-1`) is a likely culprit if the
  per-MC `:versions:<mc>:neoforge:build` is what failed — surface that.

Never leave the cwd in a "half scaffolded" state from a known failure
mode. If something goes wrong mid-render, the only thing that's hit
the disk are the templates rendered up to that point — the user can
either complete by hand or delete the dir and re-run.

## Non-interactive smoke test

These invocations should always work end-to-end if the resolver's APIs
are reachable.

**Single-MC canary** (one MC, both loaders):

```
/modsmith:init testmod --mc latest --loaders fabric,neoforge \
  --package com.example.testmod --name "Test Mod" \
  --license MIT --author tester
```

**Multi-MC canary** (two MCs, both loaders):

```
/modsmith:init testmulti --mc latest,lts --loaders fabric,neoforge \
  --package com.example.testmulti --name "Test Multi" \
  --license MIT --author tester --multimc
```

Use these as the canaries when iterating on the skill.
