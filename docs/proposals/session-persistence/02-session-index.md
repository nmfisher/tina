# SP2 — Session index for startup

Status: implemented (see "Landed" below for deltas from this plan).
Prerequisites: SP1.
Index: [README.md](README.md).

## Problem

Startup reads the store before the plugin runtime activates: the resume
picker (`pickStartupSession`), `resumeCwdFor` / `_restoreSessionCwd`, and
`--list` (`bin/tina.dart`). Scope resolution from SP1 cannot serve these
paths without booting a runtime just to list sessions — and `--list` is
deliberately lightweight.

## Implementation

Extract a narrow read-only interface the JSONL store already satisfies
structurally:

```dart
/// Read-only startup view of saved sessions.
abstract interface class SessionIndex {
  /// List sessions with metadata, most-recently-updated first.
  Future<List<SessionMeta>> listSessions();

  /// Recorded working directory for [sessionId], if any.
  Future<String?> cwdFor(String sessionId);
}
```

`resumeCwdFor` (in `packages/tina_app/lib/src/persistence/session_restore.dart`)
remains the full-store read used inside `resolveSession`'s resume path; the
index's `cwdFor` covers the launcher's pre-runtime read with identical
semantics (null for unknown sessions and sessions without a recorded cwd).

`JsonlSessionStore implements SessionIndex` directly. For other existing
stores, a zero-cost view bridges them without a new construction path:

```dart
class SessionIndexStore implements SessionIndex {
  SessionIndexStore(this._store);
  final SessionStore _store;
  // listSessions delegates; cwdFor prefers the jsonl manifest-only read and
  // falls back to loadSession (StateError → null).
}
```

`resolveSessionIndex()` (SP3 lands the config read; until then a constant
default) returns the JSONL index at the default location.

## Migration rule

No second construction path. `--list` stays lightweight: index-only, no
runtime, no provider. Code needing the full store before activation provides
a pre-built instance into the scope (SP1's `store:` override), never through
the index.

## Migration

1. Define `SessionIndex` (+ the `SessionIndexStore` bridge) in
   `packages/tina_engine/lib/src/persistence/session_index.dart`.
2. `JsonlSessionStore` implements `SessionIndex` directly, with a
   manifest-only `cwdFor` that never triggers the legacy-flat
   materialization (a write): legacy sessions recorded no cwd, so null is
   correct for them too.
3. The launcher (`bin/tina.dart`) resolves the index for the picker, the
   cwd restore, and `--list`; the full store is now built exclusively by
   the composition (SP1 plugin) — `buildAppComposition(store:)` is no
   longer passed a launcher-built instance, and the launcher no longer
   closes a store it doesn't own.
4. `resolveSessionIndex()` returns the JSONL index (constant default until
   SP3's config read lands).

## Validation

- `--list`, picker, and cwd restore work unchanged against the index
  (verified: `dart run bin/tina.dart --list` after migration).
- `--list` constructs nothing beyond the index (no provider, no TUI).
- `resolveSessionIndex` with no config returns the JSONL index at the
  default location.
- Engine tests: `test/persistence/session_index_test.dart` — direct
  implementation, listSessions/cwdFor contracts, the no-write guarantee
  for legacy sessions, the bridge fallback, and the resolver.

## Landed deltas from this plan

- The metadata type is `SessionMeta` (the store's existing type), not
  `SessionSummary` as drafted.
- The bridge is a plain class, not an extension type: extension types
  cannot `implements` an interface unrelated to their representation type.
- `cwdFor` lives on `JsonlSessionStore` itself so the bridge (and any
  direct use) gets the manifest-only read, which never materializes legacy
  flat sessions — loadSession's `_ensureMaterialized` would have been a
  startup write.
- The engine's SDK floor moved `^3.0.0` → `^3.3.0` (extension types were
  drafted; kept for the bump's honesty even though the bridge became a
  class — the interface keyword needs 3.0+, and the code uses
  `interface class` semantics available from 3.0; kept 3.3 to leave headroom
  for SP5's planned `extension type` usage).

## Status

Implemented in commit (SP2): `session_index.dart`,
`jsonl_session_store.dart` (`implements SessionIndex`, manifest-only
`cwdFor`), `bin/tina.dart` (index in the picker/cwd-restore/`--list`
paths; store now plugin-built only), barrel export, and
`test/persistence/session_index_test.dart`.
