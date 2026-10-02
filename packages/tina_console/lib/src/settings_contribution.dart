import 'dart:async';
import 'package:tina_settings/tina_settings.dart';

/// UI descriptions and callbacks only. Plugins own their values and storage.
sealed class SettingControl {
  const SettingControl({required this.id, required this.label, this.scopes});
  final String id;
  final String label;

  /// Null denotes a custom control outside configuration inheritance.
  final Set<SettingScope>? scopes;
}

/// A plugin can bind a typed scoped value to the standard settings editor.
/// Actions and temporary UI controls keep their existing callback contracts.
final class ScopedSettingControl extends SettingControl {
  ScopedSettingControl({required this.definition, required this.settings})
      : super(
            id: definition.id,
            label: definition.label,
            scopes: definition.scopes);
  final SettingDefinition<Object> definition;
  final ScopedSettings settings;
}

final class SettingToggle extends SettingControl {
  const SettingToggle(
      {required super.id,
      required super.label,
      super.scopes,
      required this.read,
      required this.change});
  final bool Function() read;
  final FutureOr<void> Function(bool) change;
}

final class SettingText extends SettingControl {
  const SettingText(
      {required super.id,
      required super.label,
      super.scopes,
      required this.read,
      required this.change,
      this.secret = false});
  final String Function() read;
  final FutureOr<void> Function(String) change;
  final bool secret;
}

final class SettingChoice extends SettingControl {
  const SettingChoice(
      {required super.id,
      required super.label,
      super.scopes,
      required this.read,
      required this.change,
      required this.options});
  final String Function() read;
  final FutureOr<void> Function(String) change;
  final List<String> options;
}

final class SettingAction extends SettingControl {
  const SettingAction(
      {required super.id, required super.label, required this.invoke});
  final FutureOr<void> Function() invoke;
}

final class SettingsSection {
  SettingsSection._(this.id, this.title, this.order, this.build);
  final String id;
  final String title;
  final int order;
  final List<SettingControl> Function() build;
}

/// A typed contribution point for a session's settings panel.
/// Scoped facades share registrations but give cleanup to their attachment.
final class SettingsRegistry {
  SettingsRegistry()
      : _state = _SettingsState(),
        _own = null;
  SettingsRegistry._(this._state, this._own);
  final _SettingsState _state;
  final void Function() Function(void Function())? _own;

  SettingsRegistry scoped(void Function() Function(void Function()) own) =>
      SettingsRegistry._(_state, own);

  List<SettingsSection> get sections => _state.sections.values.toList()
    ..sort((a, b) =>
        a.order != b.order ? a.order.compareTo(b.order) : a.id.compareTo(b.id));

  bool contains(SettingsSection section) =>
      identical(_state.sections[section.id], section);

  void Function() registerSection(
      {required String id,
      required String title,
      required List<SettingControl> Function() build,
      int order = 100}) {
    if (!RegExp(r'^[a-z][a-z0-9_-]*/[a-z][a-z0-9_/-]*$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'use a namespaced section ID');
    }
    if (_state.sections.containsKey(id)) {
      throw StateError('settings section already registered: $id');
    }
    final section = SettingsSection._(id, title, order, build);
    var removed = false;
    void remove() {
      if (removed) return;
      removed = true;
      if (contains(section)) {
        _state.sections.remove(id);
        refresh();
      }
    }

    // Claim cleanup before publishing: a disposed attachment cannot register.
    final release = _own?.call(remove) ?? remove;
    _state.sections[id] = section;
    try {
      refresh();
    } catch (_) {
      release();
      rethrow;
    }
    return release;
  }

  void Function() listen(void Function() listener) {
    final token = Object();
    final release = _own?.call(() => _state.listeners.remove(token)) ??
        () => _state.listeners.remove(token);
    _state.listeners[token] = listener;
    return release;
  }

  /// Rebuild visible controls after a plugin changes its UI state.
  void refresh() {
    for (final entry in _state.listeners.entries.toList()) {
      if (_state.listeners.containsKey(entry.key)) entry.value();
    }
  }
}

final class _SettingsState {
  final sections = <String, SettingsSection>{};
  final listeners = <Object, void Function()>{};
}
