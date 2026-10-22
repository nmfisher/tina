import 'dart:convert';
import 'package:tina_host/tina_host.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_tools/tina_tools.dart' show CommandApprovalStore;
import 'assembly_config.dart';
import 'config_document.dart';
import 'configured_provider.dart';
import 'plugin_settings.dart';
import 'scoped_config.dart';
import 'settings_catalog.dart';
import 'package:tina_tui/tina_tui.dart';

const _publicProviderFields = {
  'name',
  'wire',
  'base_url',
  'models',
  'disabled_models',
  'members',
  'requests_per_minute',
  'min_request_interval_ms',
  'max_output',
  'reasoning_effort',
  'thinking_budget',
  'output_token_field',
  'structured_output',
};
const _secretFields = {'api_key', 'auth_token'};

String _canonical(Object? value) {
  Object? sorted(Object? value) => switch (value) {
        Map value => {
            for (final key in value.keys.cast<String>().toList()..sort())
              key: sorted(value[key])
          },
        List value => value.map(sorted).toList(),
        _ => value,
      };
  return jsonEncode(sorted(value));
}

final class _Edit {
  _Edit(this.document, this.revision, this.providerCatalog);
  ConfigDocument document;
  String revision;
  final bool providerCatalog;
}

/// Application adapter. Config validation, file transactions, credentials and
/// runtime application remain here; SettingsPanel sees data and operations.
final class ConfigSettingsManagement implements SettingsManagement {
  ConfigSettingsManagement(
      {required ScopedSettings scopedSettings,
      required ConfigSettingsBackend backend,
      List<ProviderDescriptor>? descriptors,
      PluginSettings<dynamic>? pluginSettings,
      PluginManager<dynamic>? pluginManager,
      Map<String, String> pluginDescriptions = const {},
      void Function(Iterable<String>)? validatePlugins,
      void Function()? applyConfiguration,
      void Function() Function(void Function())? listenConfiguration,
      CommandApprovalStore? commandApprovals,
      ClientAccess access = const ClientAccess()})
      : _scoped = scopedSettings,
        _access = access,
        _backend = backend,
        _descriptors = descriptors ?? configuredDescriptors(),
        _plugins = pluginSettings,
        _manager = pluginManager,
        _descriptions = Map.of(pluginDescriptions),
        _validatePlugins = validatePlugins,
        _applyConfiguration = applyConfiguration,
        _approvals = commandApprovals,
        _listenConfiguration = listenConfiguration {
    settings = SettingsClient(_scoped,
        requireWrite: _access.requireControl,
        canRefresh: () => _access.canControl,
        revisionSource: () => [
              _backend.document(SettingScope.global),
              _backend.document(SettingScope.workspace),
            ],
        applyAll: (id, value) {
          if (value != null && value is! bool)
            throw ArgumentError('Plugin state must be a boolean');
          _backend.setPluginInAllScopes(
              _scoped, _scoped.catalog[id], value as bool?,
              refresh: false);
        });
  }
  final ScopedSettings _scoped;
  final ClientAccess _access;
  final ConfigSettingsBackend _backend;
  final List<ProviderDescriptor> _descriptors;
  final PluginSettings<dynamic>? _plugins;
  final PluginManager<dynamic>? _manager;
  final Map<String, String> _descriptions;
  final void Function(Iterable<String>)? _validatePlugins;
  final void Function()? _applyConfiguration;
  final void Function() Function(void Function())? _listenConfiguration;
  final CommandApprovalStore? _approvals;
  final _edits = <String, _Edit>{};
  final _releases = <void Function()>{};
  int _nextEdit = 0;
  bool _closed = false;
  @override
  late final SettingsClient settings;

  @override
  void Function() listen(void Function() listener) {
    _checkOpen();
    final stopSettings = settings.listen(listener);
    final stopConfiguration = _listenConfiguration?.call(listener);
    void release() {
      stopSettings();
      stopConfiguration?.call();
      _releases.remove(release);
    }

    _releases.add(release);
    return release;
  }

  void _checkOpen() {
    if (_closed) throw StateError('Settings attachment is closed');
  }

  @override
  Map<String, PluginSettingInfo> get plugins {
    _checkOpen();
    final reasons = _plugins?.blockingReasons ?? const <String, List<String>>{};
    return Map.unmodifiable({
      for (final d in _scoped.catalog.definitions
          .where((d) => d.id.endsWith('/enabled')))
        d.owner: PluginSettingInfo(
            _descriptions[d.owner] ?? d.description,
            _plugins != null && _manager != null
                ? _plugins.changeStatus(d.owner, _manager)
                : d.applyAt == ApplyAt.restart
                    ? 'after restart'
                    : 'when idle',
            reasons[d.owner] ?? const [],
            locked: _plugins != null &&
                _plugins.requiredIds.contains(d.owner) &&
                _plugins.applicationRequired(d.owner),
            missingDependencies:
                _plugins?.missingDependenciesOf(d.owner) ?? const [],
            dependents: _plugins?.dependentsOf(d.owner) ?? const []),
    });
  }

  @override
  List<ProviderOption> get providers => List.unmodifiable([
        for (final d in _descriptors)
          ProviderOption(
              id: d.id,
              name: d.name,
              baseUrl: d.baseUrl,
              keyEnvVar: d.keyEnvVar,
              models: {
                for (final model in d.models.values) model.id: model.name
              }),
      ]);
  @override
  bool get hasCommandApprovals => true;

  Iterable<Map<String, Object?>> _folderPermissions() sync* {
    for (final entry in _backend.permissionStore.entries) {
      final setting = entry['setting'];
      final value = entry['value'];
      if (entry['kind'] == 'setting' &&
          value is List &&
          {'tina/tools/read_only_directories', 'tina/tools/write_directories'}
              .contains(setting)) {
        for (final directory in value.whereType<String>()) {
          yield {
            ...entry,
            'id': '${entry['id']}#${base64Url.encode(utf8.encode(directory))}',
            'source_id': entry['id'],
            'directory_value': directory,
            'command': setting == 'tina/tools/read_only_directories'
                ? 'Read folder'
                : 'Write folder (includes deletion)',
            'directory': directory,
          };
        }
      } else {
        yield entry;
      }
    }
  }

  @override
  List<Map<String, Object?>> get commandApprovals {
    _checkOpen();
    return List.unmodifiable([
      for (final entry in [
        ...?_approvals?.entries,
        ..._folderPermissions(),
      ])
        if (!(entry['kind'] == 'setting' &&
            (entry['value'] == false ||
                entry['value'] is List && (entry['value'] as List).isEmpty)))
          Map<String, Object?>.unmodifiable({
            for (final key in [
              'id',
              'scope',
              'command',
              'pattern',
              'directory'
            ])
              key: entry[key],
          }),
    ]);
  }

  @override
  void revokeCommandApproval(String id) {
    _checkOpen();
    _access.requireControl();
    if (_approvals?.entries.any((entry) => entry['id'] == id) == true)
      _approvals!.revoke(id);
    final permission =
        _folderPermissions().where((entry) => entry['id'] == id).firstOrNull;
    if (permission != null)
      _backend.permissionStore.revoke(permission['source_id'] as String? ?? id,
          directory: permission['directory_value'] as String?);
    _scoped.reload();
  }

  @override
  ProviderDraft openDraft(SettingScope scope, {bool providerCatalog = false}) {
    _checkOpen();
    if (providerCatalog && scope != SettingScope.global)
      throw ArgumentError('Provider catalog is Global only');
    final revision = settings.snapshot(refresh: true).revision;
    late final _Edit edit;
    final document = providerCatalog
        ? ConfigDocument.open(_backend.globalPath)
        : _backend.draft(_scoped, scope,
            commit: (values, remove) => settings.update(scope,
                expectedRevision: edit.revision,
                values: values,
                remove: remove));
    settings.checkRevision(revision);
    final id = 'edit-${++_nextEdit}';
    edit = _Edit(document, revision, providerCatalog);
    _edits[id] = edit;
    final values = document.values;
    final providers = values['providers'] as Map? ?? const {};
    return ProviderDraft(
        id: id,
        revision: revision,
        exists: document.existsOnDisk,
        values: {
          'default': {
            for (final key in ['provider', 'model'])
              if ((values['default'] as Map?)?.containsKey(key) == true)
                key: (values['default'] as Map)[key],
          },
          'providers': {
            for (final entry in providers.entries)
              entry.key as String: {
                for (final key in _publicProviderFields)
                  if ((entry.value as Map).containsKey(key))
                    key: (entry.value as Map)[key],
              },
          },
        },
        secrets: [
          for (final entry in providers.entries)
            for (final key in _secretFields)
              if ((entry.value as Map)[key] is String &&
                  ((entry.value as Map)[key] as String).isNotEmpty)
                '${entry.key}/$key',
        ]);
  }

  _Edit _edit(ProviderDraft draft, {bool checkRevision = true}) {
    _checkOpen();
    final edit = _edits[draft.id];
    if (edit == null) throw StateError('Settings draft is closed');
    if (checkRevision) {
      if (draft.revision != edit.revision) throw const SettingsConflict();
      settings.checkRevision(edit.revision);
    }
    return edit;
  }

  ConfigDocument _candidate(ProviderDraft draft, _Edit edit) {
    if (draft.values.keys.any((key) => !['providers', 'default'].contains(key)))
      throw ArgumentError('Unknown settings draft field');
    final candidate = edit.document.fork();
    final current = candidate.table('providers');
    final next = draft.table('providers');
    current.removeWhere((id, _) => !next.containsKey(id));
    for (final entry in next.entries) {
      final fields = entry.value as Map;
      if (fields.keys.any((key) => !_publicProviderFields.contains(key)))
        throw ArgumentError('Unknown provider field');
      final target = current.putIfAbsent(entry.key, () => <String, dynamic>{})
          as Map<String, dynamic>;
      for (final key in _publicProviderFields) target.remove(key);
      target.addAll(
          (jsonDecode(jsonEncode(fields)) as Map).cast<String, dynamic>());
      for (final key in _secretFields) {
        final secret = draft.secret(entry.key, key);
        switch (secret.action) {
          case SecretAction.keep:
            break;
          case SecretAction.replace:
            target[key] = secret.value;
          case SecretAction.clear:
            target.remove(key);
        }
      }
    }
    for (final entry in draft.table('default').entries) {
      if (!['provider', 'model'].contains(entry.key))
        throw ArgumentError('Unknown default model field');
    }
    final defaults = candidate.table('default');
    for (final key in ['provider', 'model']) defaults.remove(key);
    defaults.addAll(draft.table('default'));
    return candidate;
  }

  @override
  void saveDraft(ProviderDraft draft) {
    _access.requireControl();
    final edit = _edit(draft);
    final candidate = _candidate(draft, edit);
    if (!edit.providerCatalog &&
        _canonical(candidate.values['providers'] ?? const {}) !=
            _canonical(edit.document.values['providers'] ?? const {})) {
      throw ArgumentError('Provider fields require a Global provider editor');
    }
    candidate.save(
        descriptors: _descriptors, validatePlugins: _validatePlugins);
    edit.document = candidate;
    refresh();
    draft.revision = edit.revision = settings.snapshot(refresh: true).revision;
  }

  @override
  void saveGeneration(
      ProviderDraft draft, String provider, Map<String, dynamic> fields) {
    _access.requireControl();
    final edit = _edit(draft);
    if (fields.keys.any((key) =>
        !['max_output', 'reasoning_effort', 'thinking_budget'].contains(key)))
      throw ArgumentError('Unknown generation field');
    final candidate = edit.document.fork();
    final values = candidate.table('providers').putIfAbsent(
        provider, () => <String, dynamic>{}) as Map<String, dynamic>;
    for (final key in ['max_output', 'reasoning_effort', 'thinking_budget'])
      values.remove(key);
    values.addAll(fields);
    final parsed =
        parseTinaConfig(candidate.values, descriptors: _descriptors).config;
    generationFor(parsed, provider, parsed.model);
    edit.document.saveGeneration(provider, fields,
        descriptors: _descriptors, validatePlugins: _validatePlugins);
    refresh();
    draft.acceptGeneration(provider, fields);
    draft.revision = edit.revision = settings.snapshot(refresh: true).revision;
  }

  @override
  GenerationForm generation(ProviderDraft draft, {String? provider}) {
    final edit = _edit(draft, checkRevision: false);
    final config = parseTinaConfig(_candidate(draft, edit).values,
            descriptors: _descriptors)
        .config;
    final id = provider ?? config.providerId ?? 'anthropic';
    final local = config.providers[id];
    final descriptor = descriptorByIdFor(id, config.descriptors);
    final model = config.model;
    final effort = local?.reasoningEffort ??
        (local?.thinkingBudget == null ? config.reasoningEffort : null);
    final budget = local?.reasoningEffort == null
        ? local?.thinkingBudget ?? config.thinkingBudget
        : null;
    final efforts = thinkingChoicesFor(model).toList();
    final labels = [
      for (final value in efforts)
        switch (value) {
          'auto' => 'Automatic',
          'none' => 'Off',
          _ => value[0].toUpperCase() + value.substring(1),
        }
    ];
    String? effective = effort;
    try {
      effective = generationFor(config, id, model).reasoningEffort;
    } on FormatException {
      /* Let the editor replace an unsupported legacy field. */
    }
    var selected = efforts.indexOf(effective ?? 'auto');
    if (selected < 0 &&
        effective != null &&
        !model.split('/').last.toLowerCase().startsWith('glm-')) {
      efforts.add(effective);
      labels.add(effective[0].toUpperCase() + effective.substring(1));
      selected = labels.length - 1;
    }
    if (selected < 0) selected = 0;
    if (budget != null && descriptor?.wire != ProviderWire.openAiCompatible) {
      if (budget == 0)
        selected = 1;
      else {
        efforts.add('budget');
        // Formatting belongs to the panel.
        labels.add('Custom');
        selected = labels.length - 1;
      }
    }
    return GenerationForm(
        provider: id,
        exists: draft.exists && descriptor != null,
        automaticOutput:
            descriptor?.models[model]?.maxOutput ?? config.maxOutputTokens,
        output: local?.maxOutput?.toString() ?? '',
        budget: budget,
        selected: selected,
        efforts: efforts,
        labels: labels,
        members:
            local?.members.map((m) => m.split('/').first).toSet() ?? const []);
  }

  @override
  void closeDraft(ProviderDraft draft) => _edits.remove(draft.id);
  @override
  void refresh() {
    _checkOpen();
    _access.requireControl();
    _applyConfiguration?.call();
    _scoped.reload();
    refreshProviderDefinitions(
        _scoped.catalog,
        ConfigDocument.validateValues(_backend.effectiveDocument(),
            descriptors: _descriptors));
    _scoped.reload();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final release in _releases.toList()) release();
    _edits.clear();
    settings.close();
  }
}
