# Session Persistence as a Plugin

**Status:** Proposal (rewritten 2026-09-22; original draft was written against an
assumed codebase and has been replaced)
**Depends on:** the plugin runtime in `packages/tina_engine/lib/src/runtime/`
(`PluginDescriptor`, `PluginContext`, `PluginScope`, `ServiceKey`) as it exists
today, and on `docs/proposals/plugin_runtime.md` for direction

## Introduction

Session persistence is currently hardwired: `bin/tina.dart` constructs
`JsonlSessionStore.defaultLocation()` directly and hands it to
`buildAppComposition`. This proposal migrates that seam onto the existing plugin
runtime so alternative backends (SQLite, cloud, encrypted) can be contributed as
plugins without touching the composition root, while the JSONL file store
remains the default with unchanged behavior.

### Assumptions — verified against the tree on 2026-09-22

| Assumption | Verdict |
|---|---|
| Plugin runtime is real and usable | **Yes** — `runtime/plugin.dart`: descriptors declare `requires`/`provides`, factories get a `PluginContext` with `require`/`own`/`register`/`child`; `PluginScope.provide`/`lookup` (with parent fallback) is the service mechanism. Already proven by `tools/workspace_tool_plugins.dart`. |
| `SessionStore` is contract-ready | **Yes** — `persistence/session_store.dart:350`. Plain Dart types, narrow REPL-level surface, two-level keys `(sessionId, conversationId)`. Explicitly designed for "nested files, SQLite, a remote service, etc." |
| A separate `SessionRegistry` class is needed | **No** — the draft's registry duplicates `PluginScope` service resolution (registration, lookup, active-provider selection via which binding exists). This proposal uses a `ServiceKey<SessionStore>` instead. |
| `SessionRecorder` exists to refactor | **No such class.** Persistence flows through `AppComposition.store` → `SessionController.sessionStore` (`lib/session_controller.dart`). The rewrite targets that wiring. |
| Wrapping `JsonlSessionStore` preserves compatibility | **Yes** — `defaultLocation()`, `directoryFor()`, and the on-disk format stay untouched; the plugin only changes *who constructs* the store. |

## 1. Goal

1. The active `SessionStore` is resolved through the plugin runtime's service
   scope, not constructed inline.
2. `JsonlSessionStore` becomes the default *plugin* (id
   `tina.engine.session-store-jsonl`), behavior-identical.
3. A config surface selects among registered backends.
4. Zero change for existing users: same default, same file layout, same resume /
   `--continue` / `--list` behavior.

## 2. What exists today (the seams this builds on)

- `bin/tina.dart:193` — `final sessionStore = JsonlSessionStore.defaultLocation();`
  then `buildAppComposition(store: sessionStore, ownsStore: true, ...)`.
- `bin/tina.dart:804` (`--list`) — constructs its own store, deliberately
  lightweight ("no provider or TUI").
- `packages/tina_app/lib/src/composition/app_composition.dart:223` —
  `store ?? JsonlSessionStore.defaultLocation()` fallback; `AppComposition.store`
  is the field everything downstream reads (`SessionController`, session
  commands, attach/detach).
- `bin/tina.dart:362` (`_acquireSessionLock`) — `if (store is! JsonlSessionStore)
  return;` then `SessionLock(store.directoryFor(sid))`. Advisory locking is a
  Jsonl-specific capability today.
- Startup reads happen **before** any plugin runs: the resume picker,
  `resumeCwdFor` / `_restoreSessionCwd`, and `--list` all touch the store prior
  to `buildAppComposition`.

That last point is the central constraint the original draft missed: the store
is needed *pre-runtime*, so plugin-scoped resolution alone cannot serve the
early paths.

## 3. Design

### 3.1 The service key (replaces the draft's `SessionRegistry`)

`packages/tina_engine/lib/src/persistence/session_store.dart` (or a sibling):

```dart
/// Service key under which the active session store is resolved.
final ServiceKey<SessionStore> sessionStoreServiceKey =
    ServiceKey<SessionStore>('tina.engine.session_store');
```

Registration, uniqueness, replacement, and teardown semantics come from
`PluginScope` — the runtime already enforces everything the draft's registry
re-implemented by hand (double-registration errors, active-instance selection,
dispose ordering).

### 3.2 The default JSONL plugin

`packages/tina_engine/lib/src/persistence/jsonl_session_plugin.dart`:

```dart
PluginDescriptor jsonlSessionStorePlugin({Directory? root}) => PluginDescriptor(
      id: 'tina.engine.session-store-jsonl',
      provides: [sessionStoreServiceKey],
      factory: FnPluginFactory((context) {
        final store = JsonlSessionStore(root ?? defaultRoot());
        context.own(store.close);
        return store;
      }),
    );
```

(`defaultRoot()` factors the existing `defaultLocation()` path logic so the
plugin and the legacy constructor cannot drift.)

### 3.3 Startup ordering — provider selection before the runtime exists

Split the store's early duties from its app duties:

- **Early, read-only index operations** (`listSessions`, `resumeCwdFor`): add a
  narrow `SessionIndex` interface (list + metadata read) that
  `JsonlSessionStore` already satisfies structurally. `--list`, the picker, and
  cwd restore depend on `SessionIndex`, resolved by a plain synchronous
  `resolveSessionIndex(RuntimeConfig)` that reads the `[sessions]` table (§4)
  and defaults to the JSONL location. No plugin runtime needed at this stage.
- **The active store**: resolved when the runtime activates, via
  `scope.lookup(sessionStoreServiceKey)`. `buildAppComposition` keeps its
  `store:` override (tests and `bin/tina.dart`'s early-constructed instance —
  see SP2 for how the pre-built store is *provided* into the scope rather
  than bypassed).

### 3.4 Locking capability

`_acquireSessionLock`'s `is! JsonlSessionStore` check becomes a capability
probe instead of a type test:

```dart
abstract interface class LockableSessionStore implements SessionStore {
  /// Directory (or backend namespace) advisory locks are taken in.
  String lockNamespaceFor(String sessionId);
}
```

`JsonlSessionStore` implements it via `directoryFor(sid)`. Non-lockable
backends keep today's behavior (skip locking) but now *declare* it.

## 4. Configuration

```toml
[sessions]
provider = "jsonl"        # default; must match a registered backend id suffix

[sessions.jsonl]
# root = "/custom/path"   # optional; defaults to today's location
```

Wired through the existing `RuntimeConfig` (decoded where other config blocks
are), consumed by `resolveSessionIndex` (§3.3) and by the composition root when
it decides which session plugin to include in the runtime's plugin list. No
`[plugins.*]` generic surface exists yet; when `plugin_runtime.md` lands one,
`[sessions]` remains the selection surface and `[plugins.<id>]` the
per-plugin config — matching the split the runtime plan already describes
(`PluginConfigDecoder` per descriptor).

## 5. Migration path

Split into independently landable phase specifications in
[`session-persistence/`](session-persistence/):

| ID | Phase | Prerequisites |
| --- | --- | --- |
| [SP1](session-persistence/01-service-key-and-jsonl-plugin.md) | Service key + JSONL plugin | None |
| [SP2](session-persistence/02-session-index.md) | Session index for startup | SP1 |
| [SP3](session-persistence/03-provider-selection.md) | Provider selection config | SP1; benefits from SP2 |
| [SP4](session-persistence/04-lockable-store.md) | Lockable store capability | SP1 |
| [SP5](session-persistence/05-example-backend-and-docs.md) | Example backend + docs | SP1 for the backend; SP1–SP4 for docs |

Each phase lands green independently; nothing is feature-flagged.

### Backward compatibility

- Default provider registered automatically; `[sessions]` absent ⇒ identical
  behavior and paths.
- On-disk format, `.tina` conventions, resume ids: untouched.
- `--list` stays lightweight (index-only, no runtime).

## 6. Testing

- Unit: scope resolution selects the jsonl binding; double-registration errors;
  teardown closes the store exactly once (`context.own` semantics).
- Integration: picker / `--resume` / `--continue` / `--list` against
  `SessionIndex`; lock acquisition via `LockableSessionStore`.
- Golden: session file bytes before/after SP1 must be identical for the
  same scripted conversation.
- Contract suite: run the existing persistence tests against the in-memory
  backend to prove the `SessionStore` contract is backend-neutral.

## 7. Error handling

Store failures already surface through `SessionController` and the session
commands; this proposal adds one rule: provider *selection* failures (unknown
id in `[sessions]`) fail fast at startup with the offending id named, before
any session is created — never mid-session.

## 8. Open questions

1. Should `SessionIndex` also cover `createSession` (needed before the runtime
   starts for caller-minted ids), or does session creation move after runtime
   activation?
2. Cloud backends need async construction; `PluginFactory.build` is sync.
   Options: plugin resolves a Future-bearing service, or factories get async
   build in the runtime first (belongs in `plugin_runtime.md`, not here).
3. Does attach/detach (`docs/features/session_attach_detach.md`) read the
   store through `AppComposition.store` only, or does it have its own
   construction paths to migrate too?

## 9. Acceptance criteria

- [ ] `sessionStoreServiceKey` resolves the active store from plugin scope
- [ ] JSONL backend is a registered plugin; composition root no longer
      constructs `JsonlSessionStore` inline (except the explicit early-path
      index, or a provided pre-built instance)
- [ ] `[sessions] provider` selection documented; unknown id fails at startup
- [ ] Locking decided by `LockableSessionStore`, not a Jsonl type test
- [ ] Golden: identical session files for identical conversations (pre/post)
- [ ] One non-file backend (in-memory, test-only) passes the persistence
      contract suite
- [ ] `docs/features/session_persistence.md` updated
