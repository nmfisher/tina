# SP2 — Session index for startup

Status: proposed.
Prerequisites: SP1.
Index: [README.md](README.md).

## Problem

Startup reads the store before the plugin runtime activates: the resume
picker (`pickStartupSession`), `resumeCwdFor` / `_restoreSessionCwd`, and
`--list` (`bin/tina.dart:804`). Scope resolution from SP1 cannot serve these
paths without booting a runtime just to list sessions — and `--list` is
deliberately lightweight.

## Implementation

Extract a narrow read-only interface the JSONL store already satisfies
structurally:

```dart
/// Read-only startup view of saved sessions.
abstract interface class SessionIndex {
  /// List sessions with metadata, newest first (or store-defined order).
  Future<List<SessionSummary>> listSessions();

  /// Recorded working directory for [sessionId], if any.
  Future<String?> cwdFor(String sessionId);
}
```

`resumeCwdFor` is currently a top-level helper in `bin/tina.dart`; it moves
behind the interface (keep the top-level function during migration, or move
it wholesale — one or the other, noted when landing).

`JsonlSessionStore` implements `SessionIndex` directly. For other existing
stores, a zero-cost view bridges them without a new construction path:

```dart
extension type SessionIndexStore(SessionStore store) implements SessionIndex {
  @override
  Future<List<SessionSummary>> listSessions() => store.listSessions();
  @override
  Future<String?> cwdFor(String sessionId) =>
      resumeCwdFor(store, sessionId);
}
```

`resolveSessionIndex(RuntimeConfig)` (SP3 lands the config read; until then a
constant default) returns the JSONL index at the default location.

## Migration rule

No second construction path. `--list` stays lightweight: index-only, no
runtime, no provider. Code needing the full store before activation provides
a pre-built instance into the scope (SP1's `store:` override), never through
the index.

## Migration

1. Define `SessionIndex` (+ the `SessionIndexStore` extension type) in
   `packages/tina_engine/lib/src/persistence/`.
2. `JsonlSessionStore` implements `SessionIndex` directly.
3. Take `SessionIndex` params in `_restoreSessionCwd` and the picker
   plumbing; `--list` (`_listSessions`) likewise.
4. `resolveSessionIndex` returns the JSONL index (constant default until
   SP3's config read lands).

## Validation

- `--list`, picker, and cwd restore work unchanged against the index.
- `--list` constructs nothing beyond the index (no provider, no TUI).
- `resolveSessionIndex` with no config returns the JSONL index at the default
  location.
