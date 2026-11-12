# Plugin registry: design (static-first, v1)

Status: design, committed before implementation per the principal's
directive. Branch `codex/issue85-plugin-registry` (off
`codex/issue85-plugin-management` @ `51cec2f`). The registry server and
publisher live in this branch under `tools/plugin-registry/`; the client
integration lands in `packages/libraries/tina_plugin_registry/` plus
`tina plugin` subcommands in `apps/tina_cli`.

Goal: a server/website hosting precompiled plugin components, so users
can discover, inspect, install and run Tina plugins without building
anything — while capability-gated execution stays exactly as it is
today. The registry adds **provenance and transparency, not permission**.

## 1. Registry layout (static-first)

The registry is a directory of files with no dynamic backend in v1. Any
static file server can serve it; the shipped thin axum server adds a
browsable HTML index and correct MIME/cache headers, nothing more.

```text
<registry-root>/
  index.json                  # the catalog: registry metadata + entries
  index.html                  # generated, browsable index page
  blobs/<sha256>.wasm         # content-addressed component artifacts
  keys/registry.pub           # convenience copy of the registry public key
```

- `blobs/<sha256>.wasm`: one immutable artifact per plugin-version,
  addressed by the sha256 of its bytes. Wasm portability means **one
  artifact per plugin-version — no per-platform builds**.
- `index.json`: the only listing document. `blobs/` and `keys/` are
  dead-simple static paths.
- Serving from any static server works because every URL is a plain GET
  of a plain file; the axum server (`registry-server`) exists to render
  `index.html` and to be the documented reference deployment in the
  container demo.

## 2. Entry schema

Each entry of `index.json`'s `entries` array:

```json
{
  "name": "tina/wasm-prompt",
  "version": "0.1.0",
  "description": "Reads the current session id and model into the prompt.",
  "published": "2026-11-11T00:00:00Z",
  "artifact": {
    "sha256": "<64 hex lowercase>",
    "size": 4876970,
    "path": "blobs/<sha256>.wasm"
  },
  "abi": {
    "embedder_abi": 1,
    "world": "tina:plugin-host/session@0.1.0",
    "imports": ["tina:plugin-host/session@0.1.0"],
    "exports": ["tina:plugin/plugin@0.1.0"]
  },
  "capabilities": ["session.read-context"],
  "signature": {
    "scheme": "ed25519-v1",
    "keyid": "<first 16 hex of sha256(pubkey)>",
    "signature": "<base64 of the 64-byte ed25519 signature>"
  }
}
```

Field semantics:

- `name`: registry-unique plugin id, `org/name` or bare name; the install
  cache keys on it.
- `version`: semver. `(name, version)` pairs are unique per index; a
  re-publish with the same pair but a different sha256 is refused by the
  publisher (immutability).
- `artifact.sha256` / `size`: integrity + the blob filename key. The
  client fetches **by content address**, so a tampered index cannot
  redirect a blob fetch to attacker bytes without also breaking the
  hash.
- `abi`: the stamps, matching what the loader validates at admission
  (`pkg/tina_wasm_host/src/plugin_loader.rs`):
  - `embedder_abi`: the payload version of the `tina.embedder-abi` custom
    section (`EMBEDDER_ABI_VERSION = 1`); the host's
    `verify_embedder_abi` preflight rejects anything else, and the
    client checks the same section locally before installing.
  - `world` / `imports` / `exports`: the versioned `tina:*` interface
    strings the component is built against (`tina:plugin-host/
    session@0.1.0` for the production prompt plugin;
    `tina:plugin-probe/engine-service@0.1.0` +
    `tina:plugin-probe/plugin@0.1.0` for probe-world plugins). v1
    records these as **publisher-declared** metadata checked against the
    client's known-good constants for the running engine; extracting the
    import list from component bytes is a v2 item (flagged below).
- `capabilities`: the **requested grants**, from the host's fail-closed
  vocabulary (`session.read-context`, `engine-service-import`,
  `engine-service-call` — `PLUGIN_GRANTS` in `policy.rs`). Users see
  what a plugin wants before installing; unknown grants in a published
  entry are a publisher error (the client warns and the loader would
  reject them at run time anyway).
- `signature`: detached, over the entry. The signed payload is the entry
  object **without** the `signature` field, serialized canonically:
  keys sorted lexicographically recursively, `,`/`:` separators with no
  whitespace, UTF-8, integers plain, strings as-is. Signature: 64-byte
  ed25519 over that payload, base64 (standard, padded).

## 3. Trust model v1

Layered, with the registry adding provenance only:

1. **Integrity**: `sha256(bytes) == entry.artifact.sha256`; blobs are
   fetched by content address and verified before touching the cache.
2. **Provenance**: the entry's ed25519 signature is verified against the
   registry public key **pinned in the client config** (`registry_key`).
   No pinned key → install refuses (fail closed). The registry
   operators' key is separate from the Tina release key
   (`minisign.pub`, which signs release binaries and stays untouched).
3. **Transparency**: `capabilities` are shown at install time and
   recorded; a user installs "read session context" on purpose.
4. **Runtime sandbox**: the existing loader gates are unchanged and
   remain the real sandbox — `verify_embedder_abi` preflight, admission
   shape checks (descriptor/run/service shapes as the admission fixtures
   pin them), the fail-closed grant vocabulary, per-call and
   instantiation deadlines, memory/table limits. Anything beyond granted
   capabilities fails at the loader or surfaces through the approval
   flow exactly as today.

Trust-model v1 limitations, accepted and flagged:

- The index *listing* itself is unsigned: an attacker who controls the
  static host can withdraw or reorder entries (they cannot forge an
  entry, re-point an artifact, or modify an installed file without the
  signature or hash breaking). An index-level signature with timestamp
  and pinning is v2.
- No revocation, no transparency log, no update-feed pinning. Removal =
  entry disappearance; installed copies keep working (the cache is
  local).
- `abi.imports`/`exports` are publisher-declared (cross-checked against
  the embedded stamp client-side); deep import extraction is v2.

### Deviation from the directive, flagged

The directive offered "ed25519/minisign". v1 uses **raw ed25519 with a
documented JSON envelope** instead of the minisign file format.
Grounds: minisign is ed25519 plus a file-format wrapper (trusted
comments, key files) and there is no minisign verifier in the Dart
client's dependency tree — the envelope keeps the client to one small
pure-Dart ed25519 verify while preserving the same trust properties
(key pinned in config, detached signature over canonical bytes). The
repo's existing `minisign.pub` is the release key for binaries; the
registry key is a separate, new key pair, so no compatibility is lost.
If the principal prefers real minisign envelopes, the swap is local to
the signature codec.

## 4. Server and publisher (tools/plugin-registry/)

Rust crate in this branch, two binaries, one shared lib:

- `registry-server`: axum, read-only over a registry root —
  `GET /` (HTML index, generated listing), `GET /index.json`,
  `GET /blobs/<sha256>.wasm` (immutable cache headers),
  `GET /keys/registry.pub`. No write endpoints; publishing is an
  offline CLI step.
- `registry-publish`: builds `index.json` (+ `index.html`) from a seed
  directory of `entry.json` + component files, computes sha256/sizes,
  refuses `(name, version)` collisions with different bytes, signs each
  entry with the operator key file (ed25519-dalek; key file = 32-byte
  seed, hex or base64), and writes blobs under their content address.

Placement rationale: registry operator tooling is product-adjacent and
the directive allows the branch or a tools dir; keeping it beside the
client in the tina branch documents the whole loop in one reviewable
place. A Rust crate is chosen because signing and the axum server are
already-Rust concerns (the wasm.dart workspace shows the pattern), and
the publisher must produce exactly the bytes the Dart client
re-verifies.

## 5. Client integration (tina repo)

New package `packages/libraries/tina_plugin_registry/`:

- `RegistryClient`: fetch + parse `index.json` (against a configured
  URL), verify per-entry signature (pinned key), `verifyArtifact`:
  sha256 over fetched bytes + local `tina.embedder-abi` section parse +
  ABI stamp comparison against the engine constants.
- `PluginCache`: `~/.tina/plugins/<name>/<version>/component.wasm` plus
  an `install.json` (recorded entry + grants + install time). Installs
  are versioned; removal deletes the directory and the config record.
- `RegistryConfig` reader/writer for the `[plugin-registry]` TOML
  section in the global config: `url`, `key` (base64 ed25519 public
  key), `installed` (name → version), `active` (name = the plugin the
  engine mounts). Kept deliberately independent of the settings-layer
  plugin machinery, which at this branch's base predates the capability
  document; merging the registry records into the capability document
  (`CapabilityEntry::Plugin`) rides the capability-merger merge and is
  flagged in §7.

`apps/tina_cli`: `tina plugin` subcommand routing (argv[0] == `plugin`,
dispatched before the main flag schema):

- `tina plugin list` — installed (cache + config) and available
  (registry index, name/version/description/capabilities).
- `tina plugin install <name[@version]>` — resolve entry (latest or
  pinned), verify signature → sha256 → embedded stamp → ABI stamps,
  print the requested capabilities, write the cache, record in config,
  and set `active` if none.
- `tina plugin remove <name>` — delete cache + records; refuse if
  active unless `--force` (and clear `active`).
- `tina plugin info <name>` — full entry JSON for inspection.

Engine mount (still the client's job, still no host changes): when the
config has an `active` plugin, the engine launcher appends
`--plugin-component=<cache path>` plus `--plugin-grant=<recorded
grants>` to the wasm engine argv (`wasmEngineArgv`'s extra arguments),
which is the existing, tested host mount path — `--plugin-component`
reads the artifact as a host file, `verify_embedder_abi` preflights it,
and the engine mounts `tina/wasm-prompt` through the same adapter the
`plugin_lifecycle_probe` exercises. Approval flow for anything beyond
the granted capabilities is the loader's existing behavior.

## 6. Host side: no changes in v1

Plugin components arrive as local files in the cache and flow through
the existing `--plugin-component` path; the host already preflights the
embedder ABI, enforces the grant vocabulary, and runs plugins under
deadlines and memory limits. **No host change is required or made in
v1.** Flagged (not built):

- `--plugin-grant` accepts exactly one literal grant
  (`session.read-context`); richer per-plugin grant lists arrive
  naturally with the capability-document merge (§5) rather than by
  widening the flag.
- A component-path flag exists on the host for the dev flow; the
  embedded-only packaged binary mounts from its frozen bytes. When the
  registry meets the packaged host, the host will need a
  config-preopen-driven mount (read the active plugin's path from the
  snapshot) — a host change, deliberately deferred.
- Manifest-level deep import extraction (v2, §2) would let the loader
  cross-check declared stamps at admission.

## 7. Sequencing

1. This design doc (committed first, before any implementation).
2. `tools/plugin-registry` (server + publisher) with crate tests.
3. `packages/libraries/tina_plugin_registry` (client) with Dart tests
   (signature/hash/ABI verification against fixture vectors, cache
   layout, config round-trip).
4. `tina plugin` subcommands in `apps/tina_cli` with tests.
5. Seed: `entity-decode`, `stateful-proof`, `tina/wasm-prompt` —
   published from `pkg/tina_wasm_host/testdata/plugin_probe/` artifacts
   (wasm.dart side), signed with a generated demo registry key.
6. End-to-end demo in the container: serve → `tina plugin install
   tina/wasm-prompt` (verify + cache + record) → engine launched with
   the installed component → a scripted-provider turn exercises the
   plugin's prompt hook → remove.
