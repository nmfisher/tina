/// Settings contracts independent of the engine, storage and any frontend.
library;

import 'dart:convert';

enum SettingScope { session, workspace, global }

enum ApplyAt { immediately, nextRequest, whenIdle, newSession, restart }

enum SettingKind { toggle, integer, text, choice, object }

/// Installed-plugin metadata: available even while the plugin is disabled.
final class SettingDefinition<T extends Object> {
  SettingDefinition({
    required this.id,
    required this.label,
    required this.description,
    required this.defaultValue,
    required this.kind,
    Set<SettingScope> scopes = const {...SettingScope.values},
    this.applyAt = ApplyAt.immediately,
    this.scopeReason = '',
    this.secret = false,
    this.minimum,
    this.maximum,
    List<String> choices = const [],
    List<String>? configPath,
    T Function(Object?)? decode,
    Object Function(T)? encode,
    this.validate,
    this.readConfig,
    this.writeConfig,
  })  : scopes = Set.unmodifiable(scopes),
        choices = List.unmodifiable(choices),
        configPath = List.unmodifiable(configPath ?? _defaultPath(id)),
        _decode = decode,
        _encode = encode {
    if (!RegExp(r'^[a-z][a-z0-9_-]*(?:/[a-z][a-z0-9_-]*){2,}$').hasMatch(id)) {
      throw ArgumentError(
          'Setting IDs must include a plugin namespace and key');
    }
    if (this.scopes.isEmpty ||
        this.configPath.isEmpty ||
        description.trim().isEmpty) {
      throw ArgumentError(
          'Settings require scopes, a storage path and a description');
    }
    checked(defaultValue);
  }
  final String id, label, description, scopeReason;
  final T defaultValue;
  final SettingKind kind;
  final Set<SettingScope> scopes;
  final ApplyAt applyAt;
  final bool secret;
  final int? minimum, maximum;
  final List<String> choices;

  /// Optional legacy TOML path. New plugins default to plugin_config tables.
  final List<String> configPath;
  final T Function(Object?)? _decode;
  final Object Function(T)? _encode;
  final void Function(T)? validate;

  /// Composite/legacy values may map to several keys, atomically.
  final Object? Function(Map<String, dynamic>)? readConfig;
  final void Function(Map<String, dynamic>, Object?)? writeConfig;
  String get owner => id.substring(0, id.lastIndexOf('/'));
  static List<String> _defaultPath(String id) {
    final split = id.lastIndexOf('/');
    if (split < 1)
      throw ArgumentError(
          'Setting IDs must include a plugin namespace and key');
    return ['plugin_config', id.substring(0, split), id.substring(split + 1)];
  }

  T checked(Object? raw) {
    final T value;
    try {
      value = _decode != null ? _decode(raw) : raw as T;
    } catch (_) {
      throw FormatException('$label has an invalid value');
    }
    if (kind == SettingKind.integer &&
        (value is! int ||
            minimum != null && value < minimum! ||
            maximum != null && value > maximum!)) {
      throw FormatException(
          '$label must be an integer${minimum == null ? '' : ' of at least $minimum'}${maximum == null ? '' : ' and at most $maximum'}');
    }
    if (kind == SettingKind.choice && !choices.contains(value)) {
      throw FormatException('$label must be one of: ${choices.join(', ')}');
    }
    if (kind == SettingKind.toggle && value is! bool ||
        kind == SettingKind.text && value is! String) {
      throw FormatException('$label has an invalid type');
    }
    validate?.call(value);
    return value;
  }

  Object encode(T value) => _encode?.call(checked(value)) ?? value;
  Object encodeObject(Object value) => encode(checked(value));
}

final class SettingCatalog {
  final _definitions = <String, SettingDefinition<Object>>{};
  Iterable<SettingDefinition<Object>> get definitions => _definitions.values;
  SettingDefinition<Object> operator [](String id) =>
      _definitions[id] ?? (throw ArgumentError('Unknown setting: $id'));
  bool contains(String id) => _definitions.containsKey(id);
  void replace(SettingDefinition<Object> definition) =>
      _definitions[definition.id] = definition;
  void register(SettingDefinition<Object> definition) {
    if (_definitions.containsKey(definition.id))
      throw StateError('Duplicate setting: ${definition.id}');
    _definitions[definition.id] = definition;
  }
}

/// Store encoded values by definition ID. Implementations retain unknown keys.
abstract interface class SettingsBackend {
  Map<String, Object?> read(SettingScope scope);
  void write(SettingScope scope, Map<String, Object?> values);
}

final class MemorySettingsBackend implements SettingsBackend {
  final layers = <SettingScope, Map<String, Object?>>{};
  @override
  Map<String, Object?> read(SettingScope scope) => Map.of(layers[scope] ?? {});
  @override
  void write(SettingScope scope, Map<String, Object?> values) =>
      layers[scope] = Map.of(values);
}

final class ResolvedSetting<T extends Object> {
  const ResolvedSetting(this.value, this.source);
  final T value;

  /// Null denotes the plugin's built-in default.
  final SettingScope? source;
  String get sourceLabel => source?.name ?? 'default';
}

/// One session's view of the shared global/workspace layers and its overrides.
final class ScopedSettings {
  ScopedSettings({required this.catalog, required this.backend}) {
    reload();
  }
  final SettingCatalog catalog;
  final SettingsBackend backend;
  Map<SettingScope, Map<String, Object?>> _layers = {};
  final _listeners = <Object, void Function()>{};
  final applicationErrors = <String, String>{};
  bool _closed = false;
  Map<String, Object?> layer(SettingScope scope) =>
      Map.unmodifiable(_layers[scope] ?? {});

  void _checkOpen() {
    if (_closed) throw StateError('Settings are closed');
  }

  void _validate(Map<SettingScope, Map<String, Object?>> layers) {
    for (final scope in SettingScope.values) {
      for (final entry in layers[scope]!.entries) {
        if (!catalog.contains(entry.key)) continue;
        final definition = catalog[entry.key];
        if (!definition.scopes.contains(scope))
          throw FormatException(
              '${definition.label} does not support ${scope.name} scope');
        definition.checked(entry.value);
      }
    }
  }

  void reload() {
    _checkOpen();
    final next = {
      for (final scope in SettingScope.values) scope: backend.read(scope)
    };
    _validate(next);
    final changed = jsonEncode(_layers.map((k, v) => MapEntry(k.name, v))) !=
        jsonEncode(next.map((k, v) => MapEntry(k.name, v)));
    _layers = next;
    if (changed) _notify();
  }

  ResolvedSetting<T> read<T extends Object>(SettingDefinition<T> definition,
      {SettingScope scope = SettingScope.session}) {
    _checkOpen();
    for (final candidate in SettingScope.values.skip(scope.index)) {
      if (_layers[candidate]!.containsKey(definition.id)) {
        return ResolvedSetting(
            definition.checked(_layers[candidate]![definition.id]), candidate);
      }
    }
    return ResolvedSetting(definition.defaultValue, null);
  }

  bool hasOverride(SettingDefinition<Object> definition, SettingScope scope) =>
      _layers[scope]!.containsKey(definition.id);
  Object? override(SettingDefinition<Object> definition, SettingScope scope) =>
      _layers[scope]![definition.id];

  void set<T extends Object>(
          SettingDefinition<T> definition, T value, SettingScope scope) =>
      update(scope, {definition.id: definition.encode(value)});
  void removeOverride(
          SettingDefinition<Object> definition, SettingScope scope) =>
      update(scope, const {}, remove: {definition.id});

  /// One confirmed form is one write. Validation precedes persistence.
  void update(SettingScope scope, Map<String, Object?> values,
      {Set<String> remove = const {}}) {
    _checkOpen();
    reload();
    for (final id in {...values.keys, ...remove}) {
      final definition = catalog[id];
      if (!definition.scopes.contains(scope))
        throw ArgumentError(
            '${definition.label}: ${definition.scopeReason.isEmpty ? '${scope.name} scope is unavailable' : definition.scopeReason}');
    }
    final next = Map<String, Object?>.of(_layers[scope]!);
    for (final key in remove) {
      next.remove(key);
    }
    next.addAll(values);
    _validate({..._layers, scope: next});
    backend.write(scope, next);
    reload();
  }

  void Function() listen(void Function() listener) {
    _checkOpen();
    final token = Object();
    _listeners[token] = listener;
    return () => _listeners.remove(token);
  }

  void Function() watch<T extends Object>(
      SettingDefinition<T> definition, void Function(ResolvedSetting<T>) apply,
      {bool fireImmediately = false}) {
    var previous = read(definition);
    void deliver() {
      final next = read(definition);
      if (jsonEncode(definition.encode(next.value)) ==
              jsonEncode(definition.encode(previous.value)) &&
          next.source == previous.source) return;
      previous = next;
      try {
        apply(next);
        applicationErrors.remove(definition.id);
      } catch (_) {
        applicationErrors[definition.id] =
            '${definition.label} was saved but could not be applied';
      }
    }

    final stop = listen(deliver);
    if (fireImmediately) apply(previous);
    return stop;
  }

  void _notify() {
    for (final entry in _listeners.entries.toList()) {
      if (_listeners.containsKey(entry.key)) entry.value();
    }
  }

  void close() {
    _closed = true;
    _listeners.clear();
  }
}
