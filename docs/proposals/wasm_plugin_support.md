# WASM plugin support

Status: proposal. Depends on PR #49 (`asb/plugin-runtime`, the plugin
runtime). No code is written here.

Part 1 reviews the plugin runtime as built. Part 2 proposes how a plugin
could be a WebAssembly module instead of in-process Dart.

---

## Part 1 — the plugin runtime as built (PR #49)

### What a plugin is today

A plugin is a `PluginDescriptor` (`packages/tina_engine/lib/src/runtime/plugin.dart`):
an `id`, a set of `provides` service keys, a set of `requires` service keys,
an optional `decodeConfig`, and a **synchronous** factory
(`FnPluginFactory.build`). The factory receives a `PluginContext` bound to the
runtime's root `PluginScope` and can:

- `require` a service key (throws if unbound in scope or parent chain),
- `lookup` a service key optionally,
- `provide` a service into the scope (duplicate binding in the same scope
  throws; `replace` is explicit),
- `register` a contribution under a stable id, with an optional dispose
  callback, returning a `Registration`.

A contribution is any `Object`. Nothing constrains its type at registration
time; typing happens at the consumption site, where the assembly helpers
filter `scope.contributions` with `is` checks: `toolGuardsFromScope`,
`toolExecutionHooksFromScope`, `toolResultHooksFromScope`,
`toolObserversFromScope` (`tool_guards.dart`, `tool_hooks.dart`), and the
`contribution is Tool` pass in `toolRegistryFromScope`
(`project_tool_plugins.dart`). So a plugin "can contribute" whatever the
engine has taught the assembly to look for: tools, guards, execution hooks,
result hooks, observers. It can also provide services other plugins require.

`ServiceKey<T>` (`contracts.dart`) is namespaced typed identity; two keys with
the same id string name the same service. Lifecycle is the
`PluginLifecycleState` ladder `pending → activating → active → stopping →
disposed`.

### Lifetime and reach

- Factories are synchronous. `PluginRuntime.activateSync` runs validation and
  every factory to completion synchronously; `activate()` is the async twin.
  Activation runs exactly once per runtime (`_activationStarted`).
- Validation (`_validate`) rejects duplicate ids, multi-provider keys without
  a `select()` winner, missing requires, cycles (`_assertNoCycles`), and bad
  config — all before any factory runs. Config is decoded up front per
  plugin block via `PluginConfigDecoder`.
- Activation order is Kahn's algorithm over requires-edges with ties broken
  by plugin id ascending — deterministic.
- A factory failure rolls the runtime back (`_rollback`): tree-wide admission
  close, children disposed before the root, errors collected and logged
  without masking the composition error. A failed runtime is terminal
  (`isFailed`); retry means constructing a new runtime.
- Reach is the scope tree: a plugin can look up anything in its scope or a
  parent (borrowed services are never disposed by the borrower), create child
  scopes, and own resources through `ScopeResources`. Disposal is reverse
  acquisition order; `Registration.onDisposeStart` revokes registry
  membership the moment disposal begins, and identity-based revocation means
  a stale cleanup can never revoke a replacement's membership.
- `describe()` gives id-ascending diagnostics (states, provides/requires,
  resolved `dependsOn`, activation order) without touching factories.

Built-in plugins are all composition-time Dart: `defaultExecutionPlugins`
(`execution_profile.dart`) mounts `tina.app.spend-ledger`,
`tina.app.provider-decorators` (order-only stage),
`tina.app.provider-factory`, `tina.engine.project-capabilities`, and
`tina.engine.project-tool-scope`. The tool stage is per-tool plugins over
`ProjectCapabilities` (`project_tool_plugins.dart`), plus the sidecar
`write-summary` plugin (which provides a service key and deliberately does
NOT contribute to the registry) and the `web-search` plugin (contributes one
winning tool instance under two ids). Note: there is no
`runtime/runtime_plugins.dart` on the branch; "built-in plugins" live in the
app composition layer (`runtime_plugins.dart`,
`packages/tina_app/lib/src/composition/`), not in the engine runtime package.

### Which seams are real and load-bearing

Load-bearing, in the sense that everything else hangs off them:

1. **The scope + service keys** (`PluginScope.provide/lookup/require`). The
   entire composition — ledger before provider factory, capabilities before
   tool scope — is expressed as requires-edges over keys. This is the seam
   that makes plugin ordering declarative.
2. **The contribution list + `is` filters.** Tools, guards, and all three
   hook kinds reach the executor only through `scope.contributions`. Any new
   extension point is "pick an interface, filter for it in an assembly
   helper" — cheap to extend, but entirely untyped until the filter.
3. **The guard chain** (`ToolGuard`, `combineGuardBlocks`). Deny-preserving,
   fail-closed, policy first, phase second, extras after. This is the one
   seam a plugin cannot misuse to *allow* something.
4. **The driver seam** (`AgentDriver`, `AgentDriverRequest`,
   `AgentDriverFactory`). `buildAgent` routes through the resolved driver;
   headless, TUI, and test builds go through the returned driver; the
   live-panel sub-agent session factory was routed through it (PR #49
   follow-ups). `AgentDriverRequest` carries the hooks, guards, observers,
   verifier, and history observers — so a driver factory is the single place
   a plugin's executor-side contributions get attached to an agent.

Half-used or deliberately narrow:

- **`LocalControlTool`** exists but nothing in the runtime treats it
  specially that I could find; the comment says approval policy, the executor
  is elsewhere.
- **Contribution ids** are heavily engineered (reservation across disposal,
  identity revocation) but consumers match by `is Type`, never by id. The id
  machinery pays off only for revoke-during-dispose correctness.
- **The provider-decorator stage** is an order-only edge with an empty
  default — real plumbing awaiting users.
- **The plugin runtime has no per-plugin isolation**: one scope, one zone,
  one process. "Rollback" is resource cleanup, not containment.

### Where the plugin runtime ends and the agent/tool layer begins

The runtime knows nothing about agents, tools, or policy. It moves objects
into and out of a scope. Everything agent-shaped lives above it:

- `toolRegistryFromScope` and the `tool*FromScope` helpers turn scope
  contents into executor inputs — pure app/engine convention.
- The executor (`ToolExecutor`, referenced throughout the hooks docs) orders
  the mandatory policy guard, the phase guard, then extras; enforces
  exactly-once `delegate()` for AROUND hooks; seals arguments (hooks see an
  unmodifiable view); converts hook errors into error tool results.
- The driver seam sits at agent construction, not at tool dispatch: plugins
  contribute guards/hooks before activation ends, the composition builds them
  into `AgentDriverRequest`, and each built agent runs them per call.

So the boundary is: runtime = construction and teardown of a validated object
graph; agent layer = per-call enforcement. A plugin can only influence
dispatch through the object graph it leaves behind at activation time. It
cannot touch a running turn.

### The trust model

There is none beyond "plugins are compiled into the binary." A plugin is
in-process Dart: it shares the heap with everything else, its factory can do
anything `dart:io` can, its contributions run on the same event loop as the
executor, and a throwing factory aborts startup (by design — fail fast). The
hooks are the only nod to containment, and they are narrow by construction:
`ToolCallContext` exposes a read-only input view, a cancellation *probe* (not
the signal), and exactly-once delegation — a hook cannot swap a tool, rewrite
arguments, detach cancellation, or reroute output. Guards can only deny.
Observers cannot mutate.

But the factory itself is unconfined, and a *service* a plugin provides is an
arbitrary Dart object later handed real capabilities (e.g.
`ProjectCapabilities` carries the confined filesystem, sandbox runner, and
mutation lock — nothing stops a plugin from providing a fake). Admission
control is compositional (ids, keys, cycles), not security.

### What blocks loading a plugin from outside the binary

Concrete blockers, in order of hardness:

1. **Compilation.** A `PluginDescriptor` is a Dart object built by Dart code.
   `dart compile exe` bakes the snapshot; there is no supported way to load a
   new Dart class into a running AOT binary. You cannot even `eval` a
   descriptor without shipping an interpreter.
2. **Synchronous factories.** Even if code were loadable, `activateSync` and
   `FnPluginFactory` force construction to be synchronous. Fetching,
   verifying, and compiling an external module is async; the seam would need
   an async factory variant.
3. **No capability firewall.** An external plugin would have the process's
   full authority: dart:io, env, network. Today's permission policy
   (`policy.dart`) gates *model* tool calls, not plugin code. Loading foreign
   code with host authority is the one thing the current design cannot do
   safely.
4. **Config and distribution.** No manifest format, no discovery path, no
   version compatibility pin, no signature verification. `config` is a map
   keyed by plugin id — fine — but nothing feeds external plugin *descriptors*
   into it.

Points 2 and 4 are small. Points 1 and 3 are the actual wall — and they are
exactly the two things WASM addresses.

---

## Part 2 — WASM plugin support

### 1. Why WASM here, and what it costs

**What it buys.**

- **Loadable plugins.** A `.wasm` file is data: fetch it, verify it,
  instantiate it at runtime, no compiler involved on the user's machine. This
  removes blocker 1 outright and lets third parties ship plugins without
  forking the binary.
- **Real isolation.** A module sees only its own linear memory and only the
  imports the host linked. Blocker 3 becomes enforceable: capability = which
  host functions you import, plus WASI preopens and fuel/memory limits. The
  permission story stops being "trust the author."
- **Deterministic failure.** A trapped module returns a trap; the host keeps
  running. Today a plugin factory throw aborts startup and a hook throw
  becomes an error tool result — with WASM, *any* plugin fault degrades to a
  catchable error, including mid-call.
- **Language choice for plugin authors** (Rust, C, TinyGo, eventually Dart-
  compiled-to-WasmGC), and a natural distribution unit (one file + manifest).

**What it costs — honestly.**

- **The contribution model shrinks to data.** A WASM plugin cannot hand the
  host a Dart `Tool` object with a closure. It can answer calls. Tools and
  hooks survive in a "host-side adapter, module-side logic" form (§4); an
  arbitrary `ToolGuard` that wants rich shared state with the agent does not
  survive the boundary cheaply.
- **Latency and ergonomics.** Every call crosses the boundary: serialize,
  copy into linear memory, trap, copy back. A guard runs on every tool call;
  if a WASM guard adds ~0.1–1 ms per call (estimate — must be measured),
  that is real on hot loops. Host callbacks into the module, and module calls
  back into the host, multiply this.
- **No direct access.** The plugin can no longer just "read the config map"
  or "call the logger": everything is an explicit import. Small plugins
  become bigger.
- **Two runtimes to maintain** (in-process and WASM), a native dependency to
  package for three OS/arch pairs, and CI time. The notcurses pre-staging
  pipeline (`release.yml`, `packages/dart_notcurses/native/lib/<os>_<arch>/`)
  shows the team already pays this cost once; this adds a second native lib
  to it.
- **Async mismatch.** Wasmtime calls are synchronous; Dart's event loop is
  not. Every host function the module imports that needs async work (LLM,
  network) either blocks a worker thread or forces a rendezvous through the
  scheduler. This is the classic WASM-plugin papercut and it lands on the
  hottest paths (guards, hooks).

### 2. Runtime choice

Candidates, against tina's three shipping targets (macos-arm64,
linux-x64, linux-arm64 — `release.yml` builds each on a native runner):

| Option | Isolation | Speed | Packaging | Notes |
|---|---|---|---|---|
| `wasmtime` Dart FFI bindings (wasmtime crate → cdylib) | Strong (Cargo, epochs possible) | Best-in-class | Ship `libwasmtime` per target (~20–40 MB each) | Mature host API: components, fuel, epoch, WASI |
| `wasmer` bindings | Strong | Good | Same shape | Dart binding story thinner; API churn history |
| Pure-Dart interpreter (e.g. `wasm_interpreter`-style) | Same, but unproven | 10–100× slower | Trivial (no native lib) | Attractive for a bootstrap; unlikely to stay viable for real plugins |

**Recommendation: wasmtime via FFI**, with the wasmtime cdylib built and
pre-staged per target exactly the way the notcurses libs already are — same
docker build (`tool/docker/linux.Dockerfile`) for the linux pairs, native
build for macos, same `native/lib/<os>_<arch>` staging, same dart build hook.
The FFI precedent already exists in the repo (tina_console's notcurses
backend, `dart:ffi` users in `lib/self_update/updater.dart` and friends).

CI impact: one extra build matrix leg per target inside the existing release
workflow; cache the cdylib artifacts by wasmtime version. Also note the
additive `pubspec` dependency is FFI-declaration-only (the runtime itself is
loaded at runtime, `DynamicLibrary.open`), so a missing lib should degrade to
"WASM plugins unavailable", not a startup crash — the plugin runtime is
already built for "this plugin didn't mount".

The pure-Dart interpreter is worth keeping as a *test-only* backend (no
native lib in CI unit tests) if a maintained one exists at implementation
time. **Open question:** I could not verify from this machine which Dart
wasmtime binding packages are currently maintained and component-model
compatible; that check gates the first milestone.

### 3. Module contract

Concretely: a plugin is a directory with `plugin.json` and `plugin.wasm`.

`plugin.json`:

```json
{
  "id": "com.acme.gitleaks-guard",
  "api": 1,
  "contributes": {
    "tools":   [{ "name": "scan", "description": "…", "inputSchema": { } }],
    "guards":  [{ "id": "deny-secrets", "tools": ["bash", "write", "edit"] }],
    "hooks":   [{ "kind": "result", "id": "leak-verdict" }],
    "services": [{ "key": "com.acme.policy" }]
  },
  "config": { "maxFileSize": 1048576 }
}
```

The manifest is host-side truth: the host builds the
`PluginDescriptor` (id, provides/requires keys, an `AsyncPluginFactory`) from
it *without instantiating the module*, so all of PR #49's pre-activation
validation (duplicate ids, cycles, missing requires, config decode) still
happens before any wasm runs. `api: 1` pins the ABI; mismatch is a
composition error.

The module (core wasm with WASI, or a component once the Dart side supports
them — see risks) exports:

```wat
;; lifecycle — mirrors PluginLifecycleState
(memory (export "memory") 1)
(export "tina_abi_version" (func $abi))          ;; () -> i32, must be 1
(export "tina_config"     (func $cfg))           ;; (ptr,len) -> i32 status; parses config JSON from host-written memory
(export "tina_start"      (func $start))         ;; () -> i32 status
(export "tina_stop"       (func $stop))          ;; () -> i32 status

;; host -> module calls, one per contribution
(export "tool_execute"    (func $tool_exec))     ;; (call_id, input_ptr, input_len) -> i32 (ptr to result record)
(export "guard_block"     (func $guard))         ;; (guard_id, tool_ptr, tool_len, input_ptr, input_len) -> i32 (0=allow, else ptr to denial)
(export "hook_process"    (func $hook))          ;; (hook_id, payload_ptr, payload_len) -> i32 (ptr to verdict, 0 = none)

;; module -> host: allocator negotiation and the capability imports (§4)
(import "tina" "alloc"   (func $alloc (param i32) (result i32)))
(import "tina" "free"    (func $free (param i32 i32)))
(import "tina" "log"     (func $log (param i32 i32 i32)))   ;; level, ptr, len
```

Calling convention: UTF-8 JSON in the module's linear memory for v1.
Addresses are `i32` offsets; lengths are `i32` bytes; the host imports
`alloc`/`free` from the module (the standard pattern: host asks the module
for a buffer, writes the payload, calls the export, reads the returned
pointer/length via a fixed layout `(ptr:i32, len:i32)`), then frees. Every
export returns a status `i32` where nonzero is a trap-free error the host
turns into the same failure shapes the Dart path already produces
(`PluginCompositionError` at activation; error `ToolResult` at dispatch).
JSON over linear memory is not fast; it is *simple and versionable*. A
binary upgrade path (postcard-style) is a v2 `api` bump, not a redesign.

`config` reaches the module as its manifest's `config` block — the same
per-plugin isolation `PluginRuntime.config` gives Dart plugins, decoded by
the module itself inside `tina_config`.

### 4. Host interface

Map each thing a Dart plugin reaches today onto the boundary:

| Dart plugin reaches | Crosses the boundary? | v1 answer |
|---|---|---|
| Tool registration | Yes, as data | Host builds a `WasmTool` implementing `Tool`; `execute` marshals input JSON → `tool_execute`, returns `ToolResult(content, isError)`. `onOutput` streaming: module calls an imported `emit_output` host fn, host forwards to the callback. `cancelSignal`: host checks it before/after the call; a long module call can be abandoned via fuel/epoch trap (§5) — true mid-call cancellation is out of scope for v1. |
| ToolGuard | Yes, if it can deny from (name, input) alone | Host builds a `WasmToolGuard` whose `block` marshals to `guard_block`. Deny-preserving semantics survive exactly: the module returns a denial string or "allow". |
| ToolExecutionHook (AROUND, exactly-once delegate) | Partially | v1 does **not** let a module wrap the delegate (that requires host→module→host→module ping-pong and an async bridge). Instead offer `result` hooks (§ below) and observer events. A module AROUND hook is a v2 item behind an async trampoline. |
| ToolResultHook | Yes | `hook_process` gets (tool, input, result) JSON; returns a verdict string or none. Matches the first-non-null-wins chain. |
| ToolObserver | Yes | Host pushes toolStart/toolOutput/toolComplete as fire-and-forget imported calls; module-side observers cannot block anything (same as Dart observers). |
| Services (`ServiceKey`) | One direction | A module can *provide* a service only as an opaque handle: the host binds the key to a `WasmServiceHandle` whose methods are module exports. A module can *require* a host service only if the service declares a serialized façade (§ below). |
| `ProjectCapabilities`, filesystem, env | No — deliberately | The module never receives capability objects. It gets the specific imports the manifest + policy allow (§5). |
| The driver seam (`AgentDriverFactory`) | No | A WASM plugin cannot *be* a driver: the driver hands out providers, sinks, and registries as Dart objects. The honest answer: drivers stay host-side; a plugin that needs driver-level power ships as Dart (built-in) — WASM plugins are the extension tier *below* it. |

Host services across the boundary: define serializable façades for the small
set of services a plugin legitimately wants. v1 ships exactly two:
**log** (a built-in import, levelled) and **config** (its own block, at
`tina_config` time). Everything else returns "capability not exposed to
modules" — a closed list grows on demand, never the reverse.

What cannot cross, and the answer for each: rich shared state with the agent
(a guard that wants the session's spend ledger) → expose narrow query imports
per need, not the object; LLM/network access from inside a module → deny in
v1, the module may *ask* the host to perform a permitted action via an
explicit `host_request` import that re-enters the host's own permission
pipeline (ask the user, honor `policy.dart`) — if we ever ship it;
synchronous factories → `AsyncPluginFactory` on the Dart side, a small
additive seam (`PluginRuntime` currently assumes sync factories; the
`activateSync` fast path simply refuses descriptors with async factories, or
activation requires the async path when any module is present — the runtime
already validates before building, so this is contained).

### 5. Capability model

Map WASM's native controls onto tina's existing vocabulary — this is the
part WASM makes *better* than in-process plugins:

- **Store/engine limits per module:** memory cap (e.g. 64 MiB default) and
  **fuel metering** (wasmtime) per call, configured in the manifest and
  clamped by the host. Fuel exhaustion = trap = error result. This bounds a
  malicious or buggy plugin's CPU the way `combineGuardBlocks` bounds its
  authority: structurally, not by promise. Epoch-based preemption covers
  runaway loops that hold a host thread; the epoch deadline ties into the
  existing `cancelSignal` plumbing so an ESC'd turn stops charging a module.
- **WASI:** use *preview1* only, and treat preopens as capabilities. A
  plugin's manifest declares what it needs:
  `"capabilities": { "fs": ["read:.tina/plugins/com.acme/cache"],
  "net": [] }`. The host intersects the manifest's request with what
  `PermissionPolicy` and the mode allow, preopens exactly that, and passes
  `sandboxNet: false`-style flags through the same config fields the engine
  already has (`ProjectCapabilities.build(sandboxEnabled, sandboxNet,
  sandboxReadOnly)`).
- **Mapping onto `policy.dart`:** the policy gates the *model's* tool calls;
  module capabilities gate *plugin* code. Two rules keep them coherent:
  1. A module-contributed tool is just a tool: its calls flow through the
     mandatory `PolicyToolGuard` and phase guard like any other
     (`readAll` denies it unless it is in a read-only set — decide whether
     plugin tool names can join `_readOnlyTools`; default: no, plugins are
     not auto-read-only).
  2. The host refuses to grant a module a capability the current mode would
     deny the model for: `readAll` mounts modules with read-only preopens
     (or not at all); network imports simply don't exist unless the user
     enabled them. The module therefore cannot be a smuggled bypass for the
     mode boundary — there is no import to smuggle through.
- **Filesystem confinement** reuses the existing confined-fs idea: preopen
  roots, never the project root wholesale, and never `~/.tina` (the sandbox
  already denies that tree to bash — the same rule for modules).
- **No ambient authority:** v1 links no env, no clock (a deterministic clock
  import the host controls, if a module needs time), no random unless
  declared.

### 6. Lifecycle integration

The wasm plugin mounts through the same `PluginRuntime` machinery with a new
descriptor kind — the points that carry it:

- **Admission/validation:** the host builds `PluginDescriptor`s from
  manifests. `_validate` already rejects duplicate ids, unselected
  multi-provider keys, cycles, and bad config *before factories run* — for a
  wasm plugin, "factory" includes `Module::new` + instantiate, so a bad
  module costs a validation error, not a partial activation. `api` version
  and signature/digest checks slot into this pass (extend
  `PluginCompositionError` with a `reason`, or pre-check and throw the same
  type).
- **Activation order:** unchanged. A module plugin declares
  `provides`/`requires` in its manifest; Kahn + id-ascending treats it
  exactly like `tina.app.spend-ledger` does. A wasm guard plugin that
  requires the policy guard's key activates after it — same mechanism,
  no wasm awareness in the runtime.
- **Services and ownership:** `tina_start` runs inside the factory
  (`context.provide` for manifest-declared keys happens host-side after the
  module acknowledges config). Resources: the host registers **one**
  `ScopeResources.own` cleanup per module plugin whose dispose calls
  `tina_stop` then drops the instance — reverse-acquisition teardown and
  `Registration.onDisposeStart` revocation then apply unchanged, and a
  `Registration` with the module handle as its id participates in the same
  reservation/identity rules.
- **Rollback:** a module whose `tina_start` traps throws; the runtime's
  existing `_rollback` (await teardown before rethrow, terminal `isFailed`)
  drains it like any other factory failure. `describe()` gains a
  `source: wasm|builtin` on `PluginDescription` — diagnostics only.
- **Dispose/disposal races:** module teardown is sync from Dart's
  perspective (drop the instance); it cannot create child scopes during
  teardown, so `closeAdmissionTree` concerns don't change.
- **Borrowed scopes:** `borrowedScopePlugins` trims project-owned stages by
  id; wasm plugin ids are namespaced (`com.acme.*`), so a borrowing
  conversation keeps its own modules mounted — consistent with the existing
  "everything not project-owned rides along" rule, but note it as a policy
  decision: should project-local modules be re-mounted per conversation
  (cheap: modules are data) rather than borrowed?

### 7. Migration path

Both kinds coexist by construction: a runtime is a list of
`PluginDescriptor`s, and a wasm plugin is just a descriptor whose factory
talks to a module. Nothing existing changes.

Smallest first step — one thin vertical slice:

1. Add `AsyncPluginFactory` to the engine's plugin seam (additive; the
   runtime's sync path stays for built-ins).
2. A `wasm_plugin_loader.dart` in the app layer: read `plugin.json`, build a
   descriptor whose factory instantiates the module, exposes **one tool**
   (`tool_execute`), no guards, no services. JSON-over-memory only.
3. Ship the notcurses-style pre-staged wasmtime cdylibs and a
   `--wasm-plugins <dir>` flag on the headless runner; the TUI follows.
4. Pick a real internal plugin to convert first: the **write-summary sidecar
   tool** is the natural candidate — it is already deliberately *not* a
   registry contribution (it provides `writeSummaryToolServiceKey` and the
   profiles compose it themselves), it is self-contained (a sidecar
   directory and a project root), and it has no guards/hooks entanglement.
   Converting it proves the whole pipeline while risking almost nothing.
5. Only then: guards (the deny-only seam), result hooks, observers, and the
   capability/permission mapping. AROUND hooks last or never.

Converting an arbitrary in-process plugin: if it contributes tools/hooks that
can be expressed as (JSON in) → (JSON out), it ports to the §3 exports; if
it provides rich Dart services or needs the driver seam, it stays in-process
— that is the tiering working as intended, not a failure.

### 8. Risks and open questions

Risks:

- **Two-tier plugins forever.** The WASM tier is strictly less capable; the
  docs must say so plainly or every plugin author will start with WASM and
  bounce off the boundary.
- **Native packaging weight.** Three cdylibs, tens of MB each, shipped in
  every release tarball even for users with zero plugins. Consider a
  separate download on first wasm-plugin use (lazy fetch — with a checksum
  pinned in the release notes).
- **FFI thread safety.** Wasmtime is not free-threaded; every call needs the
  engine/store access pattern sorted (single store per plugin, a lock, or
  one store per isolate). Get this wrong and the guard path deadlocks under
  a concurrent sub-agent — exactly the `SubAgentScheduler` traffic the driver
  seam already parallelizes.
- **Fuel/epoch tuning.** Too little fuel and real plugins fail mid-call in
  ways in-process plugins never did; too much and the isolation story is
  theater. Defaults need measurement, and probably a per-call override in
  the manifest.
- **Component model timing.** Core-wasm+WASI-preview1 with JSON is the safe
  v1; components with typed interfaces would be strictly better but the Dart
  side's tooling support needs checking (open question below).

Open questions (stated as questions — I could not determine these from the
repository or from this machine, where web access was unavailable):

1. Which Dart wasmtime binding package is maintained today, and does it
   expose fuel, epoch, WASI preopens, and store limits — or is a thin
   hand-rolled FFI layer over the wasmtime C API the realistic path?
2. Does `dart2wasm`/WasmGC output run under wasmtime well enough that a
   *Dart-authored* plugin can target this pipeline, or is Rust the only
   supported authoring language for v1?
3. Is the executor's per-call overhead budget known (guards + hooks today)?
   Without a number we cannot say whether a ~0.1–1 ms wasm guard round-trip
   is acceptable on the hot path — and the guard path is the one that scales
   with every tool call in every step.
4. Should plugin tool names be mountable into `PermissionPolicy`'s
   `_readOnlyTools` (auto-approved in `readAll`), or must every
   plugin-contributed tool always ask? The safe default (ask) may make
   read-only plugin tools unusable in `readAll` sessions.
5. How do wasm plugins interact with the borrow path — does a conversation
   that borrows a project's tool scope re-instantiate the project's modules
   (`borrowedScopePlugins` keeps non-project ids) or refuse them?
6. What is the distribution trust anchor — is a sha256 digest in
   `plugin.json` checked against a sidecar signature file enough for v1, and
   who signs community plugins?
7. Does the wasmtime cdylib build cleanly for linux-arm64 under the existing
   docker flow, given notcurses needed per-target staging for the same
   targets?
8. Are sync factories load-bearing anywhere a wasm plugin must mount (i.e.
   do any current composition sites call `activateSync` on profiles that
   should accept external plugins)? If so, async activation needs a
   deliberate seam, not a bolt-on.
