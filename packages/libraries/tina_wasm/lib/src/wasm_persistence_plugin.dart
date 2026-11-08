/// The wasm engine's `tina/persistence`: the sqlite plugin's behavior
/// over the WASI session store — register the session with its first
/// batch, append every committed batch, revise details, seed a resume —
/// with the settings snapshot and replay through the same
/// `PluginStateEntry` codec, so a resumed session's settings and log
/// come back exactly as the native store returns them.
library;

import 'dart:async';
import 'dart:convert';

import 'package:tina_core/tina_core.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_persistence/session_store_api.dart';
import 'package:tina_settings/tina_settings.dart';

import 'wasi_session_store.dart';

final class WasmPersistencePlugin extends AgentPlugin {
  /// [store] is the already-loaded store (the composition root awaits
  /// the WASI preload before the assembly boots, so the plugin's
  /// synchronous lifecycle never waits on a stream).
  WasmPersistencePlugin({required WasiSessionStore store, this.settings})
      : _loaded = store,
        _store = store;

  @override
  String get id => 'tina/persistence';

  @override
  int get order => -1000;

  final ScopedSettings? settings;

  /// The loaded store handed in at construction; openSession adopts it.
  final WasiSessionStore _loaded;
  WasiSessionStore? _store;
  WasiSessionStore get store =>
      _store ?? (throw StateError('persistence is closed'));

  /// The composition root flushes this after the assembly shuts down
  /// (after closeSession released the session's handle; the loaded store
  /// itself outlives the plugin).
  Future<void> flush() => _loaded.flush();

  PluginSession? _session;
  AgentLoop? _loop;
  String? _lastDetails;
  String? _lastModel;
  String? _lastSettings;
  int? _subscription;
  bool _saved = false;
  void Function()? _stopSettings;
  (Object, StackTrace)? _saveFailure;

  @override
  SessionSeed? openSession(PluginSession session) {
    if (_session != null) throw StateError('persistence plugin already opened');
    _session = session;
    _store = _loaded;
    if (session.resuming) {
      final log = store.readEntries(session.id);
      final gaps = store.checkGaps(session.id);
      if (gaps.isNotEmpty) {
        throw SessionStoreException(
            'session ${session.id} is corrupt: ${gaps.join('; ')}');
      }
      final stored =
          store.list().where((saved) => saved.id == session.id).toList();
      if (stored.isEmpty) {
        throw SessionStoreException(
            'no session ${session.id} in ${store.file}');
      }
      final details = store.readDetails(session.id);
      _lastDetails = jsonEncode(details.toJson());
      _lastModel = stored.first.model;
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

  void _checkSaveFailure() {
    if (_saveFailure case final failure?) {
      Error.throwWithStackTrace(failure.$1, failure.$2);
    }
  }

  void _saveEntries(List<SessionEntry> entries) {
    _checkSaveFailure();
    try {
      final session = _session!;
      if (_saved) {
        store.append(session.id, entries);
      } else {
        store.createSession(session.id,
            title: session.title,
            model: session.model,
            details: session.details,
            entries: entries);
        _saved = true;
        _lastDetails = jsonEncode(session.details.toJson());
        _lastModel = session.model;
      }
    } catch (error, stack) {
      _saveFailure = (error, stack);
      rethrow;
    }
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
    if (!_saved && loop.log.isNotEmpty) {
      _saveEntries(loop.log);
    }
    _subscription = loop.subscribeBatches((entries, event) {
      if (event != LogEvent.appended) return;
      _saveEntries(entries);
    });
  }

  @override
  void sessionChanged(PluginSession session) {
    _checkSaveFailure();
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
