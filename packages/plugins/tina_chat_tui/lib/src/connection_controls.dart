import 'dart:async';
import 'package:tina_host/tina_host.dart';
import 'package:tina_mode/observation.dart';
import 'package:tina_session_controls/observation.dart';

/// Each view reads public snapshots and submits data to the plugin owner.
final class ConnectionModeObservation implements ModeObservation {
  ConnectionModeObservation(this._connection);
  final SessionConnection _connection;
  static int _nextRequest = 0;
  int _revision = -1;
  bool get available => _available;
  bool _available = false;
  bool get canControl => available && _connection.canControl;
  @override
  PermissionMode get mode => _mode;
  PermissionMode _mode = PermissionMode.ask;

  void _apply(SessionSnapshot snapshot) {
    if (snapshot.cursor.revision <= _revision) return;
    _revision = snapshot.cursor.revision;
    try {
      if (snapshot.historyPublicationFailed) throw StateError('unavailable');
      final data = snapshot.features['tina/mode'] as Map;
      _mode = PermissionMode.values.byName(data['mode'] as String);
      _available = true;
    } catch (_) {
      _available = false;
    }
  }

  void refresh() => _refresh(_connection, _apply);
  @override
  void Function() listen(void Function(PermissionMode) listener) =>
      _listen(_connection, _apply, () => listener(mode));

  Future<void> setMode(PermissionMode value,
      {required PermissionMode expectedMode}) async {
    refresh();
    _connection.access.requireControl();
    if (!available) throw StateError('Permission controls unavailable.');
    final request = _connection.submitOperation('tina/mode', 'set',
        arguments: {'mode': value.name, 'expected_mode': expectedMode.name},
        id: _connection.requestWindow.id('mode-${++_nextRequest}'));
    _requireCompleted(await request.completed);
  }
}

final class ConnectionSessionControls implements SessionControlsObservation {
  ConnectionSessionControls(this._connection);
  final SessionConnection _connection;
  static int _nextRequest = 0;
  int _revision = -1;
  bool get available => _available;
  bool _available = false;
  bool get canControl => available && _connection.canControl;
  @override
  String get currentModel => _currentModel;
  String _currentModel = '';
  @override
  ModelCatalog get catalog => _catalog;
  ModelCatalog _catalog = const ModelCatalog();
  @override
  List<String> get recentModels => _recentModels;
  List<String> _recentModels = const [];

  void _apply(SessionSnapshot snapshot) {
    if (snapshot.cursor.revision <= _revision) return;
    _revision = snapshot.cursor.revision;
    try {
      if (snapshot.historyPublicationFailed) throw StateError('unavailable');
      final data = snapshot.features['tina/session-controls'] as Map;
      final next = ModelCatalog(
        models:
            List<String>.unmodifiable((data['models'] as List).cast<String>()),
        providerNames: Map<String, String>.unmodifiable(
            (data['provider_names'] as Map).cast<String, String>()),
        modelNames: Map<String, String>.unmodifiable(
            (data['model_names'] as Map).cast<String, String>()),
      );
      final model = data['model'] as String;
      final recent = List<String>.unmodifiable(
          (data['recent_models'] as List).cast<String>());
      _catalog = next;
      _currentModel = model;
      _recentModels = recent;
      _available = true;
    } catch (_) {
      _available = false;
      _currentModel = '';
      _catalog = const ModelCatalog();
      _recentModels = const [];
    }
  }

  void refresh() => _refresh(_connection, _apply);
  void Function() listen(void Function() changed) =>
      _listen(_connection, _apply, changed);

  Future<void> select(String model, {required String expectedModel}) async {
    refresh();
    _connection.access.requireControl();
    if (!available) throw StateError('Model controls unavailable.');
    final request = _connection.submitOperation(
        'tina/session-controls', 'select-model',
        arguments: {'model': model, 'expected_model': expectedModel},
        id: _connection.requestWindow.id('model-${++_nextRequest}'));
    _requireCompleted(await request.completed);
  }
}

void _requireCompleted(SessionRequestSnapshot result) {
  if (result.state != SessionRequestState.completed) {
    throw StateError(result.result?.detail.isNotEmpty == true
        ? result.result!.detail
        : 'Control change failed.');
  }
}

void _refresh(
    SessionConnection connection, void Function(SessionSnapshot) apply) {
  final attachment = connection.attach();
  try {
    apply(attachment.initial);
  } finally {
    attachment.close();
  }
}

void Function() _listen(SessionConnection connection,
    void Function(SessionSnapshot) apply, void Function() changed) {
  final attachment = connection.attach();
  var closed = false;
  void close() {
    if (closed) return;
    closed = true;
    attachment.close();
  }

  try {
    apply(attachment.initial);
  } catch (_) {
    close();
    rethrow;
  }
  Future<void> observe() async {
    try {
      while (!closed) {
        final update = await attachment.next();
        if (closed || update == null) return;
        apply(update.snapshot);
        changed();
        if (update.snapshot.status.closed) close();
      }
    } catch (_) {
      close();
    }
  }

  unawaited(observe());
  return close;
}
