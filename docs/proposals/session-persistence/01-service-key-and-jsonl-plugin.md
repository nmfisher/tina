# SP1 — Service key + JSONL plugin

Status: proposed.
Prerequisites: none.
Index: [README.md](README.md).

## Problem

`bin/tina.dart` and `buildAppComposition` construct `JsonlSessionStore`
directly, so there is no seam where an alternative backend could be supplied.
Every later phase resolves the store through this phase's mechanism.

## Implementation

Add the service key in `packages/tina_engine/lib/src/persistence/`
(`session_store.dart` or a sibling):

```dart
/// Service key under which the active session store is resolved.
final ServiceKey<SessionStore> sessionStoreServiceKey =
    ServiceKey<SessionStore>('tina.engine.session_store');
```

Add the default plugin, `jsonl_session_plugin.dart` in the same directory:

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

Factor the path logic of `JsonlSessionStore.defaultLocation()` into
`defaultRoot()` so the plugin and the legacy constructor cannot drift.

Register the plugin in the default plugin list
(`defaultExecutionPlugins` in
`packages/tina_app/lib/src/composition/execution_profile.dart`). The runtime
must activate before `AppComposition.store` is wired, so composition reads the
store from `runtime.scope.lookup(sessionStoreServiceKey)`, falling back to
today's inline construction while later phases land. The explicit `store:`
override to `buildAppComposition` stays — tests and `bin/tina.dart`'s
early-constructed instance (see SP2) depend on it.

**Landed 2026-09-22 — design correction discovered during implementation:**
the plugin does NOT go into `defaultExecutionPlugins`. That profile is also
mounted by `buildSummaryIndex` → `buildExecutionRuntime` (summary runs that
own no sessions); mounting the session plugin there would build an unused
store in every summary run. The plugin is appended by
`buildAppComposition` itself through the existing `plugins:` extension seam
(the same mechanism the git/intent input plugins use) — but only when no
`store:` override is injected. `SessionRecorder` (see the corrected assumption
audit) needed no changes: it already takes any `SessionStore`.

There is no separate `SessionRegistry` class: `PluginScope` already enforces
registration uniqueness, replacement, and teardown ordering. Selection among
backends is SP3's config concern, not a runtime data structure.

## Migration

1. Add the key and plugin; register in `defaultExecutionPlugins`.
2. Switch `AppComposition.store` population to the scope lookup (fallback to
   inline construction when the override is absent or the scope lacks the
   binding).
3. No call-site changes anywhere else — everything already reads
   `AppComposition.store`.

## Validation

- Scope resolution selects the jsonl binding; double-registration of the key
  errors as the runtime specifies.
- Teardown closes the store exactly once (`context.own` semantics).
- Golden: session file bytes are identical before/after for the same scripted
  conversation.
- Attach/detach (`docs/features/session_attach_detach.md`) is verified to read
  only `AppComposition.store` — if it constructs its own store anywhere, that
  path is migrated here, not deferred.
