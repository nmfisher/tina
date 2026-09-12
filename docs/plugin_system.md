# Plugin system

Status: implemented (Dart runtime); no loader, no external plugins.
Date: 2026-09-12.

Tina's built-in features (tools, providers, guards, hooks, prompt sections,
the agent driver) are wired through a plugin runtime instead of hand-built
composition code. The runtime was introduced by PR #49 and is pure Dart.

What exists:

- A plugin lifecycle with typed services, owned resources, reversible
  registrations, validation before activation, and rollback on failure.
  Code: `packages/tina_engine/lib/src/runtime/` (`contracts.dart`,
  `plugin.dart`, `runtime.dart`).
- A default execution profile of five built-in plugins mounted by the app
  composition. Code: `packages/tina_app/lib/src/composition/`
  (`runtime_plugins.dart`, `execution_profile.dart`, `execution_runtime.dart`).

What does not exist:

- No plugin loader and no dynamic discovery. A plugin is a
  `PluginDescriptor` built by Dart code; adding one means recompiling.
  This is deliberate: tools are a code change, not a config change.
- No WASM plugins. The WASM host in `tool/dart_wasmtime` is a Phase 0
  prototype used to measure and harden a sandboxed guest (see
  [`wasm_plugin_support.md`](proposals/wasm_plugin_support.md) and the
  Phase 0 results doc). It is not part of the plugin runtime and not
  shipped in any product path.
- No user-facing plugin configuration. The runtime can decode per-plugin
  config blocks (`PluginDescriptor.decodeConfig` over a map keyed by plugin
  id), but no TOML surface or CLI flag populates that map today.
- No async factories. A factory returns its service synchronously; cleanup
  functions may be async (`FutureOr`).

This document describes the system as implemented. The plan it came from is
[`plugin_runtime.md`](proposals/plugin_runtime.md); the review that shaped
the current code is [`plugin_runtime_pr49_fixes.md`](proposals/plugin_runtime_pr49_fixes.md).

## Runtime contracts

`packages/tina_engine/lib/src/runtime/contracts.dart`:

- `ServiceKey<T>` — a typed name for a service. Equality is by id string,
  so keys can be constants shared across packages.
- `Registration` — one reversible registration in a scope. Disposal is
  idempotent, and a hook can revoke the registration while it is starting
  (its id stays reserved until disposal completes, so nothing else can take
  it in between).
- `ScopeResources` — reverse-order cleanup of owned resources. It keeps
  going past individual errors and rethrows the first one at the end.
- `PluginLifecycleState` — `pending → activating → active → stopping →
  disposed`.

`plugin.dart`:

- `PluginDescriptor` — `id`, `requires` (service keys), `provides`
  (service keys), optional `decodeConfig`, and a `factory`.
- `FnPluginFactory` — function form of a factory for inline plugins.
- `PluginContext` — what one factory may do: `require()` a dependency,
  `own()` a cleanup function, `register()` a reversible contribution, and
  `child()` a nested scope.
- `PluginScope` — holds services and contributions. Lookup falls back to a
  parent scope (how a borrowed scope is exposed read-only). Providing a key
  that is already bound throws unless `replace: true`. Contributions are
  revoked by identity, and teardown of registered pieces is a backstop if a
  plugin forgets to clean up.

`runtime.dart` — `PluginRuntime`:

- Validation happens before any factory runs: duplicate plugin ids, missing
  dependencies, dependency cycles, colliding providers for one key (unless
  a provider was chosen with `select()`), and undecodable config.
- Activation is synchronous (`activateSync`; `activate` awaits rollback
  then rethrows with the original stack). Order is a Kahn topological sort
  of the `requires`/`provides` edges, ties broken by plugin id.
- A failing plugin rolls back the activation: the admission tree is closed,
  children before parents. The runtime is then terminal (`isFailed`).
  Teardown errors are logged, never allowed to mask the original failure.
- `describe()` reports per-plugin lifecycle state and dependency edges for
  diagnostics. `dispose()` disposes children first, then the root, and is
  idempotent.

## Extensions the runtime carries

All of these ride the same scope; a plugin registers them, a consumer reads
them back in registration order:

- **Tools** (`tools/project_tool_plugins.dart`, `agent/project_tool_scope.dart`):
  one plugin per tool, built from `ProjectCapabilities`. The registry
  exposes a frozen 12-tool catalog (`kProjectToolCatalog`); `web_search`
  joins after it only when a provider API key is configured (Tavily preferred,
  Brave as fallback). `toolRegistryFromScope` throws on duplicate tool names;
  order is catalog rank first. Tool profiles (`read-only`, `full`) filter
  the registry; `toolsFromPolicy` restores a tool set for a resumed session.
  The `write_summary` tool is a singleton service on the scope, not a
  registry contribution.
- **Guards** (`agent/tool_guards.dart`): deny-only checks. They combine
  fail-closed (`combineGuardBlocks` treats a throw as a block); execution
  order is policy, then phase, then extras — registration order is not
  execution precedence.
- **Execution hooks** (`agent/tool_hooks.dart`): wrap a tool call. The input
  on `ToolCallContext` is unmodifiable and carries a cancel probe; a hook's
  delegate runs exactly once and a hook that throws fails the call closed.
- **Result hooks**: the first non-null verdict wins; the legacy
  `Agent.resultVerifier` runs first in the same stage.
- **Observers**: additive, exceptions contained, never change the outcome.
- **Prompt contributors** (`agent/system_prompt.dart`): registered sections,
  read back by `promptContributorsFromScope` in registration order.
- **Agent driver** (`agent/agent_driver.dart`): `AgentDriver` is the seam
  that replaces the turn loop; the default factory wraps the existing
  `Agent` byte-identically. A driver factory can be mounted as a plugin
  (`driverPlugin`, id `tina.engine.driver`).

The executor's final authority and cancellation check runs inside the
innermost delegate (`agent/tool_executor.dart`), so no hook can slip a tool
call past a mode change or a cancelled turn.

## The default execution profile

`buildExecutionRuntime` (`packages/tina_app/lib/src/composition/execution_runtime.dart`)
mounts five plugins, in this declared order:

1. `tina.app.spend-ledger` — the conversation-wide `SpendLedger`. Created
   before anything can build a provider, so metering covers every provider
   from the first wire call.
2. `tina.app.provider-decorators` — registers each `ProviderDecorator` as a
   scope contribution and provides an ordering marker key. Empty by default.
3. `tina.app.provider-factory` — the conversation-owned `LlmProviderFactory`.
   Requires the ledger key and (optionally) the decorator marker — an
   order-only edge, nothing is read through it. Every provider it builds is
   wrapped in a `MeteringProvider` first, with decorator contributions
   wrapped around it.
4. `tina.engine.project-capabilities` — filesystem/process/lock
   capabilities for the project.
5. `tina.engine.project-tool-scope` — the tool scope assembled from those
   capabilities (requires the capabilities key, which fixes the order).

Properties of the composition:

- **Borrowing.** A nested same-project run can borrow a live
  `ProjectToolScope` instead of building its own. The profile is then
  trimmed to the plugins that are not project-owned
  (`borrowedScopePlugins`), and the borrowed scope is exposed through a
  parent scope — lookup works, teardown never touches it, and the lender
  still releases its own resources exactly once. Trimming selects by
  ownership, not by an allowlist of known ids, so extensions the list does
  not know (a custom driver plugin) survive.
- **Validation before activation.** The mounted profile must declare the
  ledger, the provider factory, and (unless borrowing) a tool-scope stage.
  A profile missing any of them fails with a `PluginCompositionError`
  before any factory runs. After activation the bound services are
  re-checked, so a plugin that declared a key but failed to bind it also
  surfaces as a composition error.
- **Cleanup ownership before activation.** The runtime's teardown is owned
  from the moment the resource owner exists, so anything acquired during
  activation is released even if a later composition step throws.
- **Driver resolution.** The explicit `driverFactory` parameter wins;
  otherwise the factory mounted on the scope under
  `agentDriverFactoryServiceKey`; otherwise the default. Guards, hooks,
  observers, and prompt sections are read from the scope and wired into
  every delegated driver build.

## Deliberately out of scope

- A loader, discovery, or third-party plugin packages (see top).
- Command and TUI/frontend features mounted through the lifecycle (plan
  phases P6–P8). Commands and workflows are still composed by hand.
- User-facing plugin config or profiles-as-data. Profiles are Dart
  functions; the effective composition is inspectable in code via
  `PluginRuntime.describe()`.
