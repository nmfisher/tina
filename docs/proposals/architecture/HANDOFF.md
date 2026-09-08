# Architecture refactor handoff

Updated: 2026-09-08. A01–A05 are implemented. A07's dependency checker is
implemented with a 51-entry baseline. A06 and A08 are pending.

## Start here

Read [README.md](README.md) for the dependency graph and program scope, then the
individual spec for your task. These A-numbers identify local specification
files, not external issue-tracker tickets. No external tickets were created.

The next task is **A06 application package extraction**. A08 package CI can
proceed independently. The A07 baseline is established; keep it ratcheting down
as migrations fix their dependency chains.

| Task | Spec | Next concrete work | Depends on |
| --- | --- | --- | --- |
| A01 | [Runtime isolation](01-runtime-isolation.md) | Complete; preserve its ownership and interleaving tests | — |
| A02 | [Configuration separation](02-configuration-separation.md) | Complete; retain the transitive config/application boundary checks and migrate remaining facade-based test fixtures as touched | — |
| A03 | [Application operations](03-application-operations.md) | Complete; preserve explicit targets, ownership, snapshot and selection/presentation boundaries | A01, A02 |
| A04 | [Session orchestration](04-session-orchestration.md) | Complete; preserve admission/acknowledgement, shutdown, command capability and activity identity boundaries | A03, A05 |
| A05 | [Summary/environment services](05-summary-environment-services.md) | Complete; preserve injected repositories/execution, verification/accounting policy and independent sidecar Git commits | A01, A02 |
| A06 | [Application package](06-application-package.md) | Move the established frontend-independent application layer into tina_app and enforce its package boundary | A01–A05, A07 |
| A07 | [Dependency enforcement](07-dependency-enforcement.md) | Complete; keep the baseline ratcheting down (facade-fixture entries owned by A02, TUI backend exception, probe and test-helper exceptions). A06 adds the tina_app manifest closure | Independent baseline; ratchet during migrations |
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

## A02 implementation map

- `Config.parse(...).launch` is the root resolver. It provides `RuntimeConfig`,
  `TerminalConfig` and `StartupOptions`. The latter contains `ResumeRequest`.
  The parser preserves early exits and field-specific precedence; the A02 spec
  includes the field inventory. Explicit model-source metadata remains
  `runtime.modelExplicit` for resume behavior.
- Application composition, agent construction, provider resolution, background
  services and restore accept RuntimeConfig. CLI supplies `resumeRequest` and
  terminal settings separately. Runtime collections are immutable snapshots.
- `Config` remains a root compatibility facade extending RuntimeConfig and
  implementing ResumeRequest. Application code does not import it. Legacy tests
  can still pass it, but new code should use explicit runtime fixtures / requests.
- UserConfig stores plain `ThemeOverrides`; `theme_mapper.dart` maps to console
  Theme. Existing model/settings reload boundaries remain fresh. Picker key lookup
  lives in `config/provider_selection.dart`, outside neutral provider resolution.
- PipelineRunner accepts `interviewerBuilder` and `onNodeStart` instead of screen,
  editor or attention-queue types. TUI supplies the existing adapters. The neutral
  HeadlessInterviewer preserves headless human-gate behavior.
- `test/config/runtime_boundary_test.dart` walks transitive import/export/part and
  conditional dependencies for runtime settings and application consumers. These
  tested closures contain no terminal, args or TOML dependencies. A07 still owns
  program-wide enforcement and a general baseline.

## A03 implementation map

- `lib/application/conversation_operations.dart`: explicit target/request/result
  types and spawn/branch/changeModel operations using the existing SessionManager.
  Host construction is injected; registration transfers ownership to conversations.
- TUI pickers capture session/source before awaiting. They supply freshly loaded
  prompt/key settings, then present successful results. Creation fails before
  layout changes; presentation failure retains the saved conversation and reports
  its ID. A session switch during the picker does not retarget the operation.
- Branching supports running sources and takes one deep snapshot before awaits.
  Both memory and persisted history use it. Side conversations retain their
  historical 512-token / 50-step tuning and policy behavior.
- Model swaps retain the existing immediate behavior during running turns. The
  conversation and agent adopt the new provider before old-provider closure;
  cleanup and non-missing-record persistence failures are reported explicitly.
- `conversation_selection.dart` plus `host/selection_presenter.dart`: state changes
  return a selection result; production frontend callers apply presentation.
  Side focus uses persist:false, preserving the primary resume anchor. Existing
  switch methods remain compatibility adapters. Restore is still centralized.
- New operation tests cover fake-only execution, captured targets, deep snapshots,
  cleanup/compensation errors and provider ownership. TUI tests cover attachment
  failure and normal fork rendering. The A02 transitive test guards the service.

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

## A05 implementation map

- `lib/application/project_execution.dart`: owned execution contract and borrowed
  `RunInteraction` adapters; cancellation and the environment's attention asker
  stay explicit. Scout sinks belong to the frontend that creates them.
- `lib/composition/execution_runtime.dart`: shared provider/pipeline/scheduler
  construction with no store or resume lookup. `buildAppComposition` now adds
  session state around it; background runners receive its factory directly.
- `lib/composition/project_services.dart`: TUI/headless assembly and standalone
  run adapters; refresh services require repositories and execution dependencies.
- `lib/summaries/summary_index.dart`, `summary_repository.dart`, `summary_models.dart`:
  status-only inspection, service, pure planning and plain values.
  `git_summary_repository.dart` adapts the original sidecar/allocation stores.
- `lib/environment/environment_index.dart`, `environment_repository.dart`:
  status-only inspection and verified refresh; `file_environment_repository.dart`
  owns file/tracking/folder reads. `environment_prompt.dart` owns warm prompt IO.
- Concrete runners execute existing prompts/scouting through injected factories;
  services own verification/recording. Summary spend merges after successful
  recording; environment spend merges before verified tracking. Exceptions and
  partial writes preserve the policies in the A05 spec.
- The sidecar adapter now checks for its **own Git root**. Previously it could
  accept the parent project repository and put summary commits there. New tests
  verify separate history; existing misplaced history is left untouched.
- Summary verification intentionally remains file-presence-based, including old
  files, and stamps the HEAD/tree at recording time. HEAD changes during execution
  are characterized, not made transactional. Dry-run and empty ordinary work now
  leave an absent sidecar absent.

## A04 implementation map

- `lib/application/turn_executor.dart`: explicit admission, cancellation,
  interruption, queue draining, recording order, workflow-result injection and
  completion/shutdown. Cancelling remains busy until cleanup completes.
- `lib/application/background_job_supervisor.dart`: one application job per kind,
  captured owner, cancellation and completion handles.
  `project_background_jobs.dart` binds the A05 services and notices. First-load
  environment setup uses this same supervisor through the TUI adapter.
- `lib/frontend/session_input_state.dart`: drafts and Escape arming.
  `SessionController` remains the frontend read/dispatch/navigation facade.
- `lib/session_commands/command_capabilities.dart`, `command_families.dart`:
  narrow family dependencies with unchanged registry metadata. The legacy
  `CommandContext` constructor and `ControllerCommandAdapter` preserve existing
  wiring; the facade no longer implements that aggregate.
- Engine `run_lifecycle.dart` and `host_lifecycle_adapter.dart`: identity-based
  signals and concurrent host activity. Agent no longer imports HostInterface.
  Outer turns/jobs retain activity beyond nested agent completion.
- `WorkflowSupervisor.shutdown` rejects late launches, waits and suppresses late
  completion injection. TUI teardown waits for controller shutdown before widget
  and runtime disposal. Session closure defers resources until turns settle.
- `Agent.compact(cancelSignal:)` cancels its subscription and leaves history
  intact; shutdown preserves the prompt already flushed for resume. Explicit
  Escape cancellation still rolls back and drains queued work; shutdown stops it.

## A07 implementation map

- `tool/architecture/dependency_graph.dart`: analyzer-based import graph.
  Imports, exports, parts, relative and `package:` URIs and every conditional
  import/export branch resolve to files; parts merge into their owning library;
  cycles and escapes are detected over the same edges.
- `tool/architecture/policy.dart` + `policy.json`: declarative classification
  and rules — frontend exclusion for non-frontend code, assembly direction for
  service roots, package direction, public-API (no cross-package `src/`),
  pure-planning and service-IO restrictions, manifest dependency closure, and
  full file coverage (an unclassified source or package fails the check).
- `tool/check_architecture.dart`: CLI entry point; `--report` prints violations
  as JSON. `tool/architecture/baseline.json` holds exact, reasoned, task-owned
  exceptions; both new and stale entries fail.
- `test/architecture/dependency_graph_test.dart`: 15 fixture tests covering
  multi-hop, export-mediated, relative and conditional violations, guarded
  helpers, parts, cycles, manifest closure, workspace coverage and baseline
  exactness.
- `test/import_boundary_test.dart` now runs `checkWorkspace` +
  `applyBaseline`; the original direct-import scan is subsumed and enforcement
  runs in the normal test suite.
- Baseline: 51 entries. 24 × A02 — facade-based test fixtures reach
  `tina_console` through `lib/config.dart`; migrate those fixtures to
  RuntimeConfig and delete the entries. 1 × A07 — `tui_coordinator.dart`
  constructs the notcurses backend directly; the spec's named exception until
  a public console factory exists. 23 × A07 — `tool/` diagnostic probes
  reaching console internals intentionally. 3 × A07 — pre-existing relative
  imports of other packages' test helpers.

## Validation

Current A07 validation, from the repository root:

```sh
dart run tool/check_architecture.dart
dart test test/architecture test/import_boundary_test.dart
dart analyze
```

A07 results: the checker scans 589 owned files and passes against 51 exact
baseline exceptions; all 16 checker tests pass; analysis is clean. A07 changed
no production source, so the full root and engine suites were not rerun.

Current A04 validation, from the repository root:

```sh
dart analyze
dart test test/application test/session_controller_test.dart test/workflow_supervisor_test.dart test/conversation_test.dart test/session_manager_test.dart test/session_commands test/tui_coordinator_test.dart test/tui/conversation_panel_coordinator_test.dart test/summaries test/environment test/composition test/config/runtime_boundary_test.dart --concurrency=1
```

From `packages/tina_engine`:

```sh
dart analyze
dart test --concurrency=1
```

Final focused executor check: `dart test test/application/turn_executor_test.dart`.

A04 results: the combined regression run passes 378 root tests. A subsequent
9-test executor run also covers the final session-owned closure case (379 unique
root tests in total). All 892 engine tests pass; root and engine analysis and
`git diff --check` are clean. New tests use controlled completers/streams for
admission, cancellation acknowledgement, shutdown and concurrent lifecycle signals.

Previous A05 validation, from the repository root:

```sh
dart analyze
dart test test/summaries test/environment test/composition test/session_commands test/config test/application test/tui_coordinator_test.dart test/session_controller_test.dart test/session_manager_test.dart test/conversation_test.dart test/tui/conversation_panel_coordinator_test.dart test/persistence/session_restore_test.dart test/import_boundary_test.dart --concurrency=1
```

A05 results: 441 targeted tests pass; analysis and `git diff --check` are clean.
This includes the new memory-only service tests, injected execution cleanup,
Git recording characterization, existing fleets, TUI and session regression tests.

Previous A03 validation, from the repository root:

```sh
dart analyze
dart test test/application test/tui_coordinator_test.dart test/session_manager_test.dart test/session_controller_test.dart test/conversation_test.dart test/tui/conversation_panel_coordinator_test.dart test/persistence/session_restore_test.dart test/config/runtime_boundary_test.dart test/session_commands test/composition --concurrency=1
```

A03 results: 267 tests pass; analysis and `git diff --check` are clean.
Use `--concurrency=1` for this combined command: existing TUI and session-resolution
fixtures change the process working directory. A concurrent run exposed two
failures from their overlapping temporary-directory lifetimes; the sequential
run passes. Those fixtures still need process-directory isolation in future work.

Previous A02 validation, from the repository root:

```sh
dart analyze
dart test test/pipeline_test.dart test/config test/composition test/config_test.dart test/cli_session_flags_test.dart test/persistence/session_restore_test.dart test/tui_coordinator_test.dart test/summaries test/environment test/llm/config_providers_test.dart test/permissions/config_test.dart test/tui/setup_overlay_test.dart test/pipeline test/workflow_supervisor_test.dart test/import_boundary_test.dart
```

From `packages/tina_engine`:

```sh
dart test
```

A02 results: 437 targeted root/configuration/application/TUI/workflow tests pass;
analysis is clean. A01 previously passed 888 engine and 187 targeted root tests.
A02, A03 and A05 changed no engine source; A04 changed lifecycle and compaction
cancellation and reran the complete engine suite as documented above. The entire
root test suite was not run. No release was cut.

Focused additions include engine `project_tool_scope_test.dart`,
`prompt_context_test.dart`, `scheduler_lifecycle_test.dart`,
`runtime_provider_factory_test.dart`, and root composition
`project_tool_scope_test.dart`, `runtime_provider_factory_test.dart`,
`runtime_resources_test.dart`. Existing background tests observe registry policy
during sends, not just after completion.

## Workspace state

A01 was committed as `54e136e`. A02–A05 are committed as `b12c80d`. A07's
checker, policy, baseline, tests and documentation follow in the next commit.
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
