# A01 — Isolate runtime dependencies and resource ownership

Status: implemented and validated. See the [program index](README.md) for sequencing.

## Implementation progress — 2026-09-07

The first slice introduces `ProjectToolScope`, owned by `AgentPipeline`, and
removes module-level file/tool singletons and `configureToolSandbox`. Application
composition creates a fresh scope, or accepts an explicitly borrowed scope for
the same project. Main, delegated, spawned, branched and restored agents use that
scope; live summary/environment services pass it into background compositions so
they retain the project's mutation lock. Search roots and optional search-provider
environment settings are also scoped. Standalone assembly helpers remain as
compatibility APIs and create independent unconfined tool sets.

Regression coverage lives in the engine and root
`test/agent/project_tool_scope_test.dart` and
`test/composition/project_tool_scope_test.dart`, respectively. It checks file
isolation, shared versus independent locks, destinations, sandbox/pass-through
coexistence, environment snapshots, safe mode and explicit scope borrowing.

The second slice introduces `LlmProviderFactory` and `RuntimeProviderFactory`.
The factory captures its decorator and retry count while borrowing the registry's
catalog, credential resolution and endpoint limiter. Application startup,
classifiers, delegates, workflow workers, restored conversations and TUI model
selection now build through the runtime factory. Summary/environment runners no
longer save, mutate or restore `registry.decorator`; their separate ledgers and
existing completion-time usage merge remain intact.

Failed-attempt usage is also isolated: outer retries report to the meter instance,
and nested pool failovers report through a send-scoped zone. Creating or closing
a meter no longer changes a process-global usage callback. Interleaved tests cover
both completion orders for two runtimes, including pooled failures. Construction
failures release already-created pool members and providers whose decoration
fails. Registry policy fields remain compatible with standalone direct builds;
runtime factories neither inherit nor mutate the registry's decorator.

Additional coverage is in engine `test/llm/runtime_provider_factory_test.dart`
and root `test/composition/runtime_provider_factory_test.dart`. Background-run
tests observe the registry during provider sends as well as after completion.

The final slice introduces `PromptContext`: each pipeline captures its project
root, trust decision and warm-load callbacks. Main and standalone node prompts
read that context; background services borrow it explicitly. Untrusted contexts
cannot be elevated by a prompt call option. Sources and AGENTS.md are refreshed
per resolution without changing process globals. Image rendering is now a
pipeline-owned capability detached at TUI shutdown. Scoped file tools resolve
relative paths and omitted directory defaults against their project root; bare
standalone tools preserve their existing cwd-relative behavior.

`AppComposition.dispose()` uses reverse-order, exhaustive, idempotent cleanup.
It owns its scheduler, classifier and internally created store; injected stores
are borrowed unless `ownsStore: true`. The CLI explicitly transfers its store.
Runtime factories reject builds after closure; catalogs remain process-owned.
Scheduler disposal stops admission, cancels delegated and standalone work, and
awaits it before closing event streams. Inline and standalone providers close
on success and failure; a successful panel factory transfers provider ownership
to its conversation. Background acquisition and execution use the same cleanup
mechanism, including failures before `agent.run`. Conversation construction,
restore, TUI construction, headless setup and session teardown have acquisition
or exhaustive cleanup guards. Accounting and result recording still happen
only after background resources finish cleanup.

Final validation: 888 engine tests and 187 affected application/TUI/session tests
passed; root `dart analyze` reported no issues. See [HANDOFF.md](HANDOFF.md) for
commands and the remaining task sequence. New focused coverage includes prompt
and renderer interleaving, relative project paths, scheduler cancellation and
provider closure, repeated disposal, borrowed-store survival, composition failure
and cleanup errors that must not mask the original failure.

Compatibility decisions: standalone `buildTools`/`toolSetFor`/`toolsFromPolicy`
remain public but create fresh independent scopes; they no longer wrap globals.
Direct `ProviderRegistry.build` and its legacy decorator remain for standalone
consumers. Production runtime paths use the scoped factory. Process facilities
such as CLI signal handling, wire diagnostics, terminal ownership and child-process
reaping remain process-owned; this does not promise multiple simultaneous terminal
frontends in one process. Nested background application construction is intentionally
retained for A05, with explicit borrowing and safe cleanup in the meantime.

## Original problem and source anchors

- [`agent_pipeline.dart`](../../../packages/tina_engine/lib/src/agent/agent_pipeline.dart)
  holds shared `_read`, `_write`, `_edit`, `_bash`, `_git` and other tool instances.
  `configureToolSandbox` mutates their roots, filesystem adapters, locks and
  runners. Constructing another application can reconfigure existing agents.
- [`app_composition.dart`](../../../lib/composition/app_composition.dart)
  assigns `registry.decorator` to capture a new ledger and pause gate.
- [`summary_runner.dart`](../../../lib/summaries/summary_runner.dart) and
  [`environment_runner.dart`](../../../lib/environment/environment_runner.dart)
  save and restore that decorator around awaited nested application startup.
  Overlapping calls can see the temporary decorator or restore it out of order.

This is an ownership problem even though the package dependency graph is acyclic.
Tests cannot reliably create independent runtimes with different project roots.

## Goals and scope

Replace mutable global construction with explicit runtime scopes. Preserve tool
schemas, profiles, permission semantics and provider resolution. Do not split
the engine package or introduce a dependency-injection container.

## Ownership model

| Scope | Owns | May borrow |
| --- | --- | --- |
| Process/application | Provider descriptor catalog and externally loaded catalog resources | Environment snapshot |
| Project tool scope | Canonical project root, sandbox adapters, backup adapter, file mutation lock | Filesystem/process implementations |
| Execution scope | Provider factory policy, tool factory, scheduler, ledger and pause-gate policy | Project tool scope and catalog |
| Conversation | Its provider instance, agent, transcript and recorder handle | Execution resources |
| Background run | Its own provider instances and cancellation handle | Explicitly selected tool scope and accounting scope |

No borrowing scope disposes the owner’s resource. A factory creates providers;
the recipient owns and closes them. A scope tracks its own resources for failure
cleanup and makes `close()` idempotent. Avoid retaining a provider in both an
uncoordinated scope cleanup list and conversation cleanup list.

## Proposed design

Introduce `ProjectToolScope` and `RuntimeProviderFactory`. The following expresses
the intended boundaries; exact constructor spelling can follow existing style.

```dart
abstract interface class RuntimeProviderFactory {
  LlmProvider create(ProviderRequest request);
}

abstract interface class RuntimeToolFactory {
  ToolRegistry create(ToolProfile profile);
}
```

`ProviderRequest` contains resolved model selection and request tuning; it must
not include terminal settings. `RuntimeProviderFactory` uses the catalog to
construct a provider and applies its own immutable decorator policy. Catalog
lookup remains reusable, but changing one factory cannot affect another.

`ProjectToolScope` supplies filesystem, process, backup and mutation-lock
dependencies to tools during construction. `RuntimeToolFactory` constructs a
registry from those dependencies. Stateful tool instances must not be shared
between unrelated scopes. Immutable tool instances may be reused only when
their lack of runtime state is clear.

Move `toolSetFor` and full-tool-set assembly onto the factory or make the scope
an explicit parameter. Keep tool profile selection and safe-mode filtering in
one location. Preserve conditional search-tool registration and all sandbox
flags, including the explicit pass-through runner when sandboxing is disabled.

### Sharing and accounting

Agents operating on the same files must share a mutation lock. Background runs
in the live project borrow its `ProjectToolScope`; they do not construct a fresh
lock merely because they have a separate ledger. Separate roots receive separate
scopes. If multiple sessions intentionally share a root, composition must pass
the same project scope rather than rely on a process-global singleton.

Keep current background-run accounting during migration: where a run uses an
ephemeral ledger and merges tokens into the live ledger, represent that as an
explicit owned ledger plus a completion accounting callback. Preserve existing
merge timing and cancellation/error behavior through characterization tests.
Do not silently reinterpret merged usage as shared rate-limit enforcement.

### Lifecycle and failures

Construct resources in stages. If a later stage fails, close only successfully
created resources in reverse ownership order. Stop admission of new work before
shutdown; signal cancellation, await owned work, then release providers and
stores. Observer callbacks must not prevent cleanup. Do not add an arbitrary
shutdown timeout as part of this refactor.

## Migration

1. Inventory mutable tool fields, global registries and disposal call sites.
2. Add scoped factories alongside existing assembly helpers. Test factories
   directly using existing memory filesystem and process-runner helpers.
3. Make main and sub-agent construction consume the same explicit tool scope.
4. Move provider decoration from shared registry mutation into the factory.
5. Pass factories into summary/environment execution; remove nested startup and
   decorator save/restore when A05 consumers migrate.
6. Remove `configureToolSandbox` and tool singletons after every production
   caller has migrated. Retain only standalone helpers that create independent
   scopes; keep immutable schema constants.

## Validation and acceptance criteria

- Two live runtimes in one isolate use different roots and sandbox settings;
  constructing B does not change A's read/write/bash/git/summary destinations.
- Interleave two background runs with controlled completers. Each provider is
  metered by its chosen ledger regardless of completion order.
- Same-project concurrent edits serialize through the shared mutation lock.
- Safe mode removes the same tools for main, spawned and delegated agents.
- Inject failure after each resource-acquisition boundary; assert owned resources
  close exactly once and borrowed resources remain usable.
- Existing engine tool, delegation, sandbox, composition and accounting tests
  pass; add targeted tests for behavior above rather than duplicate schemas.
- No runtime operation writes `registry.decorator` or mutates module-level tools.

## Risks and review notes

Accidentally creating a lock per tool weakens write serialization. Accidentally
sharing a provider across conversations mixes mutable request state. Review
these ownership edges explicitly. Keep temporary adapters internal and remove
them before claiming isolation; wrapping globals in a class does not satisfy it.
