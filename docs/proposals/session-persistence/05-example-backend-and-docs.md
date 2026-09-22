# SP5 — Example backend + docs

Status: proposed.
Prerequisites: SP1 only, for the backend itself; SP1–SP4 for the docs.
Index: [README.md](README.md).

## Problem

The program claims the `SessionStore` contract is backend-neutral, but every
proof is JSONL-only. A second backend exercising the full contract is the
regression net for the whole program — and the acceptance criterion the
umbrella proposal lists ("One non-file backend … passes the persistence
contract suite").

## Implementation

An in-memory `SessionStore` under `packages/tina_engine/test/` (test-only; it
is a fixture, not a shipped backend):

```dart
class InMemorySessionStore implements SessionStore {
  // createSession / createConversationWithMeta / append / replace /
  // getMessages / flush / close — record ordering, absent-session and
  // absent-conversation errors, coalescing behavior.
}
```

It must follow the documented contract precisely, including:

- `createSession(providerId:, baseUrl:, cwd:, sessionId:)` with caller-minted
  ids honored (and the returned id corrected when the implementation cannot
  honor one),
- `createConversationWithMeta` writing `ConversationMeta`,
- `append` creating the conversation if necessary,
- `replace` atomicity semantics as the JSONL store implements them,
- `StateError` on unknown session/conversation, per the doc comments,
- a no-op `close()`.

The existing persistence tests
(`packages/tina_engine/test/persistence/jsonl_session_store_test.dart`) gain
a variant run against the in-memory store: same groups, same expectations,
different backend. The variant lives in the same file or a sibling —
whichever keeps duplication lowest.

## Migration

1. Add the in-memory store and the contract-suite variant.
2. Verify the suite exposes no JSONL-specific assumptions (expectations about
   file layout, paths). If it does, factor those into backend-specific tests
   and keep the shared suite backend-neutral.
3. Update `docs/features/session_persistence.md`: the service key, the jsonl
   plugin, `[sessions]` selection (SP3), and the `LockableSessionStore`
   capability (SP4) — the acceptance list in the umbrella proposal §9.

## Validation

- The contract suite passes against the in-memory store.

## Note

`PluginFactory.build` is synchronous. The in-memory backend is synchronous
and unaffected. Cloud backends needing async construction are the plugin
runtime program's concern — open question in the umbrella proposal §8.
