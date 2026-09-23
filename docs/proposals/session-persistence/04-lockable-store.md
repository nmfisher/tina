# SP4 — Lockable store capability

Status: implemented (see "Landed" below).
Prerequisites: SP1.
Index: [README.md](README.md).

## Problem

`bin/tina.dart:362` (`_acquireSessionLock`) decides whether advisory locking
applies with `if (store is! JsonlSessionStore) return;` then
`SessionLock(store.directoryFor(sid))`. A type test hardcodes one backend; a
second backend would silently skip locking (today's behavior for non-file
backends) with no way to declare intent.

## Implementation

```dart
/// Backends that support advisory cross-process locking.
abstract interface class LockableSessionStore implements SessionStore {
  /// Directory (or backend namespace) in which to take the lock.
  String lockNamespaceFor(String sessionId);
}
```

`JsonlSessionStore` implements this directly, via the `directoryFor` it
already exposes:

```dart
@override
String lockNamespaceFor(String sessionId) => directoryFor(sessionId);
```

`_acquireSessionLock` becomes:

```dart
if (store is LockableSessionStore) {
  final lock = SessionLock(store.lockNamespaceFor(sid));
  ...
}
```

`SessionLock` itself is backend-neutral: it takes a namespace string, so
non-file backends with their own lock directories can declare the capability
too.

## Migration

1. Add `LockableSessionStore` in
   `packages/tina_engine/lib/src/persistence/session_store.dart` (or a
   sibling).
2. `JsonlSessionStore` implements it via `directoryFor`.
3. Replace the type test in `_acquireSessionLock` in `bin/tina.dart`.
4. Keep `directoryFor` public: it is the lock namespace source and SP2's
   index may read it.

## Validation

- Resume/continue on the same session from two processes: the second
  acquisition fails with the existing conflict message
  (`conflict.toMessage()`).
- A store that is `SessionStore` but not `LockableSessionStore` skips locking
  exactly as non-Jsonl stores do today.
- `--force-lock` behavior unchanged.

## Landed

Implemented in commit (SP4):

- `LockableSessionStore` in
  `packages/tina_engine/lib/src/persistence/session_store.dart` (a sibling
  of [SessionStore], as the migration allowed), barrel-exported.
- `JsonlSessionStore` implements it:
  `lockNamespaceFor(sid) => directoryFor(sid).path` (`directoryFor` stays
  public — lock namespace source).
- `SessionLock.forNamespace(String)` constructor: the lock contract needs a
  path-like string, not a `Directory`, so non-file backends can declare a
  namespace without a real directory object. `SessionLock(Directory)` is
  unchanged.
- `bin/tina.dart` `_acquireSessionLock`: `store is! LockableSessionStore`
  early-return replaces the Jsonl type test.
- Tests: `packages/tina_engine/test/persistence/lockable_store_test.dart` —
  capability declared, namespace = session directory path,
  `SessionLock.forNamespace` two-acquisition conflict via
  `conflict.toMessage()`, and a plain `SessionStore` that does not satisfy
  the capability. Launcher smoke-tested: live-pid lock conflict message and
  `--force` takeover both behave as before.
