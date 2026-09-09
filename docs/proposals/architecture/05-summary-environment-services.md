# A05 — Inject repositories and execution factories into project services

Status: implemented and validated (2026-09-08). Uses scoped execution from A01 and configuration from A02.

Update (2026-09-09): environment execution now belongs to the main conversation.
`EnvironmentIndex` prepares task instructions and verifies record advancement;
`TurnExecutor` supplies the completion of that specific turn. The dedicated
`EnvironmentRunner`, its model selection, fixed folder survey, and separate
usage merge have been removed. Normal conversation delegation, approvals,
persistence, cancellation, and accounting apply. The environment execution
description below records the earlier implementation; the summary-service
architecture remains in use.

## Implementation and migration

The existing `SummaryIndex` and `EnvironmentIndex` names remain the refresh-capable
services. Their constructors require a repository and a fleet/runner; they no
longer accept nullable configuration/registry dependencies or construct storage.
`SummaryInspection` and `EnvironmentInspection` provide status-only access with
just a repository. `repoForTest` is removed: integration tests seed the supplied
sidecar adapter; service tests use memory repositories.

- `summaries/summary_repository.dart` defines `SummaryRepository`, `SummarySnapshot`,
  `SummaryPlan` and the pure `planSummaries` function. Plain manifest/status/result
  values live in `summary_models.dart`; the old sidecar module re-exports its
  persistence types for existing consumers. Planning selects ordinary or
  empty-manifest staleness, applies directory restrictions only to regeneration,
  and preserves reset/deletion behavior.
- `GitSummaryRepository` adapts `SidecarSummaryRepo`, allocations and environment
  inspection. Git staleness probes remain in the adapter; they are not called
  “pure.” Inspection does not initialize the sidecar. `prepare` initializes it
  before actual execution, since the atomic writer needs its parent directory.
  Dry-run and empty ordinary work skip preparation and model execution.
- `EnvironmentRepository` exposes inspection, verified advancement, tracking and
  folder enumeration. `FileEnvironmentRepository` adapts the existing record and
  tracking store. Status inspection avoids reading record bytes; refresh captures
  an immutable byte baseline. Prompt rendering moved to `environment_prompt.dart`.
- `SummaryFleet` and `EnvironmentAgentRunner` are injected execution interfaces.
  The concrete runners accept `ProjectExecutionFactory`; they do not construct
  an application or read files/process state directly. Folder enumeration is
  injected into the environment runner. Existing prompts, scouting limits,
  retries, model fallback and permission behavior remain in the runner.
- `application/project_execution.dart` supplies `ProjectExecution` and
  `RunInteraction`. Interaction carries a borrowed host, cancellation future,
  permission asker and scout-sink factory. The selected environment model is an
  explicit per-run argument. The first-load attention-queue asker is preserved.
- `composition/execution_runtime.dart` builds providers, ledger, quota, pipeline,
  classifier and scheduler without a session store or resume lookup. Application
  startup reuses this factory and adds session persistence/resolution. Runtime
  cleanup remains exhaustive and idempotent. Runners dispose owned work before
  returning usage to the service; injected hosts and frontend scout sinks remain
  borrowed. Scout retries can request another sink; their frontend owns disposal.
- `composition/project_services.dart` binds repositories, runtime configuration,
  execution factories and accounting for TUI and headless consumers. It also
  supplies standalone run adapters for explicitly bound run options. Refresh
  factories capture absolute project roots at construction.

## Recording and accounting policy

This refactor preserves the existing summary verification boundary: a requested
summary counts when its slug-derived file exists. A missing file remains stale;
a pre-existing file can satisfy verification even if the current agent did not
rewrite it. Recording stamps the **current HEAD/tree at record time**, which can
differ from the state the agent read or the header it wrote. This is characterized
by real-Git tests; there is no transaction or new content-freshness guarantee.
Repartition begins with an empty manifest; previously tracked keys outside the
new plan are forgotten, not synthesized into deletions.

A settled summary fleet, including cancellation, records whatever files landed
and applies planned deletions. Execution exceptions skip recording. Summary spend
merges only after successful record/save/commit; recording failures remain visible
and skip the merge, preserving prior accounting. Environment spend merges after
settled execution, even for cancelled/no-answer/no-write outcomes, and before
tracking. Execution exceptions skip that merge. Only a completed environment
answer plus a present first-load record or changed verification bytes advances
tracking; tracking-write errors propagate.

One adapter correctness fix was necessary: `SidecarSummaryRepo.init` previously
accepted any directory *inside* a Git worktree, including the main project. It now
requires a Git root at the sidecar path and initializes its own repository when
needed. Tests assert that a summary commit leaves the project HEAD unchanged.
Existing misplaced history is not rewritten or migrated. Also, unlike the former
runner's eager initialization, dry-run and empty ordinary work no longer create
an unused sidecar directory/repository.

## Validation and remaining orchestration

Memory-only tests cover first/unchanged state, allocations, restricted plans,
repartition, dry-run, missing and partial writes, cancellation, recording failures
and accounting. Environment decision tests cover absent, unchanged, advanced and
vanished records, incomplete runs, interaction forwarding and tracking failures.
An injected-execution failure test verifies cleanup without disposing the borrowed
host. Real-Git integration tests retain fleet writes, layout and commits, and add
HEAD-change, pre-existing-file and independent-sidecar characterization.

Dependency checks reject direct IO in services/runners, transitive IO in pure
summary planning, and transitive imports of application/execution/service assembly
from services/runners. See [HANDOFF.md](HANDOFF.md) for the validation command and
result. A04 subsequently integrated these cancellation/result boundaries with
its background-job supervisor; see [the A04 implementation](04-session-orchestration.md).

## Original problem and source anchors

[`SummaryIndex`](../../../lib/summaries/summary_index.dart) constructs its
`SidecarSummaryRepo` internally, exposes `repoForTest`, and creates a concrete
`SummaryRunner`. [`EnvironmentIndex`](../../../lib/environment/environment_index.dart)
similarly constructs tracking storage and an environment runner. Both allow
construction without dependencies required by `refresh`, then fail at runtime.

The runners import application composition and create a whole nested application
to execute a feature. This forms a cycle between assembly and the services it
assembles. Git and filesystem effects also force service-level tests to create
real repositories, even when the behavior under test is a regeneration decision.

## Goals and non-goals

Make project-state inspection and regeneration orchestration testable with small
fakes. Keep actual Git, filesystem and agent execution in adapters. Preserve
sidecar layout, staleness semantics, summary prompts, environment success criteria
and permission behavior. Do not replace the Git storage model or introduce a
general repository framework.

## Service boundaries

| Boundary | Responsibility |
| --- | --- |
| `SummaryRepository` | Read project/sidecar state, persist manifests, record landed summaries and commit |
| Summary planning function | Select regeneration/deletion work from snapshot, allocations and request |
| `SummaryFleet` | Execute planned agent work using injected execution resources |
| `SummaryService` | Inspect, plan, execute, record verified results and return refreshed status |
| `EnvironmentRepository` | Read record/tracking state and record verified environment progress |
| `EnvironmentAgentRunner` | Execute the existing environment/scout workflow |
| `EnvironmentService` | Inspect status and coordinate execution with verified tracking updates |

Adapt `SidecarSummaryRepo`, `AllocationsStore`, `EnvironmentTrackingStore` and
environment input collection rather than rewrite their implementations.

## Proposed API shape

```dart
abstract interface class SummaryFleet {
  Future<SummaryExecutionResult> run(
    SummaryPlan plan,
    RunInteraction interaction,
  );
}

abstract interface class SummaryRepository {
  Future<SummarySnapshot> inspect();
  Future<SummaryRecordResult> record(SummaryPlan plan);
}
```

These signatures show the direction, not a mandate for two all-purpose methods.
Split repository operations where necessary to express existing ordering and
errors. Snapshot and plan types contain plain values: committed HEAD, recorded
manifest entries, allocated partitions, stale/deleted paths and request flags.
They contain no `Directory`, `ProcessResult`, provider registry or terminal type.

`RunInteraction` supplies the existing output sink, permission/question callbacks
and cancellation signal needed by the runner. It does not contain configuration,
storage, panel objects or an entire application. A03/A04 adapters bind the active
conversation and job handle. Keep a standalone headless adapter at composition.

Construct refresh-capable services with required dependencies. If callers need
only status, expose an inspection interface or repository-backed status service;
do not retain nullable configuration followed by `StateError` in `refresh`.

## Summary flow

1. Inspect repository state without creating a sidecar or committing anything.
2. Build a plan from existing partition/allocation and staleness rules. Preserve
   restricted-directory, dry-run and repartition behavior.
3. Return immediately for dry-run or empty work under the same rules as today.
4. Execute the fleet through its injected factory. It owns its agent providers,
   borrows the chosen project tool scope, and uses explicit accounting policy.
5. Verify which requested summary files actually landed. A successful agent
   response alone does not make a directory current.
6. Record only verified results and existing deletion semantics, commit using the
   adapter, then inspect again for the returned status.

Capture the current behavior when HEAD changes during a run before extraction.
Preserve it in the initial PR and document the snapshot/record boundary. Do not
quietly introduce a new freshness algorithm or claim a transaction across Git
and streamed agent writes. Partial execution must not falsely mark missing work
complete; failures and remaining stale paths stay observable.

## Environment flow

Inspect the environment record and tracking state through the repository. Capture
the pre-run record state, execute the existing environment/scout behavior, then
verify that the record actually advanced before recording success. Preserve the
current cancellation/no-answer/no-write failure distinctions.

The runner receives the selected model and permission asker explicitly. Preserve
the first-load attention-queue asker: falling back to a background host that
auto-denies would change behavior. Scout output uses an injected sink factory
whose scope and disposal are documented; it does not allocate panels itself.

## Infrastructure and effects

Repository adapters may use real `dart:io` and Git. Pure planning must not. Reuse
the existing engine `ProcessRunner` where its asynchronous contract fits. Where
current synchronous Git inspection needs a different shape, use a narrow Git
adapter rather than expanding every tool's process interface.

A factory for repositories alone is insufficient if service methods still reach
directly into `File`, `Directory.current`, `Platform` or `Process.runSync`.
Project roots and environment snapshots enter through construction.

## Migration steps

1. Define snapshots/results around current repository return values; identify
   status-only consumers and refresh consumers.
2. Put existing repositories behind narrow interfaces and inject them into index
   services. Delete `repoForTest`; tests seed the supplied fake or real adapter.
3. Extract pure planning only where decisions are currently mixed with I/O.
4. Inject fleet/environment runners and move their construction to composition.
5. Replace nested `buildAppComposition` with A01 execution factories; remove
   shared registry mutation and tool reconfiguration.
6. Bind cancellation and completion through A04's supervisor.
7. Retain existing real-Git tests as adapter integration coverage while moving
   service branching/failure assertions to memory-based tests.

## Acceptance criteria

- Unit tests cover first run, unchanged state, stale/deleted directories,
  allocations, restricted regeneration, repartition and dry run without Git.
- Failed/missing summary writes stay stale; cancellation and partial results
  obey characterized recording and spend-accounting behavior.
- Environment tests cover absent/unchanged/advanced record and cancelled runs;
  only verified progress advances tracking.
- Adapter integration tests cover actual Git commits, file layout and manifest
  round trips using isolated temporary repositories.
- No service or runner imports `composition/app_composition.dart` or constructs
  providers through a mutable shared registry.
- Required refresh dependencies are explicit at construction; no test-only
  repository escape hatch remains.

## Review risks

Do not rename “Git-only” probes to “pure” while they still execute processes.
Do not mock away Git correctness: retain adapter tests. The goal is to separate
decision tests from infrastructure tests, not eliminate the latter.
