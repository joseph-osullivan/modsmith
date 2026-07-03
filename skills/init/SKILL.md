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
**translation** from `resolve-versions.sh` output to the `vars.json`
schema is handled by `scripts/_init_translate_resolver.py` **in both
modes** (multi-MC by default, single-MC via `--single-mc`). See its
docstring for the field-by-field mapping rules (in particular:
`mc_suffix` is derived from `mc_version` by replacing `.` with `_`;
`java_version_shared` is the **min** of per-MC `java_version`s — every
MC line consumes top-level `:common`'s bytecode and an older JVM cannot
load newer bytecode; `java_version_daemon` is `max(21, java_version)`
— the JVM that RUNS Gradle, rendered into
`gradle/gradle-daemon-jvm.properties`; `has_fabric`/`has_neoforge`
flag per-MC loader inclusion; `is_unobfuscated`/`fml_has_getcurrent`
are true for MC ≥ 26 and drive the obfuscation-aware template
branches).

**`neoform_version`:** `resolve-versions.sh` queries
<https://maven.neoforged.net/releases/net/neoforged/neoform/maven-metadata.xml>
and resolves the latest NeoForm bytecode revision per MC line. The
translator passes that through into each `mc_versions[]` row. If the
network call fails or no artifact matches the requested MC, the
translator falls back to a `<mc>-1` placeholder and sets the row's
`neoform_version_is_placeholder` flag to `true`. In the placeholder
case, surface a clear "replace neoform_version_<mc_suffix> before the
:versions:<mc>:common build" note in the post-render text; in the
happy path no follow-up is needed.

## Resolve the plugin install root

The skill needs `$MODSMITH_DIR` to invoke scripts and read templates.

`CLAUDE_PLUGIN_ROOT` is **authoritative**: it is set when Claude Code
launches the skill inside an installed plugin (for locally-linked
installs — `claude plugin link ./modsmith` — it points at the symlink
target). Use it whenever it is set:

```bash
MODSMITH_DIR="$CLAUDE_PLUGIN_ROOT"
```

If `CLAUDE_PLUGIN_ROOT` is **unset** (e.g. you are executing this skill's
instructions outside a plugin launch), do NOT try to derive the root from
`$0` — snippets here run via the Bash tool, where `$0` is the shell
binary, so any `$(dirname "$0")/..` walk-up resolves to an unrelated
directory. Instead:

1. Substitute the plugin checkout path you already know (the directory
   containing this SKILL.md, two levels up), or
2. Probe upward from the SKILL.md location for the marker file
   `scripts/detect-targets.sh`, and use the directory that contains
   `scripts/` as `$MODSMITH_DIR`.

If neither works, **fail loudly** and ask the user for the plugin path —
never guess.

## Step 1 — verify the cwd is empty

POSIX-safe check (no `shopt` — the host shell may be zsh; hidden files
like `.DS_Store` are tolerated):

```bash
non_hidden=$(find "$PWD" -mindepth 1 -maxdepth 1 -not -name '.*' | head -5)
```

If `non_hidden` is non-empty, halt with the error above. **Do not prompt
to overwrite.**

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
  tokens that resolved to the same MC (e.g. `latest,26.2` when
  latest is `26.2`), there's only one row to scaffold.
- **2+ distinct MC versions** → if `--multimc` or `--single-mc` was
  passed, use that mode without prompting. Otherwise ask the user via
  `AskUserQuestion` whether to scaffold:
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
  MC version:    26.2 (from token "latest")
  Java toolchain: 25
  Fabric loader:  0.19.3 (fabric-api 0.154.0+26.2)
  NeoForge:      26.2.0.7-beta
  Parchment:     1.21.1 / 2024.11.17  (no parchment for 26.2 yet)
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
              neoform 1.21.1-20240808.144430  parchment 1.21.1 / 2024.11.17
    - 26.2    Java 25  fabric 0.19.3  (api 0.154.0+26.2)  neoforge 26.2.0.7-beta
              neoform 26.2-1  parchment 1.21.1 / 2024.11.17 (falls back to 1.21.1; none for 26.2 yet)
  License:       MIT
  Author:        josephd

Render into:    <cwd>
Layout:         common/ + versions/<mc>/{common,fabric,neoforge}/

Proceed? [Y/n]
```

If any per-MC row in the translated vars.json has
`neoform_version_is_placeholder: true`, additionally surface this note
under the "Layout:" line:

```
NOTE: NeoForm version for <mc> could not be resolved. gradle.properties
      will contain a `neoform_version_<mc_suffix>=<mc>-1` placeholder
      that you must replace with the real revision from
      https://maven.neoforged.net/releases/net/neoforged/neoform/
      before the :versions:<mc>:common build will succeed.
```

**Non-interactive rule:** when the invocation used the CLI form, do NOT
prompt — print the summary above and proceed directly. **Documented
defaults filling omitted optional flags count as CLI-supplied inputs**
(e.g. the smoke-test canaries below omit `--version`/`--description`
and still qualify); the only extra requirement is the mode: when 2+
distinct MCs resolved, `--multimc`/`--single-mc` must have been passed
(with 1 distinct MC the mode is implied). This is what makes the
smoke-test invocations at the bottom of this file work end-to-end in
headless/subagent contexts (where `AskUserQuestion` may not exist at
all).

Otherwise — i.e. any input was gathered interactively via
`AskUserQuestion` in Step 2/3, or the run is interactive by nature —
use `AskUserQuestion` for the confirmation. Default Y. On `n`, exit
cleanly (no files written).

## Step 5 — build the vars JSON + render

Write the vars JSON to a temp file the renderer can read. In BOTH modes
the vars JSON is produced by `scripts/_init_translate_resolver.py` from
the raw resolver output + an identity JSON — never hand-build the
resolver→vars mapping.

### Single-MC mode

Persist the raw resolver output and the identity JSON exactly as in the
multi-MC snippet below, then run the translator with `--single-mc`
(add `--mc-version <v>` if the user picked one MC out of several):

```bash
VARS_FILE=$(mktemp /tmp/modsmith-vars.XXXXXX.json)
python3 "$MODSMITH_DIR/scripts/_init_translate_resolver.py" \
  --resolver "$RESOLVER_FILE" \
  --identity "$IDENTITY_FILE" \
  --single-mc \
  --out      "$VARS_FILE"

bash "$MODSMITH_DIR/scripts/expand-templates.sh" \
  --vars "$VARS_FILE" \
  --out  "$PWD"
rm -f "$VARS_FILE"
```

For reference (and for debugging a bad render), the resolver→vars field
mapping the translator applies per row is:

| resolver row field | vars.json field |
| --- | --- |
| `mc_version` | `mc_version` |
| `java_toolchain` | `java_version` (note the rename — templates only know `java_version`) |
| `loaders.fabric.loader_version` | `fabric_loader_version` |
| `loaders.fabric.fabric_api_version` | `fabric_api_version` |
| `loaders.neoforge.loader_version` | `neoforge_version` |
| `neoform_version` | `neoform_version` (falls back to `<mc>-1` placeholder) |
| `parchment.mc` | `parchment_mc_version` (nullable) |
| `parchment.version` | `parchment_version` (nullable) |
| — (derived: parchment non-null) | `has_parchment` |
| — (derived: MC ≥ 26) | `is_unobfuscated`, `fml_has_getcurrent` |
| — (derived: `max(21, java_version)`) | `java_version_daemon` (JVM that runs Gradle → `gradle/gradle-daemon-jvm.properties`) |

Identity fields (`modid`, `mod_name`, `mod_version`, `description`,
`license`, `authors`, `package_base`, `loaders`) are carried through
verbatim. The renderer derives `package_base_path`, `mc_version_range`,
and `neoforge_loader_version_range` if not supplied.

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
- Renders a `CLAUDE.md` (project conventions: test tiers, version-bump
  rule, build commands), a `.github/workflows/ci.yml` (full
  `./gradlew build` gate — same proof command as Step 7, so
  `:common:test` runs in CI too), and a Tier-1 sample test at
  `common/src/test/java/<pkg>/unit/ScaffoldSmokeTest.java` in both modes.
- Verifies no `{{...}}` placeholders survived; exits 1 if any did.
- Always drops a pinned Gradle 9.2.0 (GA) wrapper (jar + properties +
  gradlew + gradlew.bat) into the scaffold from
  `templates/gradle-wrapper/`. No `gradle` binary is required on the
  user's PATH.
- Renders `gradle/gradle-daemon-jvm.properties` (Gradle daemon JVM
  criteria, `toolchainVersion=<java_version_daemon>`) so Gradle picks a
  Java 21+ installed JDK to RUN the build even when `JAVA_HOME` points
  at an older JDK — see the launch-JVM preflight in Step 7.

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

The renderer always ships a pinned Gradle 9.2.0 wrapper, so `./gradlew`
is guaranteed to be present after Step 5.

### Launch-JVM preflight (Java 21+ required to RUN Gradle)

No `gradle` install is needed, but the JVM that **launches** Gradle must
be Java 21+: the buildscript classpath (the fabric-loom / ModDevGradle
plugin jars) carries a module-metadata constraint on the runtime JVM,
and the foojay toolchain convention only provisions **compile/test**
toolchains — it cannot upgrade the JVM Gradle itself runs on. The
scaffold renders `gradle/gradle-daemon-jvm.properties` so Gradle
auto-selects a matching installed JDK for the build JVM even when
`JAVA_HOME` points at an older one; that still requires a suitable JDK
to be **installed**. Before the proof build, check:

```bash
java -version 2>&1 | head -1
```

If the default JVM is older than 21 and no JDK matching the daemon
criteria (`gradle/gradle-daemon-jvm.properties`) is installed, tell the
user to install a matching JDK (e.g. Temurin) — or, as a stopgap,
export `JAVA_HOME` to any installed JDK 21+ — before building.

**Both modes use the same proof command** — the full build, so every
subproject (including `:common` and, in multi-MC mode, each
`:versions:<mc>:common`) compiles, tests, and assembles:

```bash
./gradlew build --no-daemon
```

Do NOT substitute per-target builds (`:fabric:build`,
`:versions:<mc>:fabric:build`, ...) as the proof — they skip compiling
the common modules' own jars and under-test the scaffold. Per-target
builds are fine for a user's later incremental iteration, not for this
gate.

In multi-MC mode: if any per-MC row in the translated vars.json has
`neoform_version_is_placeholder: true`, the `:versions:<mc>:common`
build will fail until the placeholder is replaced — surface that as
a likely cause when the placeholder flag is set.

### Expectations

This first build can take 5-10 minutes (downloading vanilla MC,
NeoForge, Fabric Loom mappings). If it succeeds, the scaffold is
green and you have a working baseline.

If it fails, **do not retry blindly**. Show the user the gradle output,
note the likely cause (network, Java version mismatch, version pin
ahead of what's published, or — in multi-MC mode with placeholder
NeoForm versions — an unresolved `neoform_version_<mc_suffix>` line),
and exit. In particular, `Could not resolve net.fabricmc:fabric-loom...
Dependency requires at least JVM runtime version 21. This build uses a
Java <N> JVM.` means the launch JVM is too old — see the preflight
above. The scaffold itself is still valid; only the proof-build
failed.

## Step 8 — print next steps

After a successful scaffold, print a short text block. The body
depends on the scaffold mode.

### Single-MC mode

```
Scaffold complete in <cwd>.

Files rendered:
  build.gradle, settings.gradle, gradle.properties
  CLAUDE.md (project conventions: test tiers, version-bump rule, build commands)
  .github/workflows/ci.yml (CI gate: full ./gradlew build, incl. :common:test)
  gradlew, gradlew.bat, gradle/wrapper/ (pinned Gradle 9.2.0 wrapper)
  gradle/gradle-daemon-jvm.properties (build-JVM criteria: Java <N>)
  common/ (loader-neutral code + mixin config + AT + JUnit wiring
           + sample Tier-1 test)
  fabric/ (entrypoint + platform helper + manifest)
  neoforge/ (entrypoint + platform helper + manifest)

Next steps:
  1. Open the project in IntelliJ — IDE configs are auto-generated by the
     loader plugins on first sync.
  2. Add gameplay code via `/modsmith:develop` (preferred) or by hand.
     Common-side code goes in common/src/main/java/<your.package>/;
     loader-specific impls of common interfaces live in the matching
     fabric/ and neoforge/ subprojects.
  3. To verify the scaffold compiles green any time (no gradle install
     required — the bundled wrapper downloads Gradle 9.2.0 on first run;
     you DO need an installed JDK 21+ for Gradle itself to run on —
     gradle/gradle-daemon-jvm.properties selects it automatically):
        ./gradlew build
     or, per loader (incremental iteration only — not the full gate):
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
  common/                              pure Java, MC-agnostic (Java <java_version_shared>,
                                       the LOWEST across MC lines) + JUnit wiring + sample test
  versions/<mc>/common/                MC-touching shared, one copy per MC line
  versions/<mc>/fabric/                Loom per MC
  versions/<mc>/neoforge/              MDG per MC
  CLAUDE.md                            project conventions (test tiers, version-bump rule)
  .github/workflows/ci.yml             CI gate: full ./gradlew build (incl. :common:test)
  gradlew, gradlew.bat, gradle/wrapper/  pinned Gradle 9.2.0 wrapper (bundled)
  gradle/gradle-daemon-jvm.properties  build-JVM criteria (Java <N>, highest across MC lines)

MC lines scaffolded:
  - 1.21.1  Java 21  neoform 1.21.1-20240808.144430
  - 26.2    Java 25  neoform 26.2-1
  (per-MC pins live in gradle.properties with the <key>_<mc_suffix>
   scheme; see references/multiloader-layout.md `## Multi-MC layout`.)

Next steps:
  1. Open the project in IntelliJ.
  2. Pure-Java shared code (math, codecs, data structures, business logic)
     belongs in top-level :common. The MOMENT you import a net.minecraft.*,
     net.fabricmc.*, or net.neoforged.* type, move the file to
     versions/<mc>/common/ — `/modsmith:doctor` enforces this.
  3. Add gameplay code via `/modsmith:develop` (preferred) or by hand.
  4. To verify everything compiles green (no gradle install required —
     the bundled wrapper downloads Gradle 9.2.0 on first run; you DO
     need an installed JDK 21+ for Gradle itself to run on —
     gradle/gradle-daemon-jvm.properties selects it automatically):
        ./gradlew build
     or, per MC line (incremental iteration only — not the full gate):
        ./gradlew :versions:1.21.1:fabric:build :versions:1.21.1:neoforge:build
  5. To launch a dev client for a specific MC line:
        ./gradlew :versions:1.21.1:fabric:runClient
        ./gradlew :versions:26.2:neoforge:runClient
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

If any per-MC row in the vars.json has `neoform_version_is_placeholder:
true` (resolver couldn't reach maven.neoforged.net or no NeoForm
artifact matched the MC line), prepend a "REQUIRED follow-up" block to
the Next steps:

```
REQUIRED follow-up:
  - NeoForm version for <mc> is a placeholder
    (`neoform_version_<mc_suffix>=<mc>-1`). Replace it with the real
    revision from
    <https://maven.neoforged.net/releases/net/neoforged/neoform/>
    before running `:versions:<mc>:common:build`.
```

In the happy path (every row has the resolver-supplied NeoForm
revision), omit this block entirely.

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
  In multi-MC mode, if any vars.json row had
  `neoform_version_is_placeholder: true` and the failing target was
  `:versions:<mc>:common:build` (or anything downstream of it on the
  same MC line), the unresolved NeoForm placeholder is the likely
  cause — surface that. In the happy path (all NeoForm revisions were
  resolved by the resolver), this hint should not fire.

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
