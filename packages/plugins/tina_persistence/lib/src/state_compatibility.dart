import 'package:tina_engine_2/tina_engine_2.dart';

/// Read-time normalization only. Historical database rows are never rewritten.
/// Payload schemas remain the responsibility of the owning plugin's codec.
SessionEntry decodePersistedEntry(Map<String, dynamic> json) {
  final owner = switch (json['type']) {
    'plan_changed' => ('tina/plans', 'plan'),
    'goal_changed' => ('tina/goals', 'goal'),
    'workflow_run' => ('tina/workflows', 'last-run'),
    'mode_changed' => ('tina/mode', 'permission-mode'),
    _ => null,
  };
  if (owner == null) return SessionEntry.fromJson(json);
  final value = Map<String, dynamic>.from(json)
    ..remove('type')
    ..remove('seq')
    ..remove('at');
  if (json['type'] == 'mode_changed' && value['mode'] == 'normal')
    value['mode'] = 'ask';
  return PluginStateEntry.snapshot(
      pluginId: owner.$1,
      stateKey: owner.$2,
      schemaVersion: 1,
      value: value,
      seq: json['seq'] as int? ?? 0,
      at: json['at'] as String? ?? '');
}
