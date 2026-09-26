# Plugins

One document for tina's plugin system: how it works, what ships as
plugins today, and the implementation record of the proposals that
produced it. It consolidates and replaces the former proposal series —
`plugin_runtime.md`, `plugin_architecture.md`,
`plugin_safety_review.md`, `plugin_runtime_pr49_fixes.md`,
`plugin_posture_door.md`, `session_persistence_plugin.md`,
`session-persistence/`, `plugin-first-tools/`, `mcp_clients.md`,
`tina-wasm-proposal.md`, `wasm_ecosystem_research.md`,
`dart2wasm-on-workers-findings.md` — which were deleted when this file
was written; retrieve them from git history if needed. Non-plugin
proposals remain in `docs/proposals/`.

## How the system works

The agent loop and its safety machinery are fixed code; plugins
contribute everything around them. The runtime lives in
`packages/tina_engine/lib/src/runtime/`.

### Descriptors

A plugin is a `PluginDescriptor` (`runtime/plugin.dart`):

- **id** — a lowercase, dot-namespaced string. `tina.*` is reserved for
  built-ins.
- **requires** — an optional set of `ServiceKey`s that must resolve
  before the factory runs.
- **provides** — the service keys the plugin binds, declared up front so
  collisions are caught before any factory runs.
- **factory** — builds the plugin's root object. Factories are
  synchronous.

### Activation

The runtime (`runtime.dart`):

1. Sorts descriptors by id.
2. Validates the whole set: duplicate ids, missing dependencies,
   dependency cycles, two plugins providing one key, undecodable config
   — all fail startup before anything runs.
3. Runs the factories in id order, each returning the plugin's root
   object.
4. On failure, rolls back the partial scope before the error propagates:
   a failed startup leaves nothing half-mounted.

On shutdown, instances are disposed in reverse activation order; child
scopes dispose before their parents. Services resolved from a parent
scope are borrowed, never stopped, when the child dies. Registration
membership is revoked at dispose-start and the id stays reserved until
disposal settles, so a disposed contribution can never be resolved and
an old cleanup can never touch a replacement.

### The factory API

```dart
factory: FnPluginFactory((context) {
  final store = JsonlSessionStore(root); // build the object
  context.own(store.close);              // teardown calls this, once
  return store;                          // becomes the ServiceKey value
})
```

- `context.require(key)` — resolve a declared dependency. A missing key
  throws an error naming the plugin and the key.
- `context.own(cleanup)` — register teardown. Owned cleanups run in
  reverse acquisition order, exactly once — on dispose and on activation
  rollback.
- `context.register(contribution, id: …)` — add to a typed list. Returns
  a `Registration` handle that owns both list membership and an optional
  cleanup: disposing the handle revokes just that contribution, and
  scope teardown backstops it if the handle is dropped.
- `context.child(name)` — open a child scope holding disposable sets.

### The two kinds of plugins

**Service plugins** bind an object under a `ServiceKey<T>`; other code
resolves it by key. Consumers depend on the key, so an alternative
implementation is a different plugin on the same key.

**Contribution plugins** register objects into typed lists — tools,
slash commands, status sources, input routes, chat renderers, provider
decorators. Consumers read the list; plugins only append.

### Ordering as override

Id order is activation order, and therefore override order: an id that
sorts earlier can wrap or replace a later one. The timestamp chat
overlay (`example.timestamp-chat`) decorates the built-in renderer by
sorting before `tina.chat-renderer` and delegating back to it.
Dependencies that must force an order without transferring data use a
marker service key as an order-only edge — that is how the provider
factory pins the decorator stage ahead of itself.

### What is not pluggable

"Baked in" means compiled into the binary and always mounted. Nothing
loads from disk at runtime except skills and config-declared providers —
both data, not code. There is no on-disk plugin loader; adding a
built-in plugin is a code change. The agent loop and the permission
precedence are core, not plugins.

## What ships as plugins today

The canonical inventory — real ids and the files that define them.

**Mounted for every run (`buildExecutionRuntime`):**

| Plugin | Defined in |
| --- | --- |
| `tina.app.spend-ledger` | tina_app `composition/runtime_plugins.dart` — the `SpendLedger` every provider is metered through |
| `tina.app.provider-decorators` | tina_app `composition/runtime_plugins.dart` — retry / rate-limit / metering wrappers |
| `tina.app.provider-factory` | tina_app `composition/runtime_plugins.dart` — the factory resolving configured models |
| `tina.engine.session-store-jsonl` | engine `persistence/session_store_plugin.dart` — binds the store unless a caller pre-binds one |
| `tina.engine.workspace-capabilities` + `-tool-scope` | engine `tools/workspace_tool_plugins.dart` — the workspace tool catalog (skipped when a nested same-project run borrows a live scope) |
| `tina.invocations` + `tina.interrupts` | tina_app `execution/interrupts.dart` — admission identity + pause/resume |
| `tina.index-progress` | tina_app `execution/index_progress_status.dart` — code-index progress service |

**Mounted by the launcher (`bin/tina.dart`, both hosts):**

| Plugin | Defined in |
| --- | --- |
| `tina.chat-renderer` | root `lib/composition/chat_renderer.dart` — default transcript renderer |
| `example.timestamp-chat` | root `lib/composition/timestamp_chat.dart` — time gutter; id sorts first, delegates back |
| `tina.git-input` / `tina.intent-input` | tina_app `execution/` — git-state and input-intent classification; inert headless |
| `tina.tool.explore-project` | root `lib/composition/explore_project.dart` — repo-exploration tool; fails closed without Typesafe config |
| `tina.plan` / `tina.goal` | tina_app `plans/` `goals/` (stores) + root `lib/composition/` (strip sources, renderers, commands) |
| `tina.token-status` | root `lib/composition/token_status.dart` — token-spend counter |
| `tina.index-status` | root `lib/composition/index_status.dart` — indexing line on the strip |
| `tina.version-status-service` + `tina.version-status` | tina_app `execution/version_status.dart` + root `lib/composition/version_status.dart` — release check and strip alert |

**Host command scopes** (child runtimes, one each): `tina.commands`
(interactive, root `lib/session_commands/session_command_handlers.dart`)
and `tina.headless-commands` (headless, root
`lib/session_commands/headless_commands.dart`).

**Persistence is the seam case: the store is a plugin, the format is
core.** The `SessionStore` interface, JSONL format, per-session layout,
locks, and index are compiled in; the plugin binds an instance under
`sessionStoreServiceKey`. Config selects a backend with
`[sessions] provider` (one id, `jsonl`, ships); consumers resolve only
through the key.

Not plugins: the "auto" permission judge (`PermissionClassifier`, built
directly in `buildExecutionRuntime`, best-effort), config-declared
providers, and models.dev-seeded providers (data, seeded at startup).

## The implementation record

### Shipped — the baseline runtime (PR #49)

The proposal series converged on one implementation plan (the former
`plugin_runtime.md`); its **§2 baseline** is what shipped:

- Descriptor/scope/runtime lifecycle with id-order activation, upfront
  validation, topological ordering with id tiebreak, `activateSync`.
- Safety properties from the safety review: admission-gate closure,
  revoke-at-dispose-start, id reservation during disposal, rollback on
  failed activation (awaited before the error rethrows), terminal failed
  instances, children-before-parents disposal, borrowed parent bindings
  untouched, reverse-order cleanup continuing past failures, idempotent
  memoized dispose.
- Diagnostics (`describe()` / `RuntimeDescription`) and a ~30-test
  runtime suite (`packages/tina_engine/test/runtime/`).
- First consumers migrated: spend ledger, provider decorators + factory,
  session store, workspace capabilities/tool scope, invocations and
  interrupts, git/intent inputs, version/index status, plan/goal stores,
  chat renderers.

The `plugin_posture_door.md` boundary refactor landed as part of this;
its approval-provenance persistence/UI half did **not** (below).

### Shipped — application work from the same proposals

- **Session persistence (SP1–SP5, all landed 2026-09-22…26):** service
  key + JSONL plugin, `SessionIndex` (resume/`--list`), `[sessions]`
  provider selection with fail-fast on unknown ids,
  `LockableSessionStore` capability (the launcher no longer type-checks
  the store), in-memory backend running the same contract suite.
- **Plugin-first tools PT0:** launcher plugins replace conditional
  mounting; `explore_project` crosses the execution scope like any
  registry tool and fails closed without Typesafe config.
- **Spawning constraints, Changes 1–5:** workflow tools unmounted for
  agents; concurrent subagents capped at 3; render-only subagent panels;
  subagents inherit the main asker (`withOriginLabel`); origin-labeled
  approval cards.
- **Remote-answerable approvals, Parts 1–2 only:** the asker seam and
  `ApprovalTarget` decoupling ship; the daemon does not (below).
- **Hierarchical classifiers, slices 1–3:** `TreeSource`/`TreePlan`/
  `runTree` in `packages/classifier`, wired into project classification
  via `.tina/programs`.

### Not started — the target refactor (former `plugin_runtime.md` §3–§9)

The plan's remaining scope, in its own terms. All twelve §12 checklist
items are open.

- **§3 package split:** `tina_plugin_contracts` (metadata-only
  descriptors — today `decodeConfig` and `factory` are executable
  closures on the descriptor), `tina_plugin_local`, and extracted
  feature packages.
- **§4 loader:** `PluginLoader`/`LoadedPlugin`, `instanceId`, capability
  accessors, `CallContext`, metadata-only discovery with revalidation at
  load.
- **§4 compatibility:** semver compatibility ranges on descriptors,
  rejected before factories run. Nothing versioned today.
- **§5 structured failures and data:** `PluginException`/`PluginError`
  with the `plugin.*` code namespace (today: raw `StateError` /
  `FormatException` / `PluginCompositionError`); closed `JsonValue`
  algebra and DTO round-trip conformance.
- **§6 host services:** plan host, approval/posture host, git/intent
  analysis hosts, plugin storage host, logging host, clock/scheduling
  host, operation/event host, workspace/model hosts. Today plugins
  receive concrete app objects via `ServiceKey`.
- **Phases P1–P7:** contracts (P1) and loader (P2) as above; revocable
  contract handles instead of live shared objects (P3); classifier
  plugins extracted out of `tina_app` (P4); plan plugin behind a narrow
  host instead of the concrete `PlanStore` (P5); integration closure for
  UI renderers, providers, drivers, skills, persistence bridges (P6) —
  `StatusSource.read` still returns `Object?` with runtime-type renderer
  dispatch; independent-loader proof (P7) — the §1 acceptance criterion
  ("application logic runs against an alternative `PluginLoader`") is
  unmet by construction.

### Not started — separate plugin proposals

- **PT1, agent tool factories:** `AgentToolFactory` does not exist;
  `agent_composition.dart` remains the hand-wired assembly line (region
  tools, ask-user, channel/delegate wrappers).
- **PT2, tool-declared permission defaults:** no `interactiveDefault`
  getter on `Tool`; the interactive-main allow-table is still hardcoded
  in `agent_composition.dart` (11 entries). Note: subagent asker
  inheritance is spawning-constraints Change 4, **not** PT2.
- **MCP clients:** zero MCP code on `main` (config, transport, tool
  bridge, `/mcp` — all absent). The proposal stages it M0–M5.
- **WASM plugin backend:** no WASM plugin support. The safety review's
  standing decision keeps the local Dart backend and defers backend
  selection. Companion findings: `dart compile wasm` runs on Cloudflare
  Workers (spike verified locally; artifact in `spikes/dart_wasm_worker/`,
  not deployed); ecosystem research notes are historical.
- **Approval provenance (posture-door follow-up) and
  remote-answerable approvals Part 3+:** no ask store, no `/approve`,
  no daemon.

## Live obligations

- `test/composition/agent_surface_golden_test.dart` pins the default
  tool list and permission decisions byte-for-byte. Any PT1/PT2-style
  refactor must reproduce them; change a golden only with an
  intentional-change note (per the test's own failure message).
- When work from this document lands, update the relevant section here
  in the same commit — this file is the single status of record for the
  plugin system.
