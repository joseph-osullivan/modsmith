# Log-watcher rules — universal + loader-specific baselines

The `log-watcher` agent (see `agents/log-watcher.md`) tails the dev server's
`play-session.log` during the Handoff phase of `/modsmith:develop` and emits a
structured report when the player exits. The rules below are the standing
"always check for" list that applies on top of the feature-specific
`play-expectations.json` the architect emits.

Three rule sets compose at scan time, in this order:

1. **Universal baselines** — apply on every play session regardless of loader
   or feature. Stack traces, NPEs in tick paths, classloader errors, missing
   assets.
2. **Loader-specific baselines** — apply only when the dev server is running
   the matching loader. Selected by the `--loader` flag passed to
   `scripts/log-watcher.sh`.
3. **Feature-specific expectations** — `play-expectations.json` emitted by the
   architect for the feature being developed. See "Architect-emitted
   expectations" below.

## Severity definitions

Every pattern has a severity that drives downstream behavior:

| Severity | When it fires | Downstream effect |
|---|---|---|
| `hard_fail` | Any match | Auto-promotes to the reviewer kick-back queue as a bug report. The player sees it in the Handoff summary as a blocker. |
| `warn` | Any match | Surfaced in the Handoff summary and passed to the reviewer; reviewer-discretion whether to kick back. |
| `warn_if_missing` | `hit_count == 0` at finalize time | Used with `should_see` patterns. The expected event never occurred during play — the reviewer cross-references against test coverage to decide if it's a gap. |
| `warn_if_exceeded` | `hit_count > max_count` at finalize time | Used with `background_baseline` patterns. The pattern is allowed to fire some, but above the threshold is noisy / suspect. |

`hard_fail` is the only severity that **auto-promotes** without reviewer
involvement — used for unrecoverable runtime errors (crashes, OOM, classloader
breakage). Everything else flows through the reviewer.

## Baseline schema (the JSON the helper consumes)

Each `<!-- baselines:* -->` block below is a JSON array of objects. The helper
script extracts every block matching the requested category, concatenates the
arrays, and uses them as patterns to scan the log. Each object has:

```jsonc
{
  "pattern": "POSIX-extended regex string",
  "severity": "hard_fail | warn | warn_if_missing | warn_if_exceeded",
  "source": "universal | fabric | neoforge",
  "note": "(optional) short hint shown in finding context"
}
```

`should_see` / `should_not_see` / `background_baseline` semantics live in the
feature spec (the architect's `play-expectations.json`), not in baselines.
Baselines are always implicitly `should_not_see` — they describe events that
indicate something wrong.

## Universal baselines

These apply on every play session, regardless of loader. They cover the
runtime failure modes that MC + JVM share across all loaders. The helper
treats every entry as `should_not_see` (any match is a finding).

<!-- baselines:universal -->
```jsonc
[
  {
    "pattern": "^\\[.*\\] \\[.*/ERROR\\].*Exception",
    "severity": "hard_fail",
    "source": "universal",
    "note": "Stack trace line — typically followed by frames; helper groups consecutive matches."
  },
  {
    "pattern": "at [a-zA-Z_$][a-zA-Z0-9_$.]*\\([A-Za-z0-9_$]+\\.java:[0-9]+\\)",
    "severity": "hard_fail",
    "source": "universal",
    "note": "Stack frame — caught as part of trace grouping with the Exception line above."
  },
  {
    "pattern": "NullPointerException.*tick",
    "severity": "hard_fail",
    "source": "universal",
    "note": "NPE in a tick path — almost always fatal even if MC recovers."
  },
  {
    "pattern": "Exception in (server|client) tick loop",
    "severity": "hard_fail",
    "source": "universal",
    "note": "MC's tick-loop bail-out. Server typically dies after this."
  },
  {
    "pattern": "Can't keep up! .* ticks behind",
    "severity": "warn_if_exceeded",
    "source": "universal",
    "max_count": 5,
    "note": "MC tick lag. A handful is normal during chunk gen; sustained warning means a tick handler is over-budget."
  },
  {
    "pattern": "Using missing texture, unable to load minecraft:textures/",
    "severity": "warn",
    "source": "universal",
    "note": "Vanilla missing texture — usually indicates a mod referenced a path that doesn't exist."
  },
  {
    "pattern": "Missing model for ",
    "severity": "warn",
    "source": "universal",
    "note": "Item / block model not found. Player sees the purple-black checkerboard."
  },
  {
    "pattern": "Couldn't parse (recipe|loot table|advancement|element)",
    "severity": "warn",
    "source": "universal",
    "note": "JSON data load failure. The asset is effectively absent; gameplay paths that need it will silently no-op."
  },
  {
    "pattern": "ClassNotFoundException",
    "severity": "hard_fail",
    "source": "universal",
    "note": "Classloader error — almost always a missing dependency or a class-side-only import in common code."
  },
  {
    "pattern": "NoSuchMethodError",
    "severity": "hard_fail",
    "source": "universal",
    "note": "ABI mismatch — typically a vendored dep linked against the wrong MC version."
  },
  {
    "pattern": "NoClassDefFoundError",
    "severity": "hard_fail",
    "source": "universal",
    "note": "Class loaded once then unloaded, or initializer threw. Check earlier in the log for the underlying cause."
  },
  {
    "pattern": "LinkageError",
    "severity": "hard_fail",
    "source": "universal",
    "note": "JVM linkage failure — duplicate class on classpath, signed-jar mismatch, etc."
  },
  {
    "pattern": "java\\.lang\\.OutOfMemoryError",
    "severity": "hard_fail",
    "source": "universal",
    "note": "OOM. The JVM may continue limping but state from this point onward is suspect."
  }
]
```

## Fabric-specific baselines

Apply only when the dev server is the Fabric loader.

<!-- baselines:fabric -->
```jsonc
[
  {
    "pattern": "Mixin .* failed to apply",
    "severity": "hard_fail",
    "source": "fabric",
    "note": "Sponge mixin failed to inject — usually a method signature changed in MC and the @At target no longer exists."
  },
  {
    "pattern": "Mixin apply failed .*\\.mixins\\.json",
    "severity": "hard_fail",
    "source": "fabric",
    "note": "Mixin config-level failure — entire config rejected; none of its mixins applied."
  },
  {
    "pattern": "fabric\\.api\\.loader.*ERROR",
    "severity": "hard_fail",
    "source": "fabric",
    "note": "Fabric Loader error — mod resolution, manifest parse, version constraint, etc."
  },
  {
    "pattern": "Could not load mixin config",
    "severity": "hard_fail",
    "source": "fabric",
    "note": "fabric.mod.json references a mixin config that doesn't exist or is malformed."
  },
  {
    "pattern": "Sponge mixin .* injection failure",
    "severity": "hard_fail",
    "source": "fabric",
    "note": "Mixin loader-internal failure."
  },
  {
    "pattern": "Refmap '.+' for .+ could not be read",
    "severity": "warn",
    "source": "fabric",
    "note": "Mixin refmap missing — runtime remapping will fall back to dev mappings; release jars will likely fail."
  }
]
```

## NeoForge-specific baselines

Apply only when the dev server is the NeoForge loader.

<!-- baselines:neoforge -->
```jsonc
[
  {
    "pattern": "RegistryAccess.*not yet registered",
    "severity": "hard_fail",
    "source": "neoforge",
    "note": "Registry access before bootstrap completes — common cause is static-init touching a registry."
  },
  {
    "pattern": "Missing registry: ",
    "severity": "hard_fail",
    "source": "neoforge",
    "note": "A registry key referenced from data/code that doesn't exist on this side."
  },
  {
    "pattern": "Mod .* failed to load",
    "severity": "hard_fail",
    "source": "neoforge",
    "note": "Mod load failure — see the immediate context lines for the underlying cause."
  },
  {
    "pattern": "AttachmentType .* could not be found",
    "severity": "warn",
    "source": "neoforge",
    "note": "Attachment type missing — often dev-only artifact of reload; check that registration ran."
  },
  {
    "pattern": "Capability .* is not registered",
    "severity": "warn",
    "source": "neoforge",
    "note": "Capability lookup failed — usually safe in dev (lazy bind), but a bug if the lookup is on a hot path."
  },
  {
    "pattern": "DataFixer.*failed",
    "severity": "hard_fail",
    "source": "neoforge",
    "note": "DataFixer error — corrupted world data or a mod's datafix step threw."
  },
  {
    "pattern": "ModLoadingException",
    "severity": "hard_fail",
    "source": "neoforge",
    "note": "FML's wrapper for mod-side load failures. Look for the cause chain in the next few lines."
  }
]
```

## Architect-emitted expectations

For each feature, the architect emits `play-expectations.json` into the run
dir alongside its other outputs. The schema:

```jsonc
{
  "should_see": [
    {
      "pattern": "regex",
      "min_count": 1,
      "severity": "warn_if_missing",
      "note": "(optional) human label"
    }
  ],
  "should_not_see": [
    {
      "pattern": "regex",
      "severity": "hard_fail | warn",
      "note": "(optional)"
    }
  ],
  "background_baseline": [
    {
      "pattern": "regex",
      "max_count": 50,
      "severity": "warn_if_exceeded",
      "note": "(optional)"
    }
  ]
}
```

### Example: "Hero-tagged player gets discount" feature

For the canonical feature used in the modsmith plan, the architect produces:

```jsonc
{
  "should_see": [
    {
      "pattern": "\\[shopkeeper\\] discount applied to .*",
      "min_count": 1,
      "severity": "warn_if_missing",
      "note": "Discount log line emitted when a Hero-tagged player completes a trade."
    },
    {
      "pattern": "ShopkeeperProfession registered",
      "min_count": 1,
      "severity": "warn_if_missing",
      "note": "Profession registers exactly once during mod construction."
    },
    {
      "pattern": "\\[shopkeeper\\] Hero tag applied to player ",
      "min_count": 1,
      "severity": "warn_if_missing",
      "note": "Pre-discount gate — should appear before the discount line."
    }
  ],
  "should_not_see": [
    {
      "pattern": "ERROR.*lordoflands",
      "severity": "hard_fail",
      "note": "Catches any mod-namespaced ERROR — feature-spec layer of universal stack-trace rule."
    },
    {
      "pattern": "Missing texture for shopkeeper",
      "severity": "warn",
      "note": "Feature added a custom villager — should not have missing textures."
    }
  ],
  "background_baseline": [
    {
      "pattern": "\\[shopkeeper\\] discount applied to .*",
      "max_count": 50,
      "severity": "warn_if_exceeded",
      "note": "If discounts fire >50 times in one play session, the gate condition is too loose."
    }
  ]
}
```

The builder must include the corresponding `LOGGER.info(...)` calls during
implementation so the `should_see` patterns can fire. The architect explicitly
flags this in the work-unit plan so builders include the required log lines —
without them, every `should_see` pattern would fire `warn_if_missing` on every
session and the watcher becomes noise.

## How findings flow downstream

When the player exits the dev server, the watcher writes
`runs/<loader>/watcher-report.json`. From there:

1. **Handoff summary** — the orchestrator surfaces a compact form of the
   report to the player on dev-server exit, alongside gametest and reviewer
   results.
2. **Reviewer input** — the report is passed to the `reviewer` agent as
   additional context. The reviewer cross-references findings against the
   feature spec:
   - `should_see` patterns with `hit_count: 0` AND no gametest exercising
     that path → coverage gap; flag in review.
   - `warn` / `warn_if_exceeded` items → reviewer-discretion call on whether
     to kick back.
3. **Auto-kick-back** — any finding with `severity: hard_fail` is auto-promoted
   into the kick-back queue as a builder bug report (no reviewer required).
   The builder must address the failure on the next iteration. The kick-back
   counter (capped at 3) increments per cycle; on exhaustion the watcher
   findings are surfaced to the user.

## Adding new baselines

When a play session surfaces a recurring pattern not covered above, add it to
the relevant `<!-- baselines:* -->` block. Format rules:

- One JSON object per pattern.
- POSIX-extended regex. Escape backslashes (`\\.` for a literal dot).
- Severity from the four-value enum above.
- `note` is short (≤ 100 chars). It surfaces in the watcher report context.
- Put the most-specific patterns first; the helper short-circuits per-line on
  the first severity-`hard_fail` match.
- Run a quick sanity check after editing: `scripts/log-watcher.sh
  --rules references/log-watcher-rules.md --log /dev/null --state
  /tmp/check.json --loader neoforge` should parse without `jq` errors.

## Why JSON-in-markdown (not a sibling JSON file)

The baselines could live in a separate `references/log-watcher-baselines.json`,
but keeping them in the rules doc lets us:

1. Document each pattern with prose right next to its definition.
2. Avoid splitting the human-facing rules from the machine-facing patterns —
   reviewers, authors, and the agent all read the same file.
3. Keep the modsmith plugin tree compact (one file per concern).

The helper extracts blocks by HTML-comment marker (`<!-- baselines:universal
-->`), which is mechanical enough that the markdown prose can change freely
without breaking parsing. If the baselines outgrow this format (e.g., > 50
entries per category), promote them to a sibling JSON file and have the rules
doc explain it.
