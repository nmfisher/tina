import 'dart:convert';

import 'package:tina_engine_2/tina_engine_2.dart';

import 'store.dart';

typedef SessionStoreOpener = SessionStore Function();

/// Owns the session store and its log subscription. The application assembly
/// supplies an opener for the chosen location, including :memory: in tests.
final class PersistencePlugin extends AgentPlugin {
  PersistencePlugin({required this.openStore});

  @override
  String get id => 'tina/persistence';

  @override
  int get order => -1000;

  final SessionStoreOpener openStore;
  SessionStore? _store;
  SessionStore get store =>
      _store ?? (throw StateError('persistence is closed'));
  int? registryKey;
  PluginSession? _session;
  AgentLoop? _loop;
  String? _lastDetails;
  String? _lastModel;
  int? _subscription;

  @override
  SessionSeed? openSession(PluginSession session) {
    if (_session != null) throw StateError('persistence plugin already opened');
    _session = session;
    _store = openStore();
    if (session.resuming) {
      final log = store.readEntries(session.id);
      final gaps = store.checkGaps(session.id);
      if (gaps.isNotEmpty) {
        throw SessionStoreException(
            'session ${session.id} is corrupt: ${gaps.join('; ')}');
      }
      final details = store.readDetails(session.id);
      _lastDetails = jsonEncode(details.toJson());
      _lastModel = store.list().singleWhere((s) => s.id == session.id).model;
      return SessionSeed(log: log, details: details, model: _lastModel);
    }
    if (store.list().any((saved) => saved.id == session.id)) {
      throw SessionStoreException(
          'session ${session.id} already exists; resume it instead');
    }
    _lastDetails = jsonEncode(session.details.toJson());
    _lastModel = session.model;
    registryKey = store.createSession(session.id,
        title: session.title, model: session.model, details: session.details);
    return null;
  }

  @override
  void mountOn(AgentLoop loop) {
    _loop = loop;
    _subscription = loop.subscribe((entry, event) {
      if (event == LogEvent.appended) store.append(_session!.id, [entry]);
    });
  }

  @override
  void sessionChanged(PluginSession session) {
    final encoded = jsonEncode(session.details.toJson());
    if (encoded == _lastDetails && session.model == _lastModel) return;
    store.updateDetails(session.id, session.details, model: session.model);
    _lastModel = session.model;
    _lastDetails = encoded;
  }

  @override
  void closeSession() {
    final subscription = _subscription;
    if (subscription != null) _loop?.unsubscribe(subscription);
    _subscription = null;
    _loop = null;
    final opened = _store;
    _store = null;
    opened?.close();
  }
}
