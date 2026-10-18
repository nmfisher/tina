import 'dart:convert';
import 'package:tina_settings/tina_settings.dart';

/// Capabilities supplied by application composition to one settings attachment.
/// The panel receives no config files, plugin manager, stores or provider factory.
abstract interface class SettingsManagement {
  SettingsClient get settings;
  void Function() listen(void Function() listener);
  Map<String, PluginSettingInfo> get plugins;
  List<ProviderOption> get providers;
  bool get hasCommandApprovals;
  List<Map<String, Object?>> get commandApprovals;
  void revokeCommandApproval(String id);
  ProviderDraft openDraft(SettingScope scope, {bool providerCatalog = false});
  GenerationForm generation(ProviderDraft draft, {String? provider});
  void saveDraft(ProviderDraft draft);
  void saveGeneration(
      ProviderDraft draft, String provider, Map<String, dynamic> fields);
  void closeDraft(ProviderDraft draft);
  void refresh();
  void close();
}

final class PluginSettingInfo {
  PluginSettingInfo(this.description, this.status, Iterable<String> reasons,
      {bool locked = false,
      Iterable<String> missingDependencies = const [],
      Iterable<String> dependents = const []})
      : _locked = locked,
        blockingReasons = List.unmodifiable(reasons),
        missingDependencies = List.unmodifiable(missingDependencies),
        dependents = List.unmodifiable(dependents);
  final String description, status;
  final List<String> blockingReasons;

  /// Whether settings toggles can never disable this plugin: the application
  /// requires its capability, or it is the selected approval channel.
  final bool _locked;

  /// Plugin IDs this plugin needs that the effective selection does not
  /// supply, deepest provider first. Enabling it enables these too.
  final List<String> missingDependencies;

  /// Selected plugin IDs that transitively depend on this one, leaf consumers
  /// first. Disabling it disables these too.
  final List<String> dependents;
  bool get required => blockingReasons.isNotEmpty;
  bool get locked => _locked;
}

final class ProviderOption {
  ProviderOption(
      {required this.id,
      required this.name,
      required this.baseUrl,
      required this.keyEnvVar,
      required Map<String, String> models})
      : models = Map.unmodifiable(models);
  final String id, name, baseUrl, keyEnvVar;
  final Map<String, String> models;
}

enum SecretAction { keep, replace, clear }

final class SecretEdit {
  const SecretEdit.keep()
      : action = SecretAction.keep,
        value = null;
  const SecretEdit.replace(String this.value) : action = SecretAction.replace;
  const SecretEdit.clear()
      : action = SecretAction.clear,
        value = null;
  final SecretAction action;
  final String? value;
}

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();

/// Attachment-owned draft of public provider fields. Existing credentials
/// never enter this object. Secret edits explicitly keep, replace or clear.
final class ProviderDraft {
  ProviderDraft(
      {required this.id,
      required this.revision,
      required Map<String, dynamic> values,
      required Iterable<String> secrets,
      required this.exists})
      : values = _copy(values),
        _baseline = _copy(values),
        configuredSecrets = Set.unmodifiable(secrets);
  final String id;
  String revision;
  final Map<String, dynamic> values;
  final Map<String, dynamic> _baseline;
  final Set<String> configuredSecrets;
  final bool exists;
  final secretEdits = <String, SecretEdit>{};

  Map<String, dynamic> table(String name) =>
      values.putIfAbsent(name, () => <String, dynamic>{})
          as Map<String, dynamic>;
  SecretEdit secret(String provider, String field) =>
      secretEdits['$provider/$field'] ?? const SecretEdit.keep();
  bool hasSecret(String provider, String field) =>
      switch (secret(provider, field).action) {
        SecretAction.keep => configuredSecrets.contains('$provider/$field'),
        SecretAction.replace => secret(provider, field).value!.isNotEmpty,
        SecretAction.clear => false,
      };
  void editSecret(String provider, String field, SecretEdit edit) {
    secretEdits['$provider/$field'] = edit;
  }

  ProviderDraft fork() => ProviderDraft(
      id: id,
      revision: revision,
      values: values,
      secrets: configuredSecrets,
      exists: exists)
    ..secretEdits.addAll(secretEdits);

  bool get hasChanges {
    Object? normalize(Object? value) => switch (value) {
          Map value => {
              for (final key in value.keys.cast<String>().toList()..sort())
                if (value[key] is! Map || (value[key] as Map).isNotEmpty)
                  key: normalize(value[key]),
            },
          List value => value.map(normalize).toList(),
          _ => value,
        };
    return jsonEncode(normalize(values)) != jsonEncode(normalize(_baseline)) ||
        secretEdits.values.any((edit) => edit.action != SecretAction.keep);
  }

  void acceptGeneration(String provider, Map<String, dynamic> fields) {
    for (final document in [values, _baseline]) {
      final providers = document.putIfAbsent(
          'providers', () => <String, dynamic>{}) as Map<String, dynamic>;
      final values = providers.putIfAbsent(provider, () => <String, dynamic>{})
          as Map<String, dynamic>;
      for (final key in ['max_output', 'reasoning_effort', 'thinking_budget']) {
        values.remove(key);
      }
      values.addAll(fields);
    }
  }
}

/// Provider policy resolved by the owner; the frontend only edits choices.
final class GenerationForm {
  GenerationForm(
      {required this.provider,
      required this.exists,
      required this.automaticOutput,
      required this.output,
      required this.budget,
      required this.selected,
      required Iterable<String> efforts,
      required Iterable<String> labels,
      Iterable<String> members = const []})
      : efforts = List.unmodifiable(efforts),
        labels = List.unmodifiable(labels),
        members = List.unmodifiable(members);
  final String provider, output;
  final bool exists;
  final int automaticOutput, selected;
  final int? budget;
  final List<String> efforts, labels, members;
}

/// Pure presentation helpers for local, unsaved model choices.
Map<String, String> providerModels(
        ProviderOption? descriptor, Map<String, dynamic> values) =>
    {
      ...?descriptor?.models,
      for (final spec in (values['models'] as List? ?? const []).cast<String>())
        spec.split('|').first.trim(): spec.contains('|')
            ? spec.substring(spec.indexOf('|') + 1).trim()
            : spec.trim(),
    };
