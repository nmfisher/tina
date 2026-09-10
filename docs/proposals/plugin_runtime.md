# Plugin runtime implementation plan

Status: proposed; implementation has not started.
Date: 2026-09-10.

Implement Tina's built-in features through a shared plugin lifecycle, with typed
services, owned registrations, and explicit execution hooks. The default agent
driver must eventually use the same composition mechanism as tools, providers,
commands, and frontend integrations.

This follows the review of DeepSeek Harness at
[`b2e3b2a`](https://github.com/deepseek-ai/deepseek-harness/tree/b2e3b2a0125854567a4a5fcba75782e42fe84901).
The relevant mechanisms are its
[dependency-driven services](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/docs/cordis-tutorial/03-services.md),
[owned registrations](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/core/scope/src/store.ts),
and [replaceable agent driver](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/core/agent-loop/src/index.ts).
Use those principles in Dart, adapted to Tina's ownership and package boundaries.

## Scope and relationship to earlier work

[The earlier extension-seam proposal](plugin_architecture.md) intentionally
excluded a plugin runtime. Preserve it as historical context. This plan expands
the scope following the current request; it does not reinterpret the earlier
proposal as authorization to build a loader.

[A01–A08](architecture/README.md) are implemented. Reuse their runtime isolation,
application operations, provider ownership, workflow catalogs, and import rules.
The current working tree also contains the runtime read-all and environment-phase
gates. Land and retain that behavior as the baseline before extracting it.

The first complete version has:

- Built-in Dart plugins selected from a compiled-in catalog.
- Typed service dependencies and deterministic activation.
- Scoped resource ownership and reversible registrations.
- Execution guards, typed interceptors, and observation subscriptions.
- Built-in application profiles, followed by explicit configuration of known
  plugins at startup.
- A replaceable agent-driver interface used by every agent creation path.

External package discovery, downloading code, a marketplace, WASM, a public
versioned plugin SDK, and live code replacement are later projects. Configuration
in this version selects linked factories; it does not evaluate Dart, JavaScript,
or arbitrary repository-local plugin paths. Permission changes remain live state
changes and never require reloading a plugin.

## Target package structure

Start within the existing packages. Proposed names below are design targets,
not existing APIs.

| Location | Responsibility |
| --- | --- |
| `tina_engine/lib/src/runtime/` | Plugin descriptors, typed service keys, scopes, registration handles, activation and teardown |
| `tina_engine/lib/src/tools/` | Tool catalog and execution pipeline contracts, built-in file/shell/web contributions |
| `tina_engine/lib/src/agent/` | Agent-driver contract, default driver, prompt assembly, delegation contracts |
| `tina_app/lib/src/composition/` | Plugin catalog, resolved profiles, app/project/conversation scope creation |
| `tina_app/lib/src/environment/`, `workflows/`, `session/` | Application feature plugins using engine contracts |
| Root `lib/composition/` and frontend code | TUI/headless plugins, command and presentation contributions |

Runtime primitives cannot import application services, terminal packages, or
concrete tool implementations. Service keys live alongside the interfaces they
identify. Frontend plugins can use console types internally; their engine-facing
contracts cannot expose widgets, notcurses handles, or terminal initialization.
Keep `tina_console` independent of the new runtime.

## Runtime contracts and ownership

### Plugin and service contracts

Introduce these small internal contracts:

- `PluginDescriptor`: stable plugin ID, declared required/provided service keys,
  config decoder, and factory. Dependencies name typed capabilities.
- `ServiceKey<T>`: an explicit, namespaced identity for a service interface.
- `PluginContext`: access to declared services, contribution registries, child
  scopes, and an ownership handle. Resolve dependencies at activation and pass
  ordinary typed references into implementation objects.
- `Registration`: an idempotent disposer for precisely one contribution.
- `PluginScope`: owns mounted plugin instances, registration handles, resources,
  and cancellation/join handles for work it starts.
- `PluginRuntime`: validates the dependency graph, activates it, and disposes it.

Separate singleton services from multi-contributor registries. Two providers of
one service in the same scope are an error unless profile resolution explicitly
selects one. Replacing a service in a child scope must be explicit; lookups then
resolve the nearest selected provider. Duplicate tool/command IDs in one scope
also fail, rather than silently overwriting another plugin's contribution.

Use a stable topological activation order with plugin ID as the tie-breaker.
Contribution order is separately declared and frozen: dependency completion time
must never determine tool-schema order, prompt order, or command-help order.
Detect missing dependencies, cycles, duplicate IDs, and invalid config before
starting providers, subprocesses, or the terminal.

### Scope model

Ownership and capability inheritance are related but distinct:

| Scope | Owns | Borrows or inherits |
| --- | --- | --- |
| Runtime | Plugin catalog, provider factory/decorators, shared application services | Resolved startup configuration |
| Project | Confined filesystem/process capabilities, tool implementations, write lock, sandbox access state | Runtime services |
| Conversation/agent | Provider instance, driver, tool-catalog view, prompt assembly, transcript observers | Project capabilities and session mode source |
| Turn/job | Environment inspection state, temporary guards, cancellation and completion | Agent services or the explicitly selected project/session scope |

Two projects must never share mutable tool or sandbox instances accidentally.
Same-project delegates and workflow nodes continue borrowing the existing project
scope. Each conversation still owns its provider. Creating a child scope does
not create a new permission mode: preserve the explicit shared live mode source,
while retaining the current separation of remembered approvals.

### Lifecycle and failures

Use `pending → activating → active → stopping → disposed`, with failed activation
reported together with its plugin and dependency chain. Register cleanup as each
resource is acquired. An activation failure rolls back the partial scope and
unwinds dependencies already started exclusively for that failed composition.
Borrowed dependencies remain alive.

Teardown first closes admission, signals cancellation, and awaits owned work;
only then does it remove registrations and dispose providers/backends. Dispose
children before parents and consumers before providers. Preserve the existing
sequential reverse-order cleanup behavior of `RuntimeResources`, including
continuing after cleanup errors and retaining the original work failure.

Unload is supported for completed turn/job scopes, closed conversations, and
application shutdown. Version one rejects replacing or unloading services while
dependent scopes own active work. Startup profile changes take effect on restart.
This provides reversible lifecycle ownership without silently restarting a live
conversation or an approval dialog.

The plugin runtime handles composition errors. The execution pipeline handles
policy and tool failures. Cosmetic observers can fail without changing execution;
a failed execution guard must reject the call. Do not use one catch-and-ignore
rule for both kinds of extension.

## Execution and prompt contracts

### Separate advertised tools from execution authority

Retain the separation introduced by `ToolRegistry.forStep()` and
`executionBlock()`. A catalog describes the tools an agent can name; runtime
authorization decides whether a particular invocation may run.

Extract the current dispatch block from `Agent.run` into a `ToolExecutor`. Carry
over this order before introducing optional interceptors:

1. Resolve the call against the immutable catalog and turn-phase snapshot.
2. Apply mandatory live mode and phase guards before any approval/classifier.
3. Evaluate existing static/session rules and sandbox access or retry requests.
4. Await approval when required; recheck live guards before remembering an allow
   or granting additional sandbox access.
5. Recheck cancellation and live guards at the actual dispatch boundary, after
   any asynchronous preparation or execution wrapper.
6. Execute, normalize the outcome, run the existing verifier/recovery handling,
   and append exactly one corresponding tool result through the driver.

The executor resolves the implementation; wrappers cannot replace its identity
or arguments, invoke it twice, or detach cancellation. An around-execution hook
may await preparation and delegate at most once. Retries remain explicit named
policies using the existing retry contract; adding middleware must not create
automatic retries of mutating commands.

Permission policy and environment-phase enforcement become built-in guard
contributors. Guards combine by denial: an allow or an optional wrapper cannot
override another guard's rejection. Supported profiles must supply execution
authority and required confinement services; omitting them fails validation.
Built-in plugins are trusted in-process code, and the context is an architectural
boundary rather than a sandbox for hostile extensions.

Migrate environment setup as an agent-owned feature: a turn scope owns its
inspection state and transition handle. Keep the transition schema present for
the whole main conversation. A transition affects the next model step and cannot
authorize a bash call already supplied in the same batch. Retain read-only scout
ceilings, full-delegation checks, and the user's live mode across all children.

DeepSeek's [tool runtime](https://github.com/deepseek-ai/deepseek-harness/blob/b2e3b2a0125854567a4a5fcba75782e42fe84901/packages/core/tools/src/index.ts)
provides both schema restrictions and execution guards. Tina's mandatory early
guard is additionally necessary to avoid asking for an action that is already
blocked by read-all.

### Typed extension points with real consumers

Introduce hooks only with a built-in migration that uses them:

| Extension point | Initial consumer | Contract |
| --- | --- | --- |
| Tool admission | Permission mode and environment phase | Ordered, deny-preserving decisions |
| Around tool execution | Existing execution instrumentation | Awaited, single dispatch, joined cancellation |
| Post-tool processing | Existing edit verifier | Awaited; preserves call/result pairing and current transcript behavior |
| Provider construction | Existing metering/decorators | Installed before any conversation provider is built |
| Prompt contribution | Identity, project context, environment record | Stable ordered assembly |
| Turn/tool observation | Existing host/bus adapters | Observe-only; subscriber failures contained |

Retain `AgentSink`, `AgentEventBus`, persistence observers, and `RunLifecycleSink`
as compatibility adapters while their ownership moves into plugins. Avoid a
second event vocabulary carrying the same facts. Do not make correctness depend
on delivery through an asynchronous broadcast stream.

### Cache and persistence invariants

- Freeze tool names, descriptions, schemas, and ordering for each composed agent
  catalog. Permission or environment-phase changes alter execution state only.
- Assemble prompt contributions in explicit order. The initial migration must
  reproduce the existing rendered system prompt, including trust filtering.
- Append mode/phase context after existing conversation history; do not rewrite
  the system prompt or earlier messages when a runtime mode changes.
- Preserve current cancellation rollback and reannounce notices that were
  removed. Keep valid assistant tool-call/result pairing in persisted history.
- `--safe-mode` and a delegation's tool profile remain construction-time
  capability choices. They can produce different initial catalogs; switching
  the live permission mode does not rebuild those catalogs.
- Existing explicit model/prompt changes and compaction retain their current
  semantics. This refactor does not promise cache reuse across actual changes
  to model-facing content.
- Keep the current session format and recorder contract. Replacing persistence
  through a service does not require adopting DeepSeek's session event format.

## Implementation sequence

Each phase is a separate reviewable change. Migrate a real built-in in the same
change that introduces its extension contract; remove superseded wiring as each
route moves over.

| Phase | Work and principal files | Completion evidence |
| --- | --- | --- |
| P0: establish baseline | Land the pending mode/phase gate change separately; inventory creation and cleanup paths in `AppComposition`, `ExecutionRuntime`, scheduler, sessions, and workflow runner | Record passing relevant checks and representative schema/system/history fixtures |
| P1: lifecycle runtime | Add engine runtime primitives; adapt `RuntimeResources` to one cleanup implementation; mount provider factory and metering as the first runtime plugins in `execution_runtime.dart` | Failed startup leaves no resources; borrowed fakes survive; providers close once; dependency and order failures are explicit |
| P2: project capabilities and tools | Split construction from `ProjectToolScope`; provide filesystem/process/lock capabilities, then register existing file/shell/web tools as plugins | Two projects remain isolated; same-project agents share the write lock and sandbox grants; tool schemas and order match baseline |
| P3: execution pipeline | Extract `ToolExecutor` from `agent.dart`; move permission and environment guards into owned contributions; migrate verifier and execution observation hooks | Read-all never prompts or executes blocked calls; approval races, same-batch transitions, sandbox retry safety, and cancellation regressions pass |
| P4: prompts and providers | Register ordered prompt contributors; unify provider construction/decorator contributions using existing `LlmProviderFactory`/`ProviderRegistry` | Initial prompt bytes and provider selection match baseline; mode changes preserve previously sent prefix bytes |
| P5: replaceable driver | Add `AgentDriver` and `AgentDriverFactory`; wrap the existing `Agent` as the default driver plugin; migrate `Conversation`, `TurnExecutor`, scheduler and standalone workflow creation | Every production creation path uses the factory; a test driver can replace the default without editing the coordinator; default behavior remains unchanged |
| P6: application and frontend features | Mount delegation, workflows, environment, session persistence, commands, and TUI/headless adapters through the same lifecycle | Headless composition requires no terminal; command/help ordering, agent nesting/focus, workflow approvals, and teardown retain behavior |
| P7: profiles and diagnostics | Compose default interactive/headless profiles from known plugin factories; add startup-only user overrides and effective-composition diagnostics | Defaults retain current CLI behavior; invalid profiles fail before side effects; catalog, dependencies, scope, and ordering are inspectable |
| P8: finish migration | Remove legacy hardcoded construction paths and temporary adapters; update architecture rules and feature documentation | Built-ins use the same registrations as test replacements; architecture ratchet passes without broad new exceptions |

P2 is the first demonstration of service replacement: run the same tool plugin
against the production project capabilities and in-memory test capabilities.
P3 is the first substantive product benefit: adding a runtime gate or verifier
no longer requires embedding that feature inside the agent loop.

P5 must design the driver around the operations callers actually use: run,
cancel/join, provider/model replacement, compaction, and access to the composed
catalog and prompt. Move shared state into an explicit agent session/context
where needed. A wrapper that forces every caller to downcast to `Agent` does not
meet the replacement requirement. Keep sequencing and persistence guarantees in
the driver contract; an alternate driver still uses `ToolExecutor` for tools.

P6 reuses `SessionCommandRegistry`, `WorkflowCatalog`, attractor's
`NodeHandlerRegistry`, and `SessionStore`; it does not add duplicate registries.
Persistence and the driver need a construction-order-neutral contract to avoid
a cycle: persistence provides the store/recorder factory first, and each agent
scope borrows or owns the resulting recorder explicitly.

For frontend contributions, root plugins register commands and panel factories
using application data and host contracts. The TUI retains responsibility for
focus, painting, native resources, and input routing. Do not move those concerns
into engine service lookup.

## Profile rules

Begin with profiles declared in Dart so lifecycle and behavior can stabilize
before configuration becomes public. In P7, extend the existing configuration
parser rather than adding YAML or expression evaluation:

- A profile selects an ordered set of stable plugin IDs and validated configs
  from the compiled-in catalog.
- Use the existing resolved configuration precedence. List replacement/patching
  and per-plugin config replacement must have one documented deterministic rule;
  proposed rule: explicit entries replace the whole config for that plugin ID,
  and unspecified entries retain their profile defaults.
- Existing command-line flags continue setting their established options.
  Profiles cannot silently disable CLI-selected safe mode or execution gates.
- Configuration resolves to an immutable composition before plugin activation.
  Unknown plugins, missing required capabilities, and incompatible service
  selections report the plugin ID and source setting.
- A diagnostic dump shows selected plugins, dependency edges, service providers,
  scopes, and contribution order. Redact credentials and never materialize keys
  merely to render diagnostics.
- A running scope retains its composition. Applying an edited profile requires
  restart in version one; `/permissions` continues changing live policy state.

## Verification and acceptance

Use in-memory providers, stores, and fake hosts for runtime tests. Add meaningful
failure and integration coverage alongside each migration:

1. Dependency validation, failed activation rollback, idempotent disposal,
   child-before-parent cleanup, and cancellation joined before provider close.
2. Explicit service replacement and scoped registrations with two independent
   runtime/project compositions alive simultaneously.
3. Read-all against default/static/session allows, nested delegation, workflow
   nodes, and a mode switch during provider streaming or approval waits.
4. Environment inspection, failed inspection, plan transition, same-batch
   attempted execution, cancellation, and the following ordinary turn.
5. Sandbox allow-once/session grants, observed write failures, retry safety, and
   no repeated approval after denial.
6. Serialized provider-request snapshots proving byte-identical schemas/system
   and unchanged earlier messages across mode and phase changes. Check actual
   adapter request bodies as well as internal objects; do not infer cache hits
   from those tests.
7. Current session restore, compaction, queued-input interruption, provider
   replacement, tool-result pairing, and shared spend accounting.
8. Native-free headless startup plus existing ANSI/notcurses integration coverage
   for frontend migrations, especially quit while work or approval is pending.

Run affected tests at each phase, `dart analyze` for changed packages, and
`dart tool/check_architecture.dart` when dependencies move. Before removing the
legacy path, run the owned-package CI suites defined by A08. Add no new global
state or unclassified dependency paths to make composition convenient.

Completion means changing one built-in service provider or adding a tool,
guard, prompt contributor, or command requires a plugin registration and profile
selection, with no special-case edit to `Agent.run` or `tui_coordinator.dart`.
The agent driver and persistence are replaceable through their contracts, and
all registrations are removed with their owner. Source-file moves alone do not
establish that result.

## Recommended starting slice

Implement P0 and P1 first. Keep `AppComposition` and `ExecutionRuntime` as typed
facades for current callers while they acquire services from the new runtime.
Use provider construction and metering to prove dependency ordering, ownership,
rollback, and isolation. Then migrate the project tool catalog and execution
pipeline in P2/P3 before extending the plugin surface to UI or public profiles.
