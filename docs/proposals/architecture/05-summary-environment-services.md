# A05 — Inject repositories and execution factories into project services

Status: proposed. Uses scoped execution from A01 and configuration from A02.

## Problem and source anchors

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
