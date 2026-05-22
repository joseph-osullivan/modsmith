---
name: doctor
description: "Audit the current mod for multi-loader hygiene: platform interface impl coverage, ServiceLoader registration, no loader imports in common, mixin/refmap config, version freshness, mods.toml naming, and more. Outputs structured JSON; exits non-zero on hard fail."
user-invocable: true
allowed-tools: Read, Glob, Grep, Bash
---

# /modsmith:doctor — multi-loader hygiene audit

This skill audits a Minecraft mod repository for the kind of multi-loader
landmines codified in [`references/landmines.md`](../../references/landmines.md)
and the layout contracts in
[`references/multiloader-layout.md`](../../references/multiloader-layout.md)
and [`references/expect-actual-pattern.md`](../../references/expect-actual-pattern.md).

It runs in two modes:

| Mode | Invocation | Output |
| --- | --- | --- |
| User-invoked | `/modsmith:doctor` | Human-readable summary + JSON to stdout |
| Phase gate from `:develop` | `scripts/doctor.sh --json` (called by the orchestrator) | JSON only, no chatter |

In either mode, exit code is **0** if no `hard_fail` findings, **1** otherwise.
The phase gate inside `/modsmith:develop` reads the JSON, fails the gate on
any `hard_fail` finding, and treats `warn` and `info` as advisory.

## What the doctor checks

The complete list of checks lives in `scripts/doctor.sh` (the source of
truth). The check IDs and severities are summarized here for orientation.
Layout-conditional checks `skip` themselves when N/A.

### Multiloader-only (skipped if `layout != "multiloader"`)

| Check ID | Severity | What it verifies |
| --- | --- | --- |
| `platform-interface-impl-coverage` | hard_fail | Every interface in `common/.../platform/` has a matching impl in EACH loader subproject (matched by `implements <InterfaceName>`) |
| `services-meta-inf-registration` | hard_fail | Each interface has a `META-INF/services/<FQN>` file in every loader subproject whose single line is a valid impl FQN |
| `common-no-loader-imports` | hard_fail | No `import net.fabricmc.*` or `import net.neoforged.*` anywhere under `common/src/main/java/` |
| `common-no-loader-deps` | hard_fail | `common/build.gradle(.kts)` declares no `modImplementation` for `fabric-loader` or `neoforge` runtime artifacts |
| `fabric-refmap-enabled-neoforge-disabled` | hard_fail | Multiloader: Loom default mixin refmap behavior is preserved (Fabric on, NeoForge off); no Loom plugin in `:neoforge` |
| `modid-consistent-across-loaders` | hard_fail | `fabric.mod.json#id` == `neoforge.mods.toml [[mods]] modId` |

### Universal (run regardless of layout)

| Check ID | Severity | What it verifies |
| --- | --- | --- |
| `gradle-properties-source-of-truth` | hard_fail | No hardcoded MC / loader / API version digits in subproject `build.gradle(.kts)` (plugin version pins are allowed — Loom and MDG plugins are infrastructure) |
| `neoforge-mods-toml-name` | hard_fail | If a NeoForge resource has a `mods.toml`, it is the pre-26.x name and must be renamed to `neoforge.mods.toml` |
| `java-toolchain-matches-mc` | hard_fail | Declared Java toolchain matches the MC version (Java 21 for 1.21.x, Java 25 for 26.x, Java 17 for 1.20.x or below) |
| `mixin-config-references` | hard_fail | Every `**/*.mixins.json` is referenced from at least one loader manifest (`fabric.mod.json` `mixins` array OR `neoforge.mods.toml` `mixins` block) |
| `forge-deps-via-modimplementation` | hard_fail | In any Fabric build.gradle, dependencies sourced from CurseForge / Modrinth Maven use `modImplementation`, not `implementation` |
| `pack-mcmeta-present-if-assets-or-data` | warn | If `assets/<modid>/` or `data/<modid>/` exist in any subproject's resources, a `pack.mcmeta` exists alongside |
| `pinned-versions-fresh` | warn | Pinned `minecraft_version` / `neoforge_version` / `fabric_loader_version` are within 3 releases of latest (best-effort; skipped offline) |
| `AT-AW-parity` | warn | If `accesstransformer.cfg` exists in `common/META-INF/`, a Fabric task generating the corresponding `accesswidener` is present; missing-AW warning |
| `mod-bus-vs-game-bus-events` | info | Heuristic: surface `@SubscribeEvent` locations in NeoForge subproject so a human can confirm the right bus |
| `single-loader-upgrade-suggested` | info | If `layout == "single-loader"` (and no `:common`), suggests a multi-loader migration via `/modsmith:develop` |

## Flow

1. **Resolve the plugin install root** the same way `:develop` does — use
   the env var `CLAUDE_PLUGIN_ROOT` when present (Claude Code sets this for
   installed plugins; for locally-linked installs it points at the
   modsmith repo). Fall back to walking up from this SKILL.md if the var
   is unset:

   ```bash
   MODSMITH_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
   ```

2. **Detect the layout first.** Run `scripts/detect-targets.sh` against
   the current working directory. Parse its JSON to learn:

   - `layout` — used to skip the multiloader-only checks for single-loader,
     monolith, or unknown repos.
   - `common_subproject` — passed through to doctor so it knows where to
     scan for platform interfaces.
   - `targets` — passed through so the Java-toolchain and freshness checks
     can iterate per target.

   If `layout` is `unknown`, most checks N/A — doctor still runs, but most
   findings will be `skip` and verdict will be `pass`.

3. **Invoke `scripts/doctor.sh --json --targets <path-to-detected.json>`**.
   The script writes the targets-JSON it received to a temp file (or
   re-invokes `detect-targets.sh` itself if `--targets` is omitted),
   then runs every check and emits a single JSON document on stdout.

4. **Print a human-readable summary** to the user (only in user-invoked
   mode — `:develop` swallows the chatter and only reads the JSON). The
   summary groups findings by severity, lists each finding's `check`,
   `file:line`, and `message`, and prints the `fix_hint` underneath.

5. **Return** with the script's exit code. `0` means no `hard_fail`s,
   `1` means at least one `hard_fail`.

## Output schema

```jsonc
{
  "summary": {
    "hard_fail_count": 2,
    "warn_count": 5,
    "passed_count": 12,
    "verdict": "fail"  // "fail" | "pass" | "pass_with_warnings"
  },
  "findings": [
    {
      "check": "common-no-loader-imports",
      "severity": "hard_fail",  // "hard_fail" | "warn" | "info"
      "status": "fail",         // "fail" | "pass" | "skip"
      "file": "common/src/main/java/com/example/SomeClass.java",
      "line": 5,
      "message": "import net.fabricmc.api.ClientModInitializer; in common/ — loader APIs forbidden in common",
      "fix_hint": "Move this code to the platform helper interface or fabric/ subproject"
    }
  ]
}
```

Findings with `status == "pass"` or `"skip"` are included in the JSON so
`:develop` can show passed checks in its progress UI. The orchestrator
keys its gate decision off `summary.verdict` (or `hard_fail_count`).

## Conventions

- **Do NOT call gradle.** Every check is a cheap filesystem / regex
  operation. If a check fundamentally needs a build, it goes in v2.
- **Do NOT modify files.** Doctor is read-only. Fix-ups happen via
  builder agents (or by the user) in response to findings.
- **`fix_hint` is mandatory** on every `fail` finding so the user knows
  what to do without rerunning a research agent.
- **`skip` is informational.** Use it to communicate that a check
  intentionally did not apply (e.g., multiloader-only checks in a
  single-loader repo).

## How `:develop` consumes this

The orchestrator's phase 5 (Doctor gate) does:

```bash
DOCTOR_JSON=$(bash "$MODSMITH_DIR/scripts/doctor.sh" --json --targets "$MATRIX_PATH")
DOCTOR_RC=$?
echo "$DOCTOR_JSON" > "$RUN_DIR/doctor-report.json"
if [ $DOCTOR_RC -ne 0 ]; then
  # Block the phase; surface findings to the user and into the kick-back queue.
  ...
fi
```

The verdict and finding list flow into the run's state.json so the
reviewer (and any kick-back loop) has full context.
