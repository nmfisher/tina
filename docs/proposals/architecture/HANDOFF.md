# Architecture refactor handoff

Updated: 2026-09-07. A01 is implemented; A02–A08 are pending.

## Start here

Read [README.md](README.md) for the dependency graph and program scope, then the
individual spec for your task. These A-numbers identify local specification
files, not external issue-tracker tickets. No external tickets were created.

The next product-code task is **A02 configuration separation**. A07's dependency
baseline and A08's CI coverage can be done independently. Do not extract a new
application package before the application boundary has been established.

| Task | Spec | Next concrete work | Depends on |
| --- | --- | --- | --- |
| A01 | [Runtime isolation](01-runtime-isolation.md) | Complete; preserve its ownership and interleaving tests | — |
| A02 | [Configuration separation](02-configuration-separation.md) | Split runtime settings from CLI parsing and terminal theme/backend settings; migrate consumers with compatibility adapters | — |
| A03 | [Application operations](03-application-operations.md) | Extract spawn, branch, model selection and related application operations from TuiCoordinator; return frontend-neutral results | A01, A02 |
| A04 | [Session orchestration](04-session-orchestration.md) | Separate turn execution, background jobs, command dispatch and frontend input; introduce explicit lifecycle signals | A03, A05 |
| A05 | [Summary/environment services](05-summary-environment-services.md) | Inject repositories and agent-run factories; remove nested buildAppComposition calls and direct composition/I/O coupling from services | A01, A02 |
| A06 | [Application package](06-application-package.md) | Move the established frontend-independent application layer into tina_app and enforce its package boundary | A01–A05, A07 |
| A07 | [Dependency enforcement](07-dependency-enforcement.md) | Replace direct-import-only checks with direct and transitive enforcement and an explicit baseline | Independent baseline; ratchet during migrations |
| A08 | [Package CI](08-package-ci.md) | Add explicit validation for all owned packages, including attractor and fuzzy_ranker; extend for tina_app later | Independent |

Each linked spec includes the original problem, proposed interfaces or boundaries,
migration work, validation/acceptance criteria and risks. Read the current source
before following illustrative signatures: A01 used concrete types described below.

## A01 implementation map

- `packages/tina_engine/lib/src/agent/project_tool_scope.dart`: per-project tools,
  environment snapshot, sandbox, backup adapters and shared mutation lock.
  Relative paths and default directory arguments on scoped tools use that root.
- `packages/tina_engine/lib/src/agent/prompt_context.dart`: captured project root,
  trust decision and dynamically read repo/environment sources. `AgentPipeline`
  owns the context and its `ImageRenderer`. There are no global prompt sources or
  global image-render callbacks.
- `packages/tina_engine/lib/src/llm/registry.dart`: `LlmProviderFactory` interface
  and `RuntimeProviderFactory`, with runtime-local decorator/retry policy over a
  borrowed registry/catalog and shared endpoint limiter. Closing a factory stops
  new builds, without closing providers already handed to callers.
- `metering_provider.dart`, `retrying_provider.dart`, `wire.dart`: failed-attempt
  usage goes to the owning meter, including pooled retries via a send-scoped zone.
  Runtime meters do not install a global accounting callback.
- `lib/composition/app_composition.dart`: composition, validation of borrowed
  roots/trust, runtime factory and `AppComposition.dispose()`.
- `lib/composition/runtime_resources.dart`: reverse-order, exhaustive, idempotent
  cleanup. `run()` preserves the original work error if cleanup also throws.
- `sub_agent_scheduler.dart`: closes inline/standalone providers, rejects work
  during shutdown, cancels and awaits tracked work. Successful panel construction
  transfers provider ownership to its conversation.
- `summary_runner.dart` / `environment_runner.dart`: explicit tool/prompt borrowing
  and protected acquisition/cleanup. Resources finish before result recording and
  the existing completion-time ledger merge. Nested composition remains for A05.
- CLI, TUI, session manager and restore paths consume these scopes and clean up
  owned resources on normal completion and construction failures.

## Ownership rules to preserve

1. Runtime owns scheduler, classifier provider and internally created store.
   An injected store is borrowed unless `ownsStore: true` transfers it. The CLI
   uses that flag for its freshly constructed store.
2. Startup and subsequent conversation providers belong to their callers.
   `AppComposition.dispose()` does not close those providers. SessionManager
   owns registered conversations; `closeAll()` is now asynchronous and must be
   awaited by lifecycle owners.
3. A background run owns its app, providers and any host it creates. A supplied
   host, project tool scope, prompt context, registry and catalog are borrowed.
4. Same-project background runs receive both `toolScope` and `promptContext` from
   the parent pipeline. Different roots or conflicting trust decisions are rejected.
5. Catalog shutdown belongs to the CLI/process, never a background composition.
   Endpoint rate limiting remains shared by credential/endpoint intentionally.
6. Standalone tool assembly helpers and direct registry builds remain compatibility
   APIs. The helpers create independent scopes; production app paths use their
   pipeline tools and runtime provider factory.

Process-level CLI signals, terminal lifecycle, wire diagnostics and subprocess
reaping remain process-owned. A01 isolates execution dependencies; it does not
make the CLI support multiple simultaneous terminal frontends.

## Validation

From the repository root:

```sh
dart analyze
dart test test/composition test/persistence/session_restore_test.dart test/summaries/summary_runner_test.dart test/summaries/summary_index_refresh_test.dart test/environment/environment_runner_test.dart test/tui_coordinator_test.dart test/llm/config_providers_test.dart test/pipeline_test.dart test/regions/region_tools_test.dart test/import_boundary_test.dart test/session_manager_test.dart
```

From `packages/tina_engine`:

```sh
dart test
```

Results: 888 engine tests and 187 affected root/application/TUI/session tests pass;
analysis is clean. The entire root test suite was not run. No release was cut.

Focused additions include engine `project_tool_scope_test.dart`,
`prompt_context_test.dart`, `scheduler_lifecycle_test.dart`,
`runtime_provider_factory_test.dart`, and root composition
`project_tool_scope_test.dart`, `runtime_provider_factory_test.dart`,
`runtime_resources_test.dart`. Existing background tests observe registry policy
during sends, not just after completion.

## Workspace state

The user requested a commit of the entire working tree after A01 validation.
The specifications, implementation and tests are included together with the
pre-existing `.claude/`, `.poolside/` and `releases/` files. Those existing files
were included without modification. Consult git history for the commit.
No tags, pushes or release/version changes were made; the release artifacts
included here predate this refactor.

A stale generated native-hook cache was previously preserved at
`/private/tmp/tina-stale-hooks-5uhqvb_e` and regenerated to resolve an SDK-hash
mismatch. No native submodule or SDK source changes were made. Dart may require
permission to update its Flutter SDK cache outside the workspace.
