part of '../tina_settings.dart';

Object? _immutable(Object? value) => switch (value) {
      Map value => Map<String, Object?>.unmodifiable(
          value.map((key, item) => MapEntry(key as String, _immutable(item)))),
      List value => List<Object?>.unmodifiable(value.map(_immutable)),
      _ => value,
    };

/// Descriptive data only; validation and storage callbacks stay with the owner.
final class SettingInfo {
  SettingInfo(SettingDefinition<Object> definition)
      : id = definition.id,
        owner = definition.owner,
        label = definition.label,
        description = definition.description,
        scopeReason = definition.scopeReason,
        scopes = Set.unmodifiable(definition.scopes),
        kind = definition.kind,
        applyAt = definition.applyAt,
        secret = definition.secret,
        minimum = definition.minimum,
        maximum = definition.maximum,
        choices = List.unmodifiable(definition.choices),
        configPath = List.unmodifiable(definition.configPath),
        defaultValue = _publicValue(
            definition, definition.encodeObject(definition.defaultValue));
  final String id, owner, label, description, scopeReason;
  final Set<SettingScope> scopes;
  final SettingKind kind;
  final ApplyAt applyAt;
  final bool secret;
  final int? minimum, maximum;
  final List<String> choices, configPath;
  final Object? defaultValue;
}

Object? _publicValue(SettingDefinition<Object> definition, Object? value) =>
    definition.secret
        ? value == null || value == ''
            ? null
            : const <String, Object?>{r'$secret': true}
        : _immutable(value);

final class SettingsCatalogSnapshot {
  SettingsCatalogSnapshot(Iterable<SettingInfo> definitions)
      : _definitions = Map.unmodifiable({for (final d in definitions) d.id: d});
  final Map<String, SettingInfo> _definitions;
  Iterable<SettingInfo> get definitions => _definitions.values;
  SettingInfo operator [](String id) =>
      _definitions[id] ?? (throw ArgumentError('Unknown setting: $id'));
}

/// Values, inheritance and errors at one revision. No secrets or live handles.
final class SettingsSnapshot {
  SettingsSnapshot._(
      this.revision, this.catalog, this._layers, Map<String, String> errors)
      : applicationErrors = Map.unmodifiable(errors);
  final String revision;
  final SettingsCatalogSnapshot catalog;
  final Map<SettingScope, Map<String, Object?>> _layers;
  final Map<String, String> applicationErrors;

  ResolvedSetting<Object> read(SettingInfo definition,
      {SettingScope scope = SettingScope.session}) {
    for (final candidate in SettingScope.values.skip(scope.index)) {
      if (_layers[candidate]!.containsKey(definition.id)) {
        return ResolvedSetting(
            _layers[candidate]![definition.id] ?? '', candidate);
      }
    }
    return ResolvedSetting(definition.defaultValue ?? '', null);
  }

  bool hasOverride(SettingInfo definition, SettingScope scope) =>
      _layers[scope]!.containsKey(definition.id);
  Object? override(SettingInfo definition, SettingScope scope) =>
      _layers[scope]![definition.id];
}

/// An edit based on an older snapshot must be reviewed again, never rebased
/// silently onto another attachment's changes.
final class SettingsConflict implements Exception {
  const SettingsConflict();
  @override
  String toString() => 'Settings changed; reopen this editor and try again.';
}

/// In-process operations over one owner's settings. Disposing this client
/// releases only its subscriptions. It does not own the settings or backend.
final class SettingsClient {
  SettingsClient(ScopedSettings settings,
      {Object? Function()? revisionSource,
      void Function(String id, Object? value)? applyAll})
      : _settings = settings,
        _revisionSource = revisionSource,
        _applyAll = applyAll,
        _epoch = ++_nextEpoch;
  static int _nextEpoch = 0;
  final int _epoch;
  final ScopedSettings _settings;
  final Object? Function()? _revisionSource;
  final void Function(String, Object?)? _applyAll;
  final _releases = <void Function()>{};
  String? _fingerprint;
  int _revision = 0;
  bool _closed = false;
  void _checkOpen() {
    if (_closed) throw StateError('Settings client is closed');
  }

  SettingsSnapshot snapshot({bool refresh = false}) {
    _checkOpen();
    if (refresh) _settings.reload();
    final definitions = _settings.catalog.definitions.toList();
    final fingerprint = jsonEncode({
      'layers': {
        for (final scope in SettingScope.values)
          scope.name: _settings.layer(scope),
      },
      'definitions': [
        for (final d in definitions)
          [
            d.id,
            d.kind.name,
            d.choices,
            d.scopes.map((s) => s.name).toList(),
            d.encodeObject(d.defaultValue),
            d.minimum,
            d.maximum,
            d.secret,
            d.configPath,
            d.applyAt.name
          ],
      ],
      'source': _revisionSource?.call(),
    });
    if (_fingerprint != fingerprint) {
      _fingerprint = fingerprint;
      _revision++;
    }
    return SettingsSnapshot._(
        '$_epoch:$_revision',
        SettingsCatalogSnapshot(definitions.map(SettingInfo.new)),
        Map.unmodifiable({
          for (final scope in SettingScope.values)
            scope: Map<String, Object?>.unmodifiable({
              for (final definition in definitions)
                if (_settings.hasOverride(definition, scope))
                  definition.id: _publicValue(
                      definition, _settings.override(definition, scope)),
            }),
        }),
        _settings.applicationErrors);
  }

  void checkRevision(String expected) {
    if (snapshot(refresh: true).revision != expected) {
      throw const SettingsConflict();
    }
  }

  SettingsSnapshot update(SettingScope scope,
      {required String expectedRevision,
      Map<String, Object?> values = const {},
      Set<String> remove = const {}}) {
    checkRevision(expectedRevision);
    // Submitted encoded values belong to the request. The owner must not keep
    // mutable objects an editor can change after the operation returns.
    final submitted =
        Map<String, Object?>.from(jsonDecode(jsonEncode(values)) as Map);
    _settings._updateLoaded(scope, submitted, remove: Set.of(remove));
    return snapshot();
  }

  void setInAllScopes(String id, Object? value,
      {required String expectedRevision}) {
    checkRevision(expectedRevision);
    final apply = _applyAll;
    if (apply == null) throw UnsupportedError('All scopes is unavailable');
    apply(id, value);
  }

  void Function() listen(void Function() listener) {
    _checkOpen();
    late final void Function() stop;
    stop = _settings.listen(() {
      try {
        listener();
      } catch (_) {
        // A broken editor must not turn a successful owner write into failure
        // or prevent other attachments and runtime watchers from observing it.
        stop();
        _releases.remove(stop);
      }
    });
    _releases.add(stop);
    return () {
      _releases.remove(stop);
      stop();
    };
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final release in _releases) release();
    _releases.clear();
  }
}
