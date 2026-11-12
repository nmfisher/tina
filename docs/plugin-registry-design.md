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
- `capabilities`: the **requested access**, one object per capability.
  This is the consent manifest: the installer shows these objects, the
  user approves or denies each one, and the approved set is recorded as
  the plugin's grants **in the same format** the loader enforces
  (§4, §6). The object schema:

  ```json
  {
    "id": "network",                  // the capability id (below)
    "required": false,                // see denial semantics (§4.2)
    "summary": "Call the weather API.",  // one human line, shown verbatim
    ...                                // id-specific parameters (below)
  }
  ```

  Capability vocabulary v1 (ids, parameters, enforcement mapping):

  - `session.read-context` — the existing grant: read the current
    session id and model. Parameterless. This is the only grant the
    running host accepts today (`PLUGIN_GRANTS` in `policy.rs`);
    `engine-service-import` / `engine-service-call` remain probe-world
    grants in the same vocabulary.
  - `session-store` — conversation history in the session store.
    Parameters: `access`: `"redacted-read"` (default offer, §4.4) or
    `"read"`. Parameterless encoding of the default tier is the bare id.
    Default **DENY** (§4.4). Host enforcement is a designed shape, not
    built in v1 (§7).
  - `filesystem` — preopened paths in the plugin's Store. Parameters:
    `mode`: `"ro"` or `"rw"`; `paths`: a subset vocabulary —
    `"workspace"`, `"config"`, or absolute paths. No grant = no preopen
    (§7). Host enforcement is a designed shape, not built in v1.
  - `network` — outbound HTTP through mediated calls. Parameters:
    `domains`: allowlist of exact hostnames (no wildcards in v1).
    Host enforcement is a designed shape, not built in v1.

  The **recorded grant string** for an approved capability is the
  canonical parameter encoding of the same object — `<id>` when no
  parameters, otherwise `<id>:<key>=<value>[,<key>=<value>]` with keys
  and values sorted (e.g. `session-store:access=redacted-read`,
  `filesystem:mode=ro,paths=workspace`,
  `network:domains=api.weather.example`). One manifest object ↔ one
  grant string ↔ one loader decision, so the installer consent maps 1:1
  onto enforcement. Unknown `id`s in a published entry are a publisher
  error; the client warns, records nothing for the unknown id, and the
  loader would fail closed at run time anyway.
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
4. **Consent**: nothing in the three sensitive surfaces — session store,
   filesystem, network — is granted without an explicit per-capability
   user decision at install time (§4); first-time runtime needs go
   through the existing approval flow (§4.3).
5. **Runtime sandbox**: the existing loader gates are unchanged and
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

## 4. User consent for plugin access

The user must be asked before a plugin can access (a) the session
store, (b) the filesystem, (c) the network. Consent is per capability,
at two points: install time (the manifest, §4.1–4.2) and run time
(escalation, §4.3). The session store is additionally special-cased as
sensitive (§4.4).

### 4.1 Install-time manifest consent

`install` renders the entry's `capabilities` manifest — one block per
capability, verbatim `summary` plus the decoded parameters — and asks
approve/deny for each, remembering the decision per capability id:

```text
tina/wasm-prompt 0.1.0 requests:

  [1/2] session.read-context (optional)
        Read the current session id and model name.
        Grant? [y/N]: y
  [2/2] session-store:access=redacted-read (optional)
        Read redacted past-conversation history: ids, roles and
        lengths — message bodies are NOT included.
        Grant? [y/N]: n

Installing without session-store; the plugin will see denials if it
uses it.
```

Rules:

- Every capability in the manifest is asked. There is no "accept all";
  scripts use explicit `--grant <id>` opt-ins (§4.2).
- The approved set is recorded **as the canonical grant strings** (§2)
  in the `[plugin-registry]` config section (the plugin's grants), and
  — once the capability-document machinery merges into this lineage —
  into the capability document's `Plugin { plugin, grants }` entry.
  One manifest object ↔ one grant string ↔ one loader decision.
- Denied + `required: false` → **install and run without it**: the
  plugin degrades (its calls hit the loader's fail-closed denials),
  which keeps installation useful and honest about partial function.
- Denied + `required: true` → **do not install**: the plugin declares
  it cannot fulfil its purpose without the capability; proceeding would
  ship a knowingly broken install.
- **Recommendation recorded:** install-but-degrade for optional
  capabilities, refuse-installing for required ones. The alternative
  (refuse on any denial) makes partial-utility plugins uninstallable;
  the loader already knows how to deny.
- The mount passes only grants the **running host accepts** (today:
  `session.read-context`). Recorded-but-not-yet-enforced grants
  (`session-store`, `filesystem`, `network`) are printed as recorded
  but unenforced-by-this-engine — no false security. Nothing unknown is
  ever mounted.

### 4.2 Non-interactive installs

Scripts and CI must not get silent consent. Non-interactive install:

- grants are opt-in only, via repeated `--grant <canonical-id>`
  flags (e.g. `--grant session.read-context`);
- manifest capabilities not explicitly granted are DENIED;
- a denied `required: true` capability aborts the install;
- the installer prints the decision summary (granted/denied per id) so
  logs show what was consented.

### 4.3 Runtime escalation

First-time or one-off needs beyond the recorded grants go through the
**existing approval flow**: the plugin's mediated call fails closed
(`denied`), the engine surfaces the need, and the user approves or
denies in the normal prompt; **always-allow** upgrades the grant
persistently via `tina:policy` escalation (the widening mechanism
already exists: `CapabilityEntry::Plugin` + the widen path). The
persisted upgrade records the same canonical grant string, so
install-time consent and runtime upgrades stay one format. Flagged:
the escalation plumbing lands with the capability-document merge into
this lineage; until then the loader's fail-closed denials are the
runtime answer to un-granted needs.

### 4.4 Session store is sensitive — default DENY

The session store holds the whole conversation history. Default deny;
the manifest proposes tiers rather than a blanket grant, and the
consent copy must say what history means:

- **Tiers (recommendation):** offer `redacted-read` as the default
  tier, `read` (full) as the rarer explicit tier, and defer
  read/write access entirely. Rationale: the mediation broker can
  redact mechanically (fields kept: session id, model, turn count,
  token totals, message roles and lengths; message bodies dropped),
  which covers the honest use cases (recall aids, session analytics)
  with a bounded blast radius; full read is a real grant for real need;
  write access to history invites tampering and is not worth v1.
- **Redacted subset feasibility:** feasible and recommended as the
  default — redaction lives in the mediation layer (the broker that
  mediates plugin calls), not in the plugin, so the plugin cannot opt
  out of it. It is a designed shape, not built in v1 (host-side).
- **Consent wording (proposal, shown verbatim by the installer):**

  ```text
  session-store:access=redacted-read (optional)
    Read PAST CONVERSATION HISTORY from this machine's session store —
    redacted: session ids, model names, message roles and lengths only.
    Message text is NOT included. Default is denied.
    Grant? [y/N]:
  ```

  and for the full tier:

  ```text
  session-store:access=read (optional)
    Read FULL PAST CONVERSATION HISTORY from this machine's session
    store, including message text. This is everything you have said in
    Tina sessions. Default is denied.
    Grant? [y/N]:
  ```

  Wording rules: name the surface plainly ("conversation history"),
  state the default (denied), and for the full tier say the worst case
  in one sentence ("everything you have said").

## 5. Server and publisher (tools/plugin-registry/)

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

## 6. Client integration (tina repo)

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
  key), `installed` (name → version + the approved grant strings),
  `active` (name = the plugin the engine mounts). Kept deliberately
  independent of the settings-layer plugin machinery, which at this
  branch's base predates the capability document; merging the registry
  records into the capability document (`CapabilityEntry::Plugin`)
  rides the capability-merger merge and is flagged in §7.

`apps/tina_cli`: `tina plugin` subcommand routing (argv[0] == `plugin`,
dispatched before the main flag schema):

- `tina plugin list` — installed (cache + config) and available
  (registry index, name/version/description/capabilities).
- `tina plugin install <name[@version]>` — resolve entry (latest or
  pinned), verify signature → sha256 → embedded stamp → ABI stamps,
  run the **manifest consent flow** (§4.1; non-interactive rules in
  §4.2), write the cache with the approved grants, record in config,
  and set `active` if none. The printed summary lists granted and
  denied capabilities and flags recorded-but-not-yet-enforced grants.
- `tina plugin remove <name>` — delete cache + records; refuse if
  active unless `--force` (and clear `active`).
- `tina plugin info <name>` — full entry JSON for inspection.

Engine mount (still the client's job, still no host changes): when the
config has an `active` plugin, the engine launcher appends
`--plugin-component=<cache path>` plus the host-accepted grants
(`--plugin-grant=session.read-context` today; recorded grants the
running host does not accept are printed as recorded-but-unenforced)
to the wasm engine argv (`wasmEngineArgv`'s extra arguments), which is
the existing, tested host mount path — `--plugin-component` reads the
artifact as a host file, `verify_embedder_abi` preflights it, and the
engine mounts `tina/wasm-prompt` through the same adapter the
`plugin_lifecycle_probe` exercises. Approval flow for anything beyond
the granted capabilities is the loader's existing behavior (§4.3).

## 7. Host side: no changes in v1

Plugin components arrive as local files in the cache and flow through
the existing `--plugin-component` path; the host already preflights the
embedder ABI, enforces the grant vocabulary, and runs plugins under
deadlines and memory limits. **No host change is required or made in
v1.** Flagged (not built):

- `--plugin-grant` accepts exactly one literal grant
  (`session.read-context`); richer per-plugin grant lists arrive
  naturally with the capability-document merge (§6) rather than by
  widening the flag.
- A component-path flag exists on the host for the dev flow; the
  embedded-only packaged binary mounts from its frozen bytes. When the
  registry meets the packaged host, the host will need a
  config-preopen-driven mount (read the active plugin's path from the
  snapshot) — a host change, deliberately deferred.
- Manifest-level deep import extraction (v2, §2) would let the loader
  cross-check declared stamps at admission.

## 8. Sequencing

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
   tina/wasm-prompt` with the interactive consent flow (approve
   `session.read-context`, deny an optional capability to show
   degradation) → verify + cache + record → engine launched with the
   installed component and the approved grant → a scripted-provider
   turn exercises the plugin's prompt hook → remove.
