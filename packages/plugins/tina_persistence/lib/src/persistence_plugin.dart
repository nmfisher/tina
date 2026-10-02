import 'dart:convert';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_settings/tina_settings.dart';

import 'store.dart';

typedef SessionStoreOpener = SessionStore Function();

/// Owns the session store and its log subscription. The application assembly
/// supplies an opener for the chosen location, including :memory: in tests.
final class PersistencePlugin extends AgentPlugin {
  PersistencePlugin({required this.openStore, this.settings});
  final ScopedSettings? settings;
  void Function()? _stopSettings;
  String? _lastSettings;

  /// Interpret this plugin's own opaque snapshot before factories are built.
  static void restoreSettings(
      ScopedSettings settings, Iterable<SessionEntry> log) {
    PluginStateEntry? snapshot;
    for (final entry in log) {
      if (entry is PluginStateEntry &&
          entry.pluginId == 'tina/persistence' &&
          entry.stateKey == 'settings') snapshot = entry;
    }
    if (snapshot == null) return;
    if (snapshot.schemaVersion != 1)
      throw const FormatException('Unsupported session settings version');
    final values = snapshot.value?['overrides'] as Map? ?? {};
    settings.backend
        .write(SettingScope.session, Map<String, Object?>.from(values));
    settings.reload();
  }

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
  bool _saved = false;

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
      _saved = true;
      return SessionSeed(log: log, details: details, model: _lastModel);
    }
    if (store.list().any((saved) => saved.id == session.id)) {
      throw SessionStoreException(
          'session ${session.id} already exists; resume it instead');
    }
    _lastDetails = jsonEncode(session.details.toJson());
    _lastModel = session.model;
    return null;
  }

  @override
  void mountOn(AgentLoop loop) {
    _loop = loop;
    final scoped = settings;
    if (scoped != null) {
      _lastSettings = jsonEncode(scoped.layer(SettingScope.session));
      final record = loop.stateWriter(id);
      _stopSettings = scoped.listen(() {
        final overrides = scoped.layer(SettingScope.session);
        final encoded = jsonEncode(overrides);
        if (_lastSettings == encoded) return;
        _lastSettings = encoded;
        record(PluginStateEntry.snapshot(
            pluginId: id,
            stateKey: 'settings',
            schemaVersion: 1,
            value: {'overrides': overrides},
            at: DateTime.now().toUtc().toIso8601String()));
      });
    }
    // Runtime enablement also saves activity already recorded in memory.
    if (!_saved && loop.log.isNotEmpty) {
      _saveSession();
      store.append(_session!.id, loop.log);
    }
    _subscription = loop.subscribe((entry, event) {
      if (event != LogEvent.appended) return;
      final session = _session!;
      if (!_saved) _saveSession();
      store.append(session.id, [entry]);
    });
  }

  void _saveSession() {
    final session = _session!;
    registryKey = store.createSession(session.id,
        title: session.title, model: session.model, details: session.details);
    _saved = true;
    _lastDetails = jsonEncode(session.details.toJson());
    _lastModel = session.model;
  }

  @override
  void sessionChanged(PluginSession session) {
    final encoded = jsonEncode(session.details.toJson());
    if (!_saved) return;
    if (encoded == _lastDetails && session.model == _lastModel) return;
    store.updateDetails(session.id, session.details, model: session.model);
    _lastModel = session.model;
    _lastDetails = encoded;
  }

  @override
  void closeSession() {
    _stopSettings?.call();
    _stopSettings = null;
    final subscription = _subscription;
    if (subscription != null) _loop?.unsubscribe(subscription);
    _subscription = null;
    _loop = null;
    final opened = _store;
    _store = null;
    opened?.close();
  }
}
