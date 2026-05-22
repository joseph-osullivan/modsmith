# Known-good MC × loader version matrix

These are the **modsmith-vetted combinations** for new mods. The
matrix is also the default `gradle.properties` set the templates render
from. Pick the row that matches your `mc` token (see "Symbolic tokens"
below) and copy the concrete versions; don't mix rows.

When in doubt, **read the live API**: see "How to look up new versions"
at the bottom — that's the source of truth, this table is a snapshot.

## The matrix

| MC version | Loader | Loader version | Build plugin | Java | Mappings | Source |
| --- | --- | --- | --- | --- | --- | --- |
| 1.21.1 | Fabric | fabric-loader 0.16.10 | fabric-loom 1.7 | 21 | Yarn 1.21.1+build.3 (or Mojmap via loom-mappings-mojmap) | [meta.fabricmc.net/v2/versions/loader/1.21.1](https://meta.fabricmc.net/v2/versions/loader/1.21.1) |
| 1.21.1 | NeoForge | 21.1.215 (latest of LTS line as of May 2026) | net.neoforged.moddev 2.0.78 | 21 | Mojmap (NeoForge default) + Parchment 2024.11.17-1.21.1 | [versions.neoforged.net/?nfV=21.1](https://versions.neoforged.net/?nfV=21.1) |
| 1.21.1 | Fabric API | fabric-api 0.116.4+1.21.1 | — (mod-dep, not plugin) | 21 | — | [meta.fabricmc.net/v2/versions/fabric-api](https://meta.fabricmc.net/v2/versions/fabric-api) |
| 26.1.2 | Fabric | fabric-loader 0.18.6 | fabric-loom (current; ≥ 1.10) | 25 | Mojmap (Yarn lags 26.1) | [meta.fabricmc.net/v2/versions/loader/26.1.2](https://meta.fabricmc.net/v2/versions/loader/26.1.2) |
| 26.1.2 | Fabric API | fabric-api 0.145.4+26.1.2 | — | 25 | — | [meta.fabricmc.net/v2/versions/fabric-api](https://meta.fabricmc.net/v2/versions/fabric-api) |
| 26.1.2 | NeoForge | 26.1.2.43-beta | net.neoforged.moddev 2.0.141 | 25 | Mojmap + Parchment (2026.04.20-26.1 once published) | [versions.neoforged.net/?nfV=26.1](https://versions.neoforged.net/?nfV=26.1) |

### Companion versions (not version-axis but commonly needed)

| Component | Version | Notes |
| --- | --- | --- |
| Gradle | 9.2 | Wrapper. Required for MDG 2.x. |
| Foojay resolver convention | 1.0.0 | `org.gradle.toolchains.foojay-resolver-convention`; auto-downloads JDK. |
| MixinExtras (1.21.x line) | 0.4.3 | Bundled with NeoForge 21.1 and Fabric Loom; only declare if you use the API directly. |
| MixinExtras (26.1 line) | 0.6.x | Bundled with NeoForge 26.1; native mixin support — no plugin block. |
| Parchment (1.21.1) | 2024.11.17-1.21.1 | `parchmentmc.org/docs/getting-started`. |
| Parchment (26.1.2) | not yet published (as of 2026-05) | use Mojmap-only until released. |
| ModDevGradle (MDG) | 2.0.141 (26.1) / 2.0.78 (1.21.1) | Loader-side gradle plugin, `net.neoforged.moddev`. |
| fabric-loom | 1.10+ (26.1) / 1.7 (1.21.1) | Loader-side gradle plugin, `fabric-loom`. |

## How modsmith picks a row

`/modsmith:init` asks for an MC version and accepts either a concrete
pin (e.g. `26.1.2`) or one of these symbolic tokens:

| Token | Meaning | Resolves to (May 2026) |
| --- | --- | --- |
| `latest` | Newest stable Minecraft release | `26.1.2` |
| `recommended` | NeoForge's `recommended` channel | `21.1.215` (LTS line) |
| `lts` | Latest patch in the current LTS line | `1.21.1` |
| `1.21` | Latest patch in minor `1.21.x` | `1.21.1` |
| `1.21.1`, `26.1.2` | Exact pin | as written |
| `next` | Latest including pre-releases | `26.1.3-pre1` or similar |

`scripts/resolve-versions.sh` converts tokens to concrete pins by hitting
the live APIs (next section). **Resolved tokens are written into
`gradle.properties` as concrete numbers** — no symbolic refs are persisted.

## How to look up new versions

The matrix is a snapshot. When you need fresher data, query the source-of-truth APIs.

### Fabric

- **Game versions:** `https://meta.fabricmc.net/v2/versions/game`
  → JSON array of every published MC version with `stable: true|false`.
- **Loader versions for a specific game:**
  `https://meta.fabricmc.net/v2/versions/loader/{game}`
  → array of compatible loader versions, newest first; first entry
  with `stable: true` is the answer.
- **Yarn mappings for a specific game:**
  `https://meta.fabricmc.net/v2/versions/yarn/{game}`
  → newest first; pick `stable: true`.
- **Fabric API (the mod, not the loader):**
  Maven Central or `https://maven.fabricmc.net/net/fabricmc/fabric-api/fabric-api/maven-metadata.xml`
  → versions look like `0.145.4+26.1.2` (the `+`-tag is the MC version).
  Pick the highest whose `+`-tag matches your MC version.

### NeoForge

- **Index of all lines:** `https://versions.neoforged.net/index.json`
  → JSON of every active MC line (`1.20.1`, `1.21.1`, `26.1`, …).
- **Per-line:** `https://versions.neoforged.net/?nfV={line}` (HTML)
  → human-readable list of `latest`, `recommended`, `next` for that
  MC line. The JSON form lives at the maven metadata:
  `https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml`.
- **Token semantics:**
  - `latest` — newest release on that MC line (may be a beta if no
    stable release yet).
  - `recommended` — newest tagged-recommended; the safe-default.
    NeoForge marks a build recommended after it has soaked for a few
    days without major issues.
  - `next` — newest including pre-release/beta builds.

### Parchment

- **Releases:** `https://parchmentmc.org/docs/getting-started` lists the
  current per-MC version pins (e.g. `2024.11.17-1.21.1`). There is no
  JSON API; the page is the source of truth.
- **Maven coordinate:**
  `org.parchmentmc.data:parchment-{mc}:{date}@zip` for the data;
  Parchment is consumed via the `parchment` config in
  `loom` or via NeoForge's MDG (different invocation per plugin).

### Verifying a candidate row

Before pinning a new row in this matrix, run:

```bash
# Fabric side — sanity check that loader + API exist for this MC
curl -s https://meta.fabricmc.net/v2/versions/loader/26.1.2 | jq '.[0]'

# NeoForge side — sanity check that the build exists
curl -s https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml \
  | grep '<version>' | tail -20
```

If both APIs serve a stable version, the row is publishable. If only
one side does (e.g. NeoForge has shipped but Fabric hasn't yet for a
brand-new MC), the row is `fabric: pending`; modsmith `init` will
refuse to scaffold a Fabric subproject in that case.

## When to bump

- **Patch-level Loader/MDG bumps** are safe; `/modsmith:doctor` warns
  when pinned versions fall ≥ 3 releases behind latest.
- **MC version bumps** are a structural migration (renamed classes,
  package moves — see `landmines.md`). Treat as a separate feature run
  through `/modsmith:develop`, not a one-line gradle edit.
- **Major Loader/MDG bumps** (e.g. fabric-loom 1.x → 2.x, MDG 2.x →
  3.x) often change DSL — read the plugin's CHANGELOG before updating
  templates.
