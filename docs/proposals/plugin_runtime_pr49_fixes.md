# PR #49: plugin runtime remediation plan

Status: proposed fixes; this document does not implement them.
Review date: 2026-09-11.
Reviewed revision: [`7321611`](https://github.com/nmfisher/tina/pull/49/changes/7321611eb416d9a108ba9148034971f652ade596).
Specification: [plugin runtime implementation plan](plugin_runtime.md).

PR #49 introduces useful runtime primitives and extracts execution and driver
interfaces, but it is not a complete implementation of the specification.
Several registered extensions never reach production consumers. The execution
hooks and lifecycle APIs also fail guarantees required by the plan.

The recommendation is to request changes. Complete the fixes below before
describing P0–P8 as delivered. Keep each fix independently reviewable and retain
the existing read-all, environment-phase, approval, sandbox retry, cancellation,
and provider ownership behavior.

## 1. Recheck authority at actual tool dispatch — P1

Source: [tool_executor.dart:533](https://github.com/nmfisher/tina/blob/7321611eb416d9a108ba9148034971f652ade596/packages/tina_engine/lib/src/agent/tool_executor.dart#L533).

The final runtime check currently runs before execution hooks. An asynchronous
hook can wait while the permission mode changes to `readAll` or the turn is
cancelled, then invoke its delegate and still execute the tool. Both cases were
reproduced using fake tools.

Fix:

- Keep the early policy and phase gates before classification or approval.
- Put the final authority and cancellation checks inside the innermost delegate,
  after all hook preparation and immediately before calling the tool.
- If any guard performs asynchronous work, check the current mandatory state
  again after that work. Leave no asynchronous gap between that last check and
  dispatch.
- Preserve blocked-result formatting and emit one completion event. A denied or
  cancelled call must not invoke the underlying tool or request fresh approval
  merely because it passed through a hook.

Acceptance tests: suspend a hook with a completer, change mode or environment
phase or cancel the turn, then release it. Assert zero underlying executions and
the appropriate error/cancellation outcome. Retain existing same-batch mode
transition and sandbox retry tests.

## 2. Seal approved arguments — P1

Sources: [tool_executor.dart:742](https://github.com/nmfisher/tina/blob/7321611eb416d9a108ba9148034971f652ade596/packages/tina_engine/lib/src/agent/tool_executor.dart#L742),
[tool_hooks.dart:19](https://github.com/nmfisher/tina/blob/7321611eb416d9a108ba9148034971f652ade596/packages/tina_engine/lib/src/agent/tool_hooks.dart#L19).

`ToolCallContext.input` exposes the same mutable map that the tool executes. A
probe changed an allowed command into a denied command inside the hook; the
changed command reached the fake tool. A `final` map field does not make its
contents immutable.

Fix:

- Take a detached snapshot of model-provided JSON arguments before authorization.
  Use that snapshot consistently for policy matching, approval display, and
  execution.
- Expose deeply immutable argument views to hooks and observers, including nested
  maps and lists. Audit event payloads for aliases to execution arguments.
- Keep any required mutable tool-local copy private to the executor/tool boundary.
- Preserve the existing explicit authorization path for sandbox retry changes;
  build and validate a new execution snapshot there rather than exposing a
  general argument-rewriting hook.

Acceptance tests: attempt top-level and nested mutations through hooks and
observers, and mutate the caller's original map during an approval wait. The
executed arguments must remain those authorized. Assert both the approval text
and the arguments received by the fake tool.

## 3. Own and join hook delegates — P1

Source: [tool_executor.dart:718](https://github.com/nmfisher/tina/blob/7321611eb416d9a108ba9148034971f652ade596/packages/tina_engine/lib/src/agent/tool_executor.dart#L718).

The invocation counter detects zero or multiple calls, but does not control the
delegate's lifetime. A hook can start work without awaiting it and return early.
It can also save the delegate, return without calling it, and invoke it after the
executor has reported a hook error. Both behaviors were reproduced.

Fix:

- Track whether each hook invocation is open, whether delegation has started,
  and the future representing delegated work.
- Reject delegate calls after the hook closes and reject repeat calls before
  starting any additional work.
- Close the delegate handle on every hook exit, including exceptions.
- Join any work already started on success and failure paths before the executor
  returns, reports completion, or permits resource teardown. Preserve the
  existing cancellation mechanism for that work.
- Define deterministic result/error precedence for a hook failure combined with
  a delegate failure. Observe both futures so failures cannot escape unhandled.

Acceptance tests: early return after delegation, throw after delegation, a saved
delegate invoked after rejection, double delegation with the exception swallowed,
nested hooks, and cancellation during delegated work. Assert at most one tool
execution, no execution after closure, and no completion before work settles.

## 4. Make registrations and scopes reversible — P2

Source: [plugin.dart:123](https://github.com/nmfisher/tina/blob/7321611eb416d9a108ba9148034971f652ade596/packages/tina_engine/lib/src/runtime/plugin.dart#L123).

Registration disposal invokes cleanup but does not remove the contribution or
release its ID. Runtime disposal leaves services discoverable. These were
reproduced independently of any application or terminal dependencies.

Fix:

- Make a registration own both registry membership and its optional cleanup.
  Register that ownership with the scope even when no cleanup was supplied.
- Revoke membership when disposal begins. Define when the ID becomes reusable;
  after awaited disposal it must be reusable without collision or interference
  from the previous registration's cleanup.
- Make disposal idempotent, sharing the same completion future across callers.
- Give scopes explicit active, stopping, and disposed states. Close admission
  before draining children and resources; reject registration, provision, and
  child creation once stopping starts.
- Remove owned services and contributions during teardown. A disposed scope must
  not resolve a released service or expose borrowed services through a dead scope.
  Do not dispose the parent's borrowed resources.
- Preserve child-before-parent and consumer-before-provider teardown order,
  continuing cleanup after errors and joining owned work before resource release.

Acceptance tests must inspect registry membership and lookup results, not only
cleanup callback counts. Cover early disposal, ID reuse, scope disposal after
early disposal, concurrent disposal, cleanup errors, child admission during
teardown, and parent-owned resources surviving child disposal.

## 5. Await failed-startup rollback — P2

Source: [runtime.dart:343](https://github.com/nmfisher/tina/blob/7321611eb416d9a108ba9148034971f652ade596/packages/tina_engine/lib/src/runtime/runtime.dart#L343).

The failure paths call asynchronous `_rollback()` without awaiting it, including
when invoked through asynchronous `activate()`. A gated-cleanup probe confirmed
that activation rejects before cleanup finishes.

Fix:

- Make asynchronous activation await rollback before propagating the composition
  error. Preserve the original failure and stack trace while collecting teardown
  failures for diagnostics.
- Register ownership before activation can acquire resources, including resources
  acquired by the factory that subsequently throws.
- Mark the failed runtime unusable and accurately reflect its terminal state.
  Retrying startup should create a new runtime after the failed one has drained.
- Do not implement asynchronous activation by delegating to a synchronous method
  that detaches cleanup. Prefer asynchronous composition. If a synchronous path
  remains necessary, constrain it to genuinely synchronous ownership and cleanup
  with an explicit contract.

Acceptance tests: hold cleanup behind a completer after a later factory fails.
Activation must remain pending until cleanup finishes. Verify failed-factory
cleanup, reverse order, exactly-once provider close, rollback errors, and no
overlap between a failed startup and its replacement.

## 6. Connect plugin contributions to production composition — P1

Sources: [execution_runtime.dart:213](https://github.com/nmfisher/tina/blob/7321611eb416d9a108ba9148034971f652ade596/packages/tina_app/lib/src/composition/execution_runtime.dart#L213),
[system_prompt.dart:185](https://github.com/nmfisher/tina/blob/7321611eb416d9a108ba9148034971f652ade596/packages/tina_engine/lib/src/agent/system_prompt.dart#L185).

A mounted `driverPlugin` publishes its service, but the scheduler receives a
separate constructor parameter instead. A composition probe found the service in
the scope while `scheduler.driverFactory` remained null. Guard, execution-hook,
and prompt-contributor scope collectors also lack production consumers; prompt
construction still selects the defaults directly.

Fix:

- Resolve the selected driver factory and ordered contributions from the active
  scope at the typed composition boundary. Pass those resolved dependencies into
  consumers; avoid giving runtime code a general service locator.
- Use the same registration path for built-ins and replacements. Translate any
  temporary compatibility parameters into profile overrides with explicit
  conflict handling, then remove duplicate wiring when callers migrate.
- Connect tool, guard, execution-hook, result-hook, observer, and prompt
  contributions to their actual consumers. Preserve stable ordering and required
  metering and authority layers.
- Avoid a hardcoded internal tool runtime that ignores the outer profile's tool
  contributions. Make project scope construction consume the resolved selection.
- Preserve selected conversation extensions when borrowing project services;
  do not silently discard extensions through a built-in-ID allowlist.
- Validate the complete profile, including required application outputs, before
  factories perform side effects. Missing services should produce actionable
  composition errors rather than null assertions after activation.

Acceptance tests must build an application with test plugins and observe actual
behavior: a guard blocks execution, a hook runs, a prompt section reaches the
provider request, and the selected driver performs a turn. Exercise borrowed
project scopes. For invalid profiles, count factory invocations and assert zero;
checking only model-provider construction is insufficient.

## 7. Complete driver replacement across entry points — P1

Sources: [sub_agent_scheduler.dart:301](https://github.com/nmfisher/tina/blob/7321611eb416d9a108ba9148034971f652ade596/packages/tina_engine/lib/src/agent/sub_agent_scheduler.dart#L301),
[conversation.dart:26](https://github.com/nmfisher/tina/blob/7321611eb416d9a108ba9148034971f652ade596/packages/tina_app/lib/src/session/conversation.dart#L26).

The selected factory covers two plain scheduler paths but excludes live panels.
Main and panel construction remain concrete. `Conversation` requires both an
`Agent` and a driver, leaving callers responsible for keeping them synchronized.

Fix:

- Inventory main interactive, restored/branched/new conversation, live-panel
  delegate, telemetry-only delegate, headless, and standalone workflow creation.
  Route every applicable path through the scope-selected `AgentDriverFactory`.
- Make `Conversation` and its consumers depend on `AgentDriver` alone. Extend the
  contract only for operations callers need; do not require a concrete `Agent`,
  an adapter downcast, or a paired implementation object.
- Keep the existing `Agent` behind the default factory. Preserve the established
  owners of history, providers, persistence, cancellation, and turn completion.
- Ensure restoration and provider replacement use the same contract and do not
  introduce a second provider-close path.

Acceptance tests: use a scripted driver that does not construct an `Agent` and
run it through every entry point above. Verify turn dispatch, cancellation,
compaction, provider replacement, restoration, and cleanup. Factory-reference
identity assertions alone do not demonstrate replacement.

## Finish the planned architecture and testability work

The seven fixes address concrete defects, but do not by themselves complete the
original plan:

- **P2:** Separate project capability interfaces from production construction.
  Allow filesystem, process runner, and related dependencies to be injected;
  `ProjectCapabilities.build` currently constructs concrete IO dependencies.
  Run the same tool plugins against in-memory capabilities and production
  capabilities, retaining project isolation and shared mutation-lock tests.
- **P6:** Mount delegation, workflows, environment setup, persistence, commands,
  and frontend adapters through the shared lifecycle. Adding optional factory
  parameters is not equivalent to migrating those features into plugins.
- **P7:** Provide the planned interactive/headless profiles and startup-only
  configuration of compiled-in plugins. Validate overrides before side effects
  and expose effective composition diagnostics. External loading and live code
  replacement remain outside scope.
- **P8:** Remove legacy construction paths and temporary adapters, update the
  architecture rules, and add feature documentation describing the final API.
  Update phase status to match delivered behavior.
- **Caching:** Add serialized provider-request fixtures covering tools, system
  instructions, and prior message prefixes. Freeze volatile inputs in tests.
  Verify mode changes affect runtime authority without changing previously sent
  prefix bytes, tool ordering, or plugin topology.

## Verification and delivery order

Suggested commit sequence:

1. Reversible registrations/scopes and awaited rollback, with focused unit tests.
2. Immutable arguments, final dispatch checks, and owned hook delegation, with
   the corresponding regression tests.
3. Production contribution resolution and complete profile validation.
4. Driver migration across every entry point and behavior-level composition tests.
5. Remaining capability, application-feature, profile, cache-fixture, and
   documentation work from P2/P6–P8.

Run focused tests for each change, then the relevant engine, application, and
root suites. Run static analysis and `dart tool/check_architecture.dart` when
composition or dependency boundaries change. Exercise interactive frontend
behavior through fake hosts where possible; headless composition must not
initialize a terminal.

Review evidence at the pinned revision:

- Nine focused probes failed their expected invariants: mode change during hook
  preparation, cancellation during preparation, argument mutation, unjoined
  delegated work, late delegation, stale registration membership, lookup after
  disposal, incomplete rollback, and a mounted driver missing from the scheduler.
  These probes used fake tools; no real shell command was needed to demonstrate
  unauthorized dispatch.
- Local engine/application static analysis and the architecture checker passed.
  Those checks do not establish runtime ownership or replacement behavior.
- Existing engine, application, and root CI checks passed. Console CI reported
  nine failures; the review did not establish that PR #49 introduced them.
  See the [reviewed CI run](https://github.com/nmfisher/tina/actions/runs/34507135875).
- Local broad-suite runs encountered temporary-directory and environment-related
  failures. They were not treated as plugin regressions or reported as a clean
  full-suite result.

The regression scenarios above are the durable specification for new checked-in
tests. The review's temporary probe files are not dependencies of this plan.
