# A03 — Extract application operations from TUI composition

Status: implemented and validated (2026-09-08).

## Implementation

`lib/application/conversation_operations.dart` provides `ConversationOperations`
with spawn, branch and changeModel operations. Requests contain a captured
`ConversationTarget` (session and source IDs), selected model/profile, explicit
credential override and immutable prompt overrides. Spawn and branch use the
same `CreateConversationRequest`; the method selects history-copy semantics.
The service consumes A01 provider/tool/prompt scopes and A02 runtime settings.
Its host factory is terminal-independent and creates an unattached host. There
is no second session registry: successful operations register in SessionManager.

The coordinator captures targets before opening pickers, reloads prompt and key
settings at the existing boundary, delegates application work, and then attaches
and focuses panels. A focus change during the picker cannot redirect the request.
If the user switches sessions meanwhile, the conversation remains in its captured
session without attaching a panel to the wrong session. The default presenter
uses the existing tree/layout/focus helpers; an optional frontend presenter is
also injectable. Detached hosts receive valid prospective bounds without splitting
the visible layout before creation succeeds.

Spawn/branch retain 512 output tokens, registry-default stream idle timeout,
runtime request timeout and 50 agent steps. Profile tools are pre-approved except
bash, which inherits the configured decision. Safe mode strips the same tools.
Both paths resolve the current main prompt exactly as before. Branching a running
source remains supported: one deep message snapshot is taken at operation entry,
before the first await. That same snapshot seeds persistence and memory. Nested
tool-input structures are copied through the existing message JSON codec.

Lazy primary registration may remint its on-disk conversation ID. Persisted
ancestry now uses the source recorder's ID; frontend tree results retain the
source's stable in-memory ID. Primary registration precedes side-record creation,
and side selection never changes the persisted primary resume anchor.

Model changes preserve the existing immediate-swap rule, including while a turn
is running; this refactor does not introduce a cancel/defer policy. The replacement
is built before touching the current provider. `Conversation.replaceProvider`
synchronizes both conversation and agent references before releasing the old
provider. Cleanup failures are returned to the application caller while the valid
replacement remains installed. Model persistence retains existing best-effort
semantics; non-missing-record failures are exposed in `ModelChanged` and rendered
as a warning. Existing model-label formatting and request tuning are preserved.

`ConversationSelection` separates selection state from host presentation.
SessionManager's selectSession/selectConversation methods return it without
calling hosts; the controller and panel coordinator apply `selection_presenter`
and persist only deliberate primary selections. Legacy switch methods remain
compatibility wrappers. Restore still uses the existing restoration service.

## Failure and ownership policy

- Provider, new metadata, detached host and recorder are acquired before in-memory
  registration. On failure, cleanup releases the host/provider and deletes only
  the newly returned conversation ID. The materialized primary is retained.
- If compensation itself fails, `ConversationOperationFailure` reports the
  original error, cleanup error and allocated ID; other cleanup still runs.
  A store that writes then throws before returning its new ID cannot be reliably
  compensated through the current interface; this operation does not claim a
  transaction or delete records by guessing which one was created.
- The host factory owns partially constructed resources until it returns; after
  successful registration the conversation/session owns the host and provider.
- A failed panel presenter retains the valid registered and persisted conversation.
  The TUI reports its ID for recovery/resume. Terminal attachment is not treated
  as a filesystem transaction. Provider/recorder failure leaves layout unsplit.

## Validation evidence

Application tests use fake providers/hosts and memory storage, without creating a
terminal. Coverage includes target focus/session changes, deep branch snapshots,
running branches and model swaps, provider construction/closure, safe mode,
primary ancestry and resume anchors, failure compensation and selection without
presentation. TUI tests verify the real panel/fork wiring and retain-on-presentation-
failure policy. The transitive dependency test now includes ConversationOperations.
See [HANDOFF.md](HANDOFF.md) for the final command and test count.

## Original problem

[`TuiCoordinator.create`](../../../lib/tui_coordinator.dart) builds terminal
objects and implements application behavior in long closures, notably
`openSpawn`, `openBranch` and `openModelPicker`. Provider construction, policy
selection, history copying and persistence are intertwined with layout changes.
[`SessionManager`](../../../lib/session_manager.dart) already provides useful
conversation factories, but it also drives host presentation during switching.

The extraction should consolidate operations around that existing manager,
rather than introduce a competing session registry.

## Responsibilities

| Application operation | TUI adapter |
| --- | --- |
| Validate target session/conversation and model selection | Open model/profile picker |
| Construct provider, agent, policy and recorder | Construct/attach a conversation surface |
| Snapshot branch history and preserve conversation ancestry | Order tree panels and update labels |
| Register conversation and persist metadata | Choose focus and split layout |
| Replace a conversation's model under an explicit lifecycle rule | Render operation errors and notices |
| Release owned resources on failed construction | Roll back an unsuccessful panel attachment |

## Proposed contracts

Introduce `ConversationOperations` in `lib/application/` before A06. Its public
requests identify targets explicitly rather than consulting mutable active focus
after an asynchronous picker or provider operation.

```dart
abstract interface class ConversationOperations {
  Future<ConversationCreated> spawn(SpawnRequest request);
  Future<ConversationCreated> branch(BranchRequest request);
  Future<ModelChanged> changeModel(ChangeModelRequest request);
}
```

Requests carry session/source IDs, selected model reference, tool profile and
resolved prompt options as needed. They carry no panel, screen, editor, theme or
closure that mutates layout. Results identify the conversation and expose only
the state needed to bind its frontend.

Initially a root-injected host factory can satisfy existing `Conversation.host`
construction. Its contract must remain terminal-independent and its ownership
explicit. A04 narrows presentation coupling further; A03 need not replace every
host interface to extract the operations.

## Operation semantics

### Spawn

Capture the intended session at request creation. Resolve the selected provider
and current prompt settings using existing precedence. Apply the chosen profile
and safe-mode filtering, create a fresh conversation policy, initialize recorder
metadata, then register the conversation. Do not copy another conversation's
history. Preserve existing per-operation request tuning, including any current
spawn-specific output limit, until changed separately.

### Branch

Capture the source conversation ID. Preserve the current supported behavior for
branching during a running turn; characterize it before migration. Define one
snapshot boundary so later source appends cannot alter the branch. Use copied
message structures where mutation is possible, not a shared mutable list.
Preserve stored system prompt, tool-profile behavior, ancestry and recorder
format as currently implemented. The primary persisted resume anchor must not
change merely because the frontend focuses the new side conversation.

### Change model

Build the replacement provider before releasing the old one. Specify the same
busy-conversation rule used today; the operation must enforce it even when called
without a TUI. Persist the same provider/model metadata used by resume. Do not
scatter provider closure and `agent.provider` synchronization across the frontend
and service. Preserve current key/base-URL resolution through the factory.

### Failure and presentation boundaries

A failed provider or recorder construction must not register a half-built
conversation. Clean up resources created for that attempt. Persistence is not
assumed transactional: document the write order and compensate using existing
store capabilities, without deleting unrelated session data.

The TUI should change layout after a successful application result. If panel
attachment fails after registration, retain the valid conversation for retry or
close it through the normal operation; choose and test one policy in the PR.
Do not pretend that a terminal allocation and filesystem write form a transaction.

## Migration steps

1. Extract provider/profile/prompt decisions into the service using A01 factories.
2. Move spawn; retain the picker and panel attachment in the TUI closure.
3. Move branch using the same construction path plus an explicit history snapshot.
4. Move model changes and consolidate provider ownership.
5. Make session switching emit/return selection state; let the frontend adapter
   apply `setActive`, activity restoration and layout behavior.
6. Delegate resume to the existing restoration service rather than duplicate it.
7. Move eligible assertions from TUI tests into operation tests. Keep wiring and
   panel-order integration tests intact.

## Test matrix and acceptance

| Scenario | Required assertion |
| --- | --- |
| Picker changes focus before completing | Request targets the deliberately captured session/source |
| Branch then append to source | Branch history does not change |
| Spawn with safe mode | Same disabled tools as main/delegated agents |
| Provider construction failure | No registered conversation; old provider remains usable |
| Model replacement success/failure | Provider closure and persisted metadata follow documented ownership |
| Focus side panel, restart | Primary resume anchor remains unchanged |
| Recorder failure | Owned resources released; store consistency policy is observable |

Operation tests use fake providers, memory session storage and fake sinks; they
must not create a terminal or call `TuiCoordinator.create`. Existing TUI tests
continue to verify picker cancellation, split/focus ordering, labels and busy
cues. Completion is measured by responsibility removal, not a line-count target.
