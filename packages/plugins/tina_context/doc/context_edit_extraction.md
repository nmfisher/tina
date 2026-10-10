# Context edit pipeline: survey + design (refactor 1)

Status: scratch doc. The extracted function's contract, pinned before moving code.

## A. Callers (complete map)

Production:
- `ContextFileMirror.synchronize(current, replace)` — called once per `beforeModelCall`
  when a mirror exists. Its `replace` callback is `ContextPlugin.replaceWorkingContext`
  (wrapped to convert `ContextEditRejected` → `FormatException`).
- `ContextPlugin.replaceWorkingContext({expectedRevision, expectedThroughSeq, messages})`
  — called by the mirror callback and directly by tests/embedders.

Tests: 15 calls to `replaceWorkingContext` in `working_context_test.dart`;
11 tests in `context_file_mirror_test.dart`; external consumers import only
`ContextPlugin`, `ContextEditStatus`, `lastReceipt` (tina_tui/context_plugin_test.dart).
No external references to `ContextEditRejected`/`ContextPersistenceFailure`.

## B. Rule inventory with exact firing order

The mirror and plugin checks interleave; the combined order when a file edit is
synced at a model-call boundary is:

| # | Rule | Where today | Error type / string |
|---|------|-------------|---------------------|
| 1 | Mirror initialized | mirror | `StateError('Context mirror is not initialized')` |
| 2 | schema_version==1, revision==base.revision, through_seq==base.throughSeq | mirror | `FormatException('File version or counters changed')` |
| 3 | file read/decode/shape | mirror | FormatException 'Context file is missing or unreadable' / 'Invalid context file structure' / 'Invalid context message' |
| 4 | edited vs base unchanged → no-op | mirror | (receipt `unchanged`) |
| 5 | current vs base: revision equal, throughSeq ≥, prefix preserved | mirror | FormatException 'Stale context file' |
| 6 | merged = edited + current-beyond-base (append rebase) | mirror | — |
| 7 | pairing/structure of merged (`validateContextMessages`) | mirror | FormatException (per-message rules) |
| 8 | plugin counter check: current.revision==expected, current.throughSeq==expected | plugin | `ContextEditRejected('Stale working-context edit')` |
| 9 | freeze + validate replacement (`validateContextMessages`) | plugin | FormatException (structural) |
| 10 | signed-reasoning integrity: every signed block in replacement matches original text+complete by signature | plugin | `FormatException('Signed reasoning must remain intact')` |
| 11 | in-turn: current request preserved (turnMessages.first present in replacement) | plugin | `ContextEditRejected('The current user request must remain intact')` |
| 12 | in-turn: outstanding tool calls settled | plugin | `ContextEditRejected('The executing tool batch must settle first')` |
| 13 | snapshot counters (revision ≥1, throughSeq ≥ -1) | snapshot ctor | FormatException 'Invalid working-context counters' |
| 14 | append `PluginStateEntry` via `_write!` | plugin | `ContextPersistenceFailure` (sets `_writeFailed`) |

The mirror collapses rules 2,3,5,7,8..12 rejections into ONE receipt:
'Context edit rejected: invalid, stale, or protected content. The current working
context was restored to the file.' Persistence failures (14) propagate instead.

## C. Design: `evaluateContextEdit`

New file `lib/src/context_edit.dart`, pure (no File, no loop, no writes):

```dart
sealed class ContextEditVerdict { const ContextEditVerdict(); }
final class ContextEditAccepted extends ContextEditVerdict {
  const ContextEditAccepted(this.merged);      // frozen message list to adopt
}
final class ContextEditRejected_ { ... }       // see D: reason taxonomy
```

Signature:

```dart
ContextEditVerdict evaluateContextEdit({
  required WorkingContext current,   // state right now
  required List<Message> edited,     // the proposal
  List<Message>? base,               // exported base for the append rebase;
                                     // null → direct replacement path
  ActiveTurnContext? activeTurn,     // null → between turns
});

final class ActiveTurnContext {
  const ActiveTurnContext({required this.turnId, required this.messages});
  final String turnId;             // loop.derive().pendingTurnId
  final List<Message> messages;    // turnMessages from the log
}
```

Evaluation order (preserves B's order exactly):

1. counters: `current.revision != expected` style checks are the CALLER's job —
   `evaluateContextEdit` takes `current` as ground truth. The stale-vs-base rule (5)
   applies only when `base != null`.
2. if base != null: edited-unchanged→ `ContextEditUnchanged` verdict (new third state;
   mirror needs it for its receipt). Stale-base → rejected reason stale.
3. merge: `edited + current.messages.skip(base.length)` when base != null.
4. freeze + `validateContextMessages(merged)` → structural reason.
5. signed-reasoning integrity → protected reason.
6. activeTurn != null: request preservation → protected reason; settled-batch →
   protected reason.
7. else accept with merged list.

## D. Reason taxonomy (resolves the mirror's collapsed receipt)

`ContextEditRejected_` is NOT reintroduced. Keep the thrown types callers use today,
but make the reason inspectable without breaking the receipt text:

```dart
enum ContextEditReason { stale, structural, protected, unchanged? }
```

Decision: verdicts are `accepted(merged)`, `rejected(ContextEditProblem)` where

```dart
final class ContextEditProblem {
  const ContextEditProblem(this.kind, this.message);
  final ContextEditProblemKind kind;  // stale | structural | protected
  final String message;               // EXACT current message strings
}
```

Caller mapping (both callers rethrow, preserving today's types+strings):
- mirror `synchronize`: any rejected verdict → the single collapsed receipt
  (unchanged text), because the model-facing receipt is deliberately generic.
- plugin `replaceWorkingContext`: `ContextEditRejected(problem.message)` when
  kind == stale|protected; `FormatException(problem.message)` when kind == structural
  (and signed-reasoning keeps FormatException, as today).
- `beforeModelCall`'s replace wrapper: unchanged behavior (Rejected→FormatException).

The dry-run future (context://live) reads `kind` + `message` directly.

## E. What stays where

- `synchronize` keeps: file read/parse, unchanged-detection (vs published text),
  receipt construction, `_publish`, rethrow of persistence errors from `replace`.
- `replaceWorkingContext` keeps: `_mounted`/`workingContext` reads, loop-state reads
  (inTurn, pendingTurnId, turn messages), `_write!` + `_writeFailed` guard,
  revision+1 snapshot construction, persistence failure wrapping.
- Neither caller validates anything the function also validates.
