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
PluginDescriptor jsonlSessionStorePlugin({Directory? root}) =>
    PluginDescriptor(
      id: 'tina.engine.session-store-jsonl',
      provides: [sessionStoreServiceKey],
      factory: FnPluginFactory((context) {
        final store = JsonlSessionStore(root ?? JsonlSessionStore.defaultSessionRoot());
        context.own(store.close);
        return store;
      }),
    );
