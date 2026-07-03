# Known-good MC × loader version matrix

These are the **modsmith-vetted combinations** for new mods. The
matrix is also the default `gradle.properties` set the templates render
from. Pick the row that matches your `mc` token (see "Symbolic tokens"
below) and copy the concrete versions; don't mix rows.

When in doubt, **read the live API**: see "How to look up new versions"
at the bottom — that's the source of truth, this table is a snapshot.

## The matrix

Snapshot as of 2026-07 (live-verified by the v0.2.0 validation gate):

| MC version | Loader | Loader version | Build plugin | Java | Mappings | Source |
| --- | --- | --- | --- | --- | --- | --- |
| 1.21.1 | Fabric | fabric-loader 0.19.3 | fabric-loom 1.15.5, id `fabric-loom` (obfuscated pipeline) | 21 | Mojmap + Parchment 2024.11.17-1.21.1 | [meta.fabricmc.net/v2/versions/loader/1.21.1](https://meta.fabricmc.net/v2/versions/loader/1.21.1) |
| 1.21.1 | Fabric API | fabric-api 0.116.13+1.21.1 | — (mod-dep, not plugin) | 21 | — | [meta.fabricmc.net/v2/versions/fabric-api](https://meta.fabricmc.net/v2/versions/fabric-api) |
| 1.21.1 | NeoForge | 21.1.235 (latest of LTS line) | net.neoforged.moddev 2.0.141 | 21 | Mojmap (NeoForge default) + Parchment 2024.11.17-1.21.1 | [versions.neoforged.net/?nfV=21.1](https://versions.neoforged.net/?nfV=21.1) |
| 26.2 | Fabric | fabric-loader 0.19.3 | fabric-loom 1.15.5, id `net.fabricmc.fabric-loom` (no-remap; MC 26+ is unobfuscated) | 25 | none (no mappings block allowed) | [meta.fabricmc.net/v2/versions/loader/26.2](https://meta.fabricmc.net/v2/versions/loader/26.2) |
| 26.2 | Fabric API | fabric-api 0.154.0+26.2 | — | 25 | — | [meta.fabricmc.net/v2/versions/fabric-api](https://meta.fabricmc.net/v2/versions/fabric-api) |
| 26.2 | NeoForge | 26.2.0.7-beta | net.neoforged.moddev 2.0.141 | 25 | Mojmap; Parchment falls back to 1.21.1 (none for 26.2 yet) | [versions.neoforged.net/?nfV=26.2](https://versions.neoforged.net/?nfV=26.2) |

### Obfuscation boundary (MC 26+)

MC 26.x+ ships **unobfuscated**. That flips three things on the Fabric
side, all templated behind the per-MC `is_unobfuscated` flag:

- **Plugin id:** `net.fabricmc.fabric-loom` (Loom's no-remap mode) instead
  of the legacy `fabric-loom` id used for obfuscated MC (< 26).
- **Mappings:** NO `mappings` block — configuring any mappings in
  no-remap mode is a hard configuration error.
- **Mod deps:** plain `implementation` for fabric-loader/fabric-api —
  `modImplementation` is not registered in no-remap mode.

On the NeoForge side, 26.x FML exposes the `FMLLoader.getCurrent()`
instance API; 21.x only has static methods (templated behind
`fml_has_getcurrent`).

### Single plugin-version policy

The templates pin ONE `fabric-loom` version and ONE ModDevGradle version
in the root `build.gradle` plugins block for **all** MC lines — the Loom
jar registers both plugin ids, and the per-line difference is which id a
subproject applies (see the obfuscation boundary above), not the plugin
version. Plugin versions are the single deliberate exception to the
"all versions live in gradle.properties" rule: Gradle's `plugins {}` DSL
needs literal versions, and `/modsmith:doctor` does not flag them.

### Companion versions (not version-axis but commonly needed)

| Component | Version | Notes |
| --- | --- | --- |
| Gradle | 9.2.0 (GA) | Bundled wrapper pin. Required for MDG 2.x. Do not pin RCs — 9.x RCs surfaced hard errors (e.g. core-plugin `apply false`). |
| fabric-loom | 1.15.5 | One version for all MC lines (see policy above). |
| ModDevGradle (MDG) | 2.0.141 | One version for all MC lines, `net.neoforged.moddev`. |
| Foojay resolver convention | 1.0.0 | `org.gradle.toolchains.foojay-resolver-convention`; auto-downloads JDK. |
| MixinExtras (compile-time) | mixinextras-common 0.5.3 | Both loaders bundle MixinExtras at runtime; templates compile against 0.5.3. |
| Parchment (1.21.1) | 2024.11.17-1.21.1 | `parchmentmc.org/docs/getting-started`. |
| Parchment (26.2) | not yet published (as of 2026-07) | resolver falls back to the 1.21.1 artifact; Fabric 26.2 builds don't use Parchment at all (no mappings in no-remap mode). |
| NeoForm (26.2) | 26.2-1 | Consumed by `:common` via MDG `neoFormVersion`. |
| NeoForm (1.21.1) | 1.21.1-20240808.144430 | Timestamp-suffixed revision (older-line format). |

## How modsmith picks a row

`/modsmith:init` asks for an MC version and accepts either a concrete
pin (e.g. `26.2`) or one of these symbolic tokens:

| Token | Meaning | Resolves to (July 2026) |
| --- | --- | --- |
| `latest` | Newest stable Minecraft release | `26.2` |
| `recommended` | NeoForge's `recommended` channel | LTS line (`1.21.1`) |
| `lts` | Latest patch in the current LTS line | `1.21.1` |
| `1.21` | Latest patch in minor `1.21.x` | `1.21.1` |
| `1.21.1`, `26.2` | Exact pin | as written |
| `next` | Latest including pre-releases | `26.3-pre1` or similar |

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
  → versions look like `0.154.0+26.2` (the `+`-tag is the MC version).
  Pick the highest whose `+`-tag matches your MC version.

### NeoForge

- **Index of all lines:** `https://versions.neoforged.net/index.json`
  → JSON of every active MC line (`1.20.1`, `1.21.1`, `26.2`, …).
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
curl -s https://meta.fabricmc.net/v2/versions/loader/26.2 | jq '.[0]'

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
