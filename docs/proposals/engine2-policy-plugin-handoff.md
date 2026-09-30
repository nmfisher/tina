# Engine2 policy/plugin separation — implementation handoff

Status: implemented. The findings below record the original baseline.
Async fail-closed hooks, optional step limits, plugin-owned state, persisted mode,
capability-based requirements and a single approval path are now implemented.
The identity plugin is named `tina/system-instruction`; old config IDs remain readable.
Baseline inspected: `0cfb059` on `asb/engine2`.

## Objective and constraints

Remove built-in step policy, unsafe hook-failure behavior, feature-specific core
state, duplicate mode ownership, hardcoded plugin requirements, and the obsolete
approval decision path. Preserve the current CLI, terminal rendering, session
history, scoped plugin settings, and live attachment behavior.

User requirements:

- Work on **`asb/engine2` only**. Do not create another branch.
- Commit coherent increments. Push only after the relevant tests pass.
- Limits such as maximum steps belong to plugins, not the agent loop.
- Plugins are managed through **Settings → Plugins**, with checkboxes and
  Global/Workspace/Session scopes. Do not restore `/plugins`.
- Plugin definitions require a nonempty user-facing description. Show metadata
  even for disabled plugins, without constructing them.
- Preserve namespacing; `tina/` is reserved for first-party plugins.
- Keep workflow/Attractor integration disconnected from the new application.
  Keep their packages and legacy integration available. Do not enable indexing.
- Classification remains display-only. Do not add classification-based routing.
- Do not port old commands or cut a release as part of this work.

At the inspected checkout, `packages/dart_notcurses` is independently modified and
`docs/proposals/wasm_hosted_dart2wasm_compiler.md` is untracked. Preserve both;
recheck the worktree before editing and stage only this task's changes.

## Findings and important qualifications

| Finding | Current implementation | Required change |
| --- | --- | --- |
| Hidden 16-step ceiling | `packages/tina_engine_2/lib/src/loop.dart`: `maxStepsPerTurn = 16`, bounded loop, `max-steps … exceeded` | Plugin-owned limit; no implicit ceiling in the loop |
| Hook exceptions silently permit continuation | `_phase`, input-hook loop, and tool-guard loop in the same file catch and continue | Explicit phase-specific failure semantics; guards cannot fail open |
| Feature state in core | `packages/tina_core/lib/src/session_log.dart`: plan, goal, workflow types, JSON dispatch and `deriveSession` cases | Generic plugin-state envelope; plugin-owned types and decoding |
| Duplicate permission-mode ownership | Loop `mode` getter/setter and `SessionSettings.mode`; actual controls use `ToolsPlugin`/`ModeControl` | One authoritative mode owner; remove the loop's feature-specific state |
| Required plugins hardcoded by ID | `packages/tina_tui/lib/src/plugin_settings.dart`: `requiredIds`, `_selection`, `_validate`; `plugin_catalog.dart`: separate base plugins | Requirements derived from capabilities and explicit application requirements |
| Two approval mechanisms | Core `Decision.ask` becomes `ask-unresolved`; active approvals use `ApprovalRequester` and delivery-channel plugins | Async guards returning allow/deny after consulting the approval capability |

The mode finding is narrower than saying the loop currently controls permissions:
`/mode` and Shift-Tab already change `ToolsPlugin.mode`, which updates the sandbox
and process runner. The loop's mode field is a separate state path. Trace both
before removing anything; do not accidentally make the obsolete field authoritative.

The architecture checker currently protects dependency directions, but does not
prevent feature-specific types or policy constants from accumulating in core.
Extend that coverage rather than weakening existing rules.

## Target ownership

| Location | Owns |
| --- | --- |
| `tina_core` | Messages, tools, stream values, structural transcript entries, generic plugin-state envelope and envelope serialization |
| `tina_engine_2` | Turn execution, the single transcript writer, request derivation, ordered hooks, cancellation/termination mechanics, tool/result pairing and structured hook failure reporting |
| `tina_host` | Session lifecycle, registration, capability graph validation, dependency ordering, resource cleanup and generic live reconciliation |
| `packages/plugins/*` | Limits, plans, goals, mode semantics, compaction policy, approvals, persistence, workflow state and other feature behavior |
| `tina_tui` | Application assembly, config scope resolution, terminal mounting and presentation of generic plugin metadata/settings |
| `tina_console` | UI capabilities and settings controls; no policy about which plugins must run |

The single writer and tool/result pairing remain engine responsibilities. A
plugin supplies decisions and data; it must not append directly to SQLite or
mutate historical transcript entries. Compaction scheduling and summarization
remain plugin-owned; validating and recording a history replacement is a
structural engine operation and need not move out merely to reduce line count.

## Work order and reviewable commits

1. Fix hook failures and add cancellation-aware asynchronous policy hooks.
2. Replace the loop ceiling with an optional step-limit plugin.
3. Introduce generic plugin-state entries and backward-compatible loading.
4. Move feature schemas/replay into plugins and remove duplicate mode state.
5. Derive selection constraints from capability metadata.
6. Remove the obsolete `ask` path and finish generic approval integration.
7. Add regression/architecture gates, update documentation, and verify release
   entry-point behavior without cutting a release.

Steps 3–4 should have multiple commits: first add a compatible representation and
reader, then convert consumers, then delete obsolete core types. Keep every
commit buildable. No simultaneous large replacement of hooks, state and loading.

## 1. Hook failures and asynchronous guard execution

Primary files:

- `packages/tina_engine_2/lib/src/{plugin,context,loop,model}.dart`
- `packages/tina_engine_2/test/{engine_2_test,loop_log_test}.dart`
- Host lifecycle tests and approval/input-cancellation tests in `tina_tui`.

### Failure contract

Replace blanket catch-and-continue with a documented phase contract:

| Phase | On unexpected exception |
| --- | --- |
| `onPrompt` | End the turn as an error before a model request; do not send a request with required instructions silently missing |
| `onInput` | Stop the turn before recording the accepted user message or calling the provider; retain the raw input audit entry |
| `beforeModelCall` | Stop before sending that request |
| `beforeToolCall` | Never execute that tool; append an error result, stop further dispatch, and close all already-recorded tool calls with matching error/cancelled results |
| `afterToolResult` | Never retry the already-executed tool; do not silently expose a result whose required transformation failed. Record a conservative error result, stop subsequent dispatch and preserve pairing |
| `onTurnEnd` | The outcome is already committed. Report the plugin failure and continue other cleanup/notification hooks; do not append a second turn-end entry or rerun the turn |

A plugin doing optional observational work can catch its own failures and report
unavailability, as classification already does. Exceptions from enforcement hooks
must not implicitly turn into permission. Do not add a default `ignoreErrors`
setting that recreates the same bug.

Expose a generic diagnostic containing plugin ID, phase and a safe message.
Detailed exceptions/stacks may go to an explicit diagnostic sink; do not inject
arbitrary exception contents into a model prompt or terminal by default. Keep
persistence/listener failures distinguishable from plugin-policy failures: a
broken store must not be treated as a successfully persisted turn.

### Async hooks and cancellation

- Allow `FutureOr<void>` for `beforeModelCall` and `beforeToolCall`, as is already
  done for `onInput`. Existing synchronous overrides should continue to work.
- Execute hooks sequentially in documented order. Await each hook before accepting
  its copied context and before advancing to the next hook.
- Race pending hooks with the turn's cancellation/termination signal. Observe late
  errors and discard late context writes. Do not await a hung hook during shutdown.
- Recheck cancellation/termination immediately after each policy hook and
  immediately before provider/executor invocation.
- Preserve the first non-allow tool decision; later plugins cannot overwrite it.
- Audit the shared cancellation token in `TurnContext.copy()`: it is intentionally
  shared, so dropping a copied context does not roll back cancellation. Correct
  comments claiming that *all* effects of a throwing hook are discarded.
- A copy is only shallow for nested values today. Verify message/tool payload
  immutability; document/enforce the boundary rather than claiming arbitrary
  plugin side effects can be rolled back.

Do not turn every hook into detached background work. Classification owns its
background operation explicitly; enforcement hooks must finish before the action.

### Acceptance tests

Replace the tests that currently assert “throwing guard is ignored; tool runs”
and ignored input/request failures. New tests must prove:

- Throwing input guard: zero provider requests, no accepted user message.
- Throwing request hook: zero requests for the blocked call.
- Throwing tool guard: zero executor invocations, including a delayed throw.
- Two tools in one model response: a failed first guard leaves neither tool
  executed and leaves exactly one result per recorded tool-call ID.
- Post-result failure: external side effect happens once, no automatic retry,
  conservative recorded result, and later tool calls are not dispatched.
- Cancellation during an async hook exits promptly; a late completion cannot
  rewrite input, permit execution or corrupt the next turn.
- Every started turn has exactly one terminal entry, including error paths.
- A completion-hook failure does not prevent other completion hooks/cleanup.

## 2. Plugin-owned step limit

Create `packages/plugins/tina_step_limit`, registered as `tina/step-limit` with a
required description explaining exactly what is counted.

Recommended behavior for this handoff:

- No ceiling when the plugin is absent. Do not keep a hidden fallback of 16.
- Make this plugin opt-in initially; do not silently reintroduce the rejected
  ceiling through the default plugin list.
- `max_steps_per_turn = 0` means unlimited; reject negative/non-integer values.
- A step means one foreground model/tool round. One model response requesting
  three tools consumes one step, not three. Background classification, goal
  judging and compaction calls are not foreground steps.
- Permit exactly N foreground model calls. Execute and record tool calls from the
  Nth response; stop before call N+1. A normal final answer on call N succeeds.
- Reset the counter for each input turn and isolate it per session/panel/subagent.
- Configuration changes take effect on the next turn; do not change a running
  turn's allowance halfway through execution.

The loop may expose a generic model-round index/count in `TurnContext`, but must
not compare it with a configured limit. The plugin checks that count in
`beforeModelCall` and requests a generic policy stop. Alternatively, the plugin
can count its own hook invocations; document ordering and count semantics.

Add a generic stop-request mechanism distinct from an unexpected failure. A
proposed shape is `requestStop(code, detail)` on the context, attributed by the
engine to the invoking plugin; the engine handles termination and pairing. This
mechanism must contain no reference to “steps”, budgets or plugin IDs hardcoded
in core. Keep `cancel()` for user/host cancellation.

Decide the wire representation before implementing it. Preferred: a generic
policy-stop reason plus optional plugin/code/detail fields on the terminal entry.
The reader must still accept existing terminal entries without those fields.
If adding an enum value makes older binaries unable to read new sessions, document
and version that compatibility boundary; do not assume Dart enum additions are
wire-compatible. A deliberately documented mapping onto the old cancellation
reason with optional structured termination metadata is a possible compatibility
alternative. Do not encode the only useful information in a UI-only string.

The plugin owns its config reader and validation. Follow the existing config-path
injection pattern, not a new host `maxSteps` field. A proposed stanza is:

```toml
[plugin_config."tina/step-limit"]
max_steps_per_turn = 0
```

Expose the numeric control through the existing settings contribution interface.
Keep terminal controls in a console adapter if needed; the policy must run
headlessly. Explain zero/unlimited in the UI. Enablement still uses the generic
Plugins checkboxes and scoped overrides. Do not silently copy a workspace setting
into global config. If the numeric value is initially global-only, label that
explicitly rather than implying it follows the enablement scope.

Remove `AgentLoop.maxStepsPerTurn`, its constructor parameter, bounded `for`
condition and `max-steps … exceeded` error. Replace the bounded loop with the
ordinary completion/cancellation/plugin-stop loop.

Acceptance: a finite scripted conversation requiring more than 16 rounds succeeds
without the plugin; exact-N and N+1 boundaries; multiple tools per round; zero,
invalid values, two turns, two panels, load/unload, cancellation and resume. Verify
subagents explicitly: their construction currently selects its own plugin set;
do not assume parent selection or counters are automatically inherited.

## 3. Generic plugin state and storage compatibility

Primary files:

- `packages/tina_core/lib/src/session_log.dart`
- `packages/tina_engine_2/lib/src/loop.dart`: `recordState`, `derive`
- `packages/plugins/tina_persistence/lib/src/{store,legacy_import}.dart`
- `packages/plugins/tina_{plans,goals,workflows}/lib/src/`

Introduce a structural `PluginStateEntry`, for example:

```text
plugin_id: "tina/plans"
state_key: "plan"
schema_version: 1
value: JSON object, or null to clear this key
seq, at: normal transcript envelope fields
```

Contract:

- Core validates the envelope: namespaced identity, valid state key, supported
  envelope structure, integer schema version, JSON-safe immutable payload.
- Core does not know plan-item states, goal verdicts, mode words or workflow nodes.
- Entries represent complete state snapshots for `(plugin_id, state_key)`;
  null is an explicit clear/tombstone. Do not mix snapshot and delta semantics.
- Plugin-owned codecs validate the payload and handle that plugin's versions.
- Unknown plugin IDs and unknown plugin payload versions survive loading,
  appending and re-saving while the plugin is disabled.
- A loaded plugin that cannot decode its state reports an explicit compatibility
  problem. It must not silently replace an unknown future version with defaults.
- Structural transcript kinds remain strictly validated. Supporting opaque plugin
  state does not mean accepting arbitrary unknown core event types.
- The engine remains the only writer. Prefer an owner-bound plugin-state writer
  acquired at mount time, so callers cannot accidentally write another plugin's
  namespace or forge turn/message/compaction entries through `recordState`.
  This is an integrity boundary, not a security sandbox for arbitrary native code.

`DerivedSession` should contain conversation/structural state and, if useful, a
generic map of latest plugin snapshots. Remove typed `plan`, `goal`, `workflowRun`
and permission-mode fields once consumers migrate. Generic latest-snapshot folding
is acceptable; feature interpretation is not.

### Backward-compatible reads are mandatory

Existing SQLite payloads contain `plan_changed`, `goal_changed`, `workflow_run`
and `mode_changed`. `SessionEntry.fromJson` currently knows those cases, and the
store also round-trips entries through this decoder. Do not delete the cases
first and break all existing histories.

Implement a compatibility adapter at the persistence/import boundary:

1. Recognize historical feature events and translate their raw fields into the
   appropriate generic plugin-state envelope, retaining sequence, timestamps,
   order and explicit clearing semantics.
2. Put historical payload migrations in plugin codecs where practical. The
   persistence adapter may recognize old wire names without importing live
   feature plugins, UI code, Attractor or the old engine.
3. Preserve original rows. Prefer read-time normalization and new-format writes;
   avoid rewriting the entire SQLite database just to relocate Dart types.
4. Update the legacy JSONL importer to produce generic state. Its current plan
   and goal parsing directly constructs core feature entries and must be migrated.
5. If a physical database migration is needed, make it transactional, versioned,
   backed up and idempotent. Prove failed migration leaves the source usable.
6. State explicitly that a new binary reads old sessions; an old binary reading
   newly written formats is a separate compatibility question. Do not promise
   rollback readability without testing it.

Test mixed old/new entries, interleaved sessions, repeated imports, cleared
plans/goals, disabled plugins, unknown future plugin payloads, corrupt envelopes,
and original seq/order preservation. Loading a session must never execute a
historical tool call or start a workflow.

Use fixture copies, including previously imported real legacy sessions where
available. Do not modify a user's live session database during validation.

## 4. Feature types, UI projections and mode ownership

Move plan types and approval semantics into `tina_plans`, goal state/verdicts into
`tina_goals`, and workflow state into `tina_workflows`. Migrate their subscribers,
prompt sections, commands and tools to the generic state envelope. Update all
consumers discovered by symbol search, including chat/status rendering and tests;
removing fields from `DerivedSession` alone is insufficient.

The UI should obtain feature data through a plugin contribution or a typed
capability supplied by the owning plugin. Do not replace core coupling with
`if (pluginId == 'tina/plans')` payload decoding in the TUI or console package.
A presentation adapter may depend on its feature package; core and host may not.

Keep `tina_workflows` working for its existing consumers/tests, but leave it out
of the new app's default/catalog wiring. Removing workflow types from core does
not authorize enabling workflows or Attractor.

For permission mode:

- Treat `ToolsPlugin`'s `ModeControl` as the authoritative execution-policy state.
  `tina/mode` is a command adapter; `tina/mode-tui` is a presentation/input adapter.
  Disabling an adapter must not remove enforcement from tools.
- If recording/restoring mode, the tools policy owner writes a generic state key,
  e.g. `tina/tools` / `permission-mode`; both adapters use the same injected control.
- Remove `AgentLoop.mode`, `SessionSettings.mode`, `ModeChangedEntry` from the
  final core API and the feature-specific `deriveSession` case after compatibility
  loading is in place. Keep the unrelated system-prompt setting intact.
- The current live control does not use the loop setter. Do not claim existing
  sessions reliably recorded every live mode change. Define the missing-state
  default explicitly and preserve the current normal/read-only semantics.
- Unknown restored mode values must not silently grant broader permissions;
  surface a migration/configuration problem or use a documented conservative
  fallback. Do not restore temporary approval grants from a mode snapshot.

Acceptance: command and Shift-Tab agree, sandbox and process runner agree, mode
changes produce one state update, resume restores supported recorded state,
missing historical state is handled deliberately, and unloading UI leaves policy
intact. Feature replay must work after disable/re-enable without duplicating state.

## 5. Capability-driven requirements and selection

Primary files:

- `packages/tina_host/lib/src/{plugin_definition,plugin_registry,plugin_manager}.dart`
- `packages/tina_tui/lib/src/{plugin_catalog,plugin_settings,assembly,settings_panel}.dart`

`PluginDefinition` already declares `requires`, `provides`, `live` and
`description`. Extend the typed construction API to support the actual dependency
graph, including multiple dependencies where required. Do not introduce an
ambient service locator accessible to every plugin.

Express dependencies such as:

- approval service → approval delivery channel;
- tools and grok guard → approval requester;
- mode command/view → mode control;
- updater status view → updater status source;
- child-session creation → the capabilities its selected child plugins need.

Distinguish three concepts:

1. **Defaults:** product choices in the application profile/config; allowed here.
2. **Application requirements:** capabilities necessary for a particular app
   profile to operate, e.g. model access. A headless host must not inherit all TUI
   requirements merely because the interactive application needs them.
3. **Dependency constraints:** a selected consumer requires a provider; that
   provider cannot be removed while the consumer remains selected.

Compute a selection result with selected IDs, dependency ordering and structured
blocking reasons. Settings uses this result to show why a checkbox is locked or
why a change is rejected. If two providers satisfy a capability, require explicit
selection; never choose one arbitrarily. Do not silently download/install plugins
or auto-enable a security-relevant capability provider as a side effect of toggling.

Remove duplicate required-ID lists from settings validation and assembly. Catalog
factory declarations and the default plugin list can still contain first-party
IDs; generic validation, state resolution and the loop cannot depend on their
spellings. Bring the separately constructed base plugins into the same selection
model where possible. System instruction should be a selectable default unless a real
consumer declares a requirement; it is not inherently required by the loop.

Preserve explicit `approval_channel` configuration as an application role
selection mapped to the channel capability. Provider construction must respect
dependency order: no resource-opening side effects during validation. Keep the
existing host `providerFactory` boundary usable by headless callers.

Preserve precedence: session > workspace > global > defaults. Keep per-ID
workspace overrides, inherited values, Ctrl-R reset and global replacement lists.
Graph checks must happen before writes/live mutations, including changes masked
by another scope where invalid configuration would otherwise surface next launch.

Preserve restart-only and dependency-rebinding behavior. This task does not require
hot-swapping a provider still referenced by live consumers. Show pending restart
rather than claiming a checkbox changed a running dependency when it did not.

Acceptance: alternate publisher implementations satisfy the same roles; missing,
ambiguous and cyclic dependencies fail before factories/files change; required
reasons update after consumers are disabled; failed attachment cleans its settings,
commands and subscriptions; unrelated plugins remain usable after rollback.

## 6. One approval path

After async hooks exist, remove `DecisionKind.ask` and `Decision.ask`, plus the
`ask-unresolved` loop behavior and tests asserting it. Keep generic allow/deny
(and replacement error results if still needed) as the execution decision.

A policy plugin receives `ApprovalRequester` through constructor capability
injection. It awaits a request and writes allow/deny. The selected delivery plugin
handles terminal, stream or another future transport. The loop receives a final
decision and knows no UI/channel vocabulary.

Do not move all tool-specific approvals to a preflight hook indiscriminately.
Filesystem/process operations may only know the concrete target when executing;
those checks continue to use the same approval capability within the sandbox/tool
implementation. Never execute an operation first merely to discover what needed
approval, and avoid asking twice for the same decision.

Preserve request correlation, expiry, deny-on-cancellation/disconnect, late-response
rejection, and capability lifetime. Pending approvals must close on turn/session
cancellation. The TUI remains a consumer of approval requests, not their source.

Acceptance: the same test policy runs with TUI and stream channels; allow executes
once; deny executes zero times; timeout, lost channel and cancellation deny; late
responses cannot authorize a later action. Retain existing grok Yes/No tests and
sandbox escape/path/process approval tests.

## 7. Gates, tests and completion evidence

Run relevant suites after each commit, then the full affected suites once the
integration is complete:

- `tina_core`, `tina_engine_2`, `tina_host`.
- Step-limit, plans, goals, tools, compaction, approvals, approvals TUI, persistence,
  subagents, chat TUI, and workflow compatibility suites.
- `tina_tui`, classification integration, and remaining legacy callers affected by
  moved types. Classification must remain display-only.
- Root architecture tests and `dart analyze` for every changed package.
- Root suite and `python3 tool/smoke_engine2.py` at 80×10, 80×24 and 120×30.
  Exercise the root `dart run bin/tina.dart`, scoped checkboxes/descriptions,
  prompt/mode changes, approval choices, panels, tool rendering and resume/import.

Existing macOS root updater tests compare temporary paths literally: `/var` versus
`/private/var` can fail despite identical files. A previous passing invocation used
`env -u TYPESAFE_API_KEY TMPDIR=/private/tmp dart test`. Record environmental
adjustments honestly. Unset real classifier credentials for tests using the default
plugin catalog; use local provider/judgment fixtures, not paid production calls.

Extend architecture checks to enforce:

- Engine runtime dependencies remain limited to `tina_core`.
- Core/engine/host contain no plan, goal, workflow or permission-mode schemas.
- No step limit/configuration/error literal remains in the loop.
- Core/host do not import concrete plugin packages or delivery-channel UI.
- Generic plugin selection contains no first-party required-ID switch/list.
- The root executable still cannot reach legacy app/engine, workflows/Attractor
  or repository indexing. The existing display-only classification path remains.

Use targeted source/AST checks alongside behavioral tests, not a broad substring
ban that rejects comments, test fixtures or legitimate generic step counters.
Do not add exceptions to the architecture policy just to make the refactor pass.

Before final push, report:

- Commits and packages changed; exact tests passed and any remaining failures.
- Step-plugin default, counting semantics, config path and settings behavior.
- Which old session formats were loaded and how unknown plugin state survives.
- Any newer-writer/older-reader incompatibility and rollback instructions.
- Confirmation that workflow/Attractor and indexing remain disconnected.
- Confirmation that no release was cut and unrelated work was preserved.

## Definition of done

A headless loop with no policy plugins can complete a finite conversation beyond
16 rounds. Installing the step-limit plugin changes that behavior without changing
the loop. A failed guard cannot execute the guarded action. A new plugin can persist
its state, expose its description/settings and declare dependencies without editing
core or adding an ID-specific branch to selection logic. Existing sessions resume,
existing approvals work through either supported channel, and the current terminal
experience passes its regression checks.
