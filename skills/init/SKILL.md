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
```

All flags are optional except `<modid>`. Use the defaults below for
missing values.

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
will get two MC versions resolved. The v1 init scaffold targets **one
MC version**: take the first row by default, but if the user supplied
multiple tokens, ask them which row to use as the scaffold's pin
(multi-MC scaffolds are future work).

## Step 4 — confirm with the user

Before rendering anything, show a summary:

```
About to scaffold:
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

Use `AskUserQuestion` for the confirmation. Default Y. On `n`, exit
cleanly (no files written).

## Step 5 — build the vars JSON + render

Write the vars JSON to a temp file the renderer can read. Schema is the
union of:

- everything from the resolver row (`mc_version`, `java_toolchain`,
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

The renderer:
- Skips loader-specific templates when a loader is deselected.
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
not, skip with a clear "Run `gradle wrapper --gradle-version 9.2 &&
./gradlew :fabric:build :neoforge:build` to verify the scaffold." note.

```bash
TARGETS=()
for lo in $LOADERS_LIST; do TARGETS+=(":$lo:build"); done
./gradlew "${TARGETS[@]}" --no-daemon
```

This first build can take 5–10 minutes (downloading vanilla MC, NeoForge,
Fabric Loom mappings). If it succeeds, the scaffold is green and you
have a working multi-loader baseline.

If it fails, **do not retry blindly**. Show the user the gradle output,
note the likely cause (network, Java version mismatch, version pin
ahead of what's published), and exit. The scaffold itself is still
valid; only the proof-build failed.

## Step 8 — print next steps

After a successful scaffold, print a short text block:

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

## Error handling

- **Empty-dir check failed** → halt with the dir-not-empty message
  above. Do not modify anything.
- **AskUserQuestion timeout / cancel** → exit cleanly.
- **Resolver failure** → show warnings; allow user to retry or abort.
  Do not write files with `null` values silently.
- **Template render failure (unresolved tokens)** → halt and show the
  unresolved tokens. The renderer's stderr lists them.
- **Git failure** → warn but continue; the scaffold doesn't require
  git to function.
- **Gradle build failure** → show the relevant output, exit non-zero,
  but **leave the rendered files in place** so the user can inspect.

Never leave the cwd in a "half scaffolded" state from a known failure
mode. If something goes wrong mid-render, the only thing that's hit
the disk are the templates rendered up to that point — the user can
either complete by hand or delete the dir and re-run.

## Non-interactive smoke test

This invocation should always work end-to-end if the resolver's APIs
are reachable:

```
/modsmith:init testmod --mc latest --loaders fabric,neoforge \
  --package com.example.testmod --name "Test Mod" \
  --license MIT --author tester
```

Use this as the canary when iterating on the skill.
