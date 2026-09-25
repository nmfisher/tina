import 'dart:io';

import 'jsonl_session_store.dart';
import 'session_store.dart';
import '../runtime/plugin.dart';

/// Service key under which the active session store is resolved. The
/// composition that owns sessions binds the default JSONL store (or an
/// alternative backend) here; consumers resolve it from plugin scope.
final ServiceKey<SessionStore> sessionStoreServiceKey =
    ServiceKey<SessionStore>('tina.engine.session_store');

/// The default file-backed session store as a plugin: binds the active
/// [SessionStore] under [sessionStoreServiceKey] at the default location
/// (or [root] when given, e.g. from config).
///
/// Mounted by the session-owning composition — NOT by
/// [defaultExecutionPlugins]-style profiles, which also serve compositions
/// that own no sessions (summary runs): those would get an unused store.
/// Session-less compositions simply leave the key unbound.
PluginDescriptor jsonlSessionStorePlugin({Directory? root}) => PluginDescriptor(
      id: 'tina.engine.session-store-jsonl',
      provides: [sessionStoreServiceKey],
      factory: FnPluginFactory((context) {
        final store =
            JsonlSessionStore(root ?? JsonlSessionStore.defaultSessionRoot());
        context.own(store.close);
        return store;
      }),
    );

/// Session-store backend ids selectable via `[sessions] provider` (SP3).
/// The plugin id for each is `tina.engine.session-store-<id>`.
const List<String> sessionStoreProviderIds = ['jsonl'];

/// The store plugin for a `[sessions] provider` id (SP3 selection).
///
/// Fails fast on an unknown id — before any session is created — because a
/// typo'd provider must surface at startup, not mid-session. The error is a
/// [FormatException] so config-parsing call sites exit through their normal
/// `on FormatException` path.
PluginDescriptor sessionStorePluginFor(String provider, {Directory? root}) {
  if (!sessionStoreProviderIds.contains(provider)) {
    throw FormatException('Unknown [sessions] provider "$provider". '
        'Known providers: ${sessionStoreProviderIds.join(', ')}.');
  }
  return switch (provider) {
    'jsonl' => jsonlSessionStorePlugin(root: root),
    _ => throw StateError('unreachable: validated above'),
  };
}
