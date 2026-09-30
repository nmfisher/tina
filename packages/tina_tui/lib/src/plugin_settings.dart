import 'dart:io';
import 'package:tina_host/tina_host.dart';
import 'package:tina_llm/tina_llm.dart';
import 'assembly_config.dart';
import 'config_document.dart';

enum PluginScope { session, workspace, global }

/// Per-ID precedence: session, workspace, global, built-in defaults. Global
/// `enabled` remains a replacement baseline; overrides never copy that list.
final class PluginSettings<C> {
  PluginSettings(
      {required this.globalPath,
      required this.workspacePath,
      required this.registry,
      this.descriptors = builtinDescriptors,
      this.sessionBaseline,
      this.channelOverride}) {
    reload();
  }
  final String globalPath;
  final String workspacePath;
  final PluginRegistry<C> registry;
  final List<ProviderDescriptor> descriptors;
  final List<String>? sessionBaseline;
  final String? channelOverride;
  final _session = <String, bool>{};
  late ConfigDocument _global;
  late ConfigDocument _workspace;

  bool get _sameFile {
    String canonical(String path) {
      final file = File(path);
      return file.existsSync()
          ? file.resolveSymbolicLinksSync()
          : file.absolute.path;
    }

    return canonical(globalPath) == canonical(workspacePath);
  }

  void reload() {
    final global = ConfigDocument.open(globalPath);
    final workspace = _sameFile
        ? ConfigDocument.empty(workspacePath)
        : ConfigDocument.open(workspacePath, workspace: true);
    _validate(global, workspace, _session);
    _global = global;
    _workspace = workspace;
  }

  String _channel(ConfigDocument global, ConfigDocument workspace) =>
      channelOverride ??
      ((workspace.values['plugins'] as Map?)?['approval_channel'] as String?) ??
      ((global.values['plugins'] as Map?)?['approval_channel'] as String?) ??
      defaultApprovalChannel;
  String get channel => _channel(_global, _workspace);
  Map<String, List<String>> get blockingReasons => {
        ...registry.blockingReasons(selected),
        channel: ['Selected approval delivery role'],
      };
  Set<String> get requiredIds => blockingReasons.keys.toSet();

  ({bool enabled, String source}) _state(String id, ConfigDocument global,
      ConfigDocument workspace, Map<String, bool> session,
      {PluginScope scope = PluginScope.session}) {
    if (scope == PluginScope.session && session.containsKey(id))
      return (enabled: session[id]!, source: 'session');
    if (scope == PluginScope.session && sessionBaseline != null)
      return (
        enabled: pluginBaseline(sessionBaseline!).contains(id),
        source: 'session'
      );
    final local = parsePluginOverrides(workspace.values['plugins']);
    if (scope != PluginScope.global && local.containsKey(id))
      return (enabled: local[id]!, source: 'workspace');
    final overrides = parsePluginOverrides(global.values['plugins']);
    if (overrides.containsKey(id))
      return (enabled: overrides[id]!, source: 'global');
    final baseline = (global.values['plugins'] as Map?)?['enabled'] as List?;
    if (baseline != null)
      return (
        enabled: pluginBaseline(baseline.cast<String>(),
                selectionVersion: (global.values['plugins']
                        as Map?)?['selection_version'] as int? ??
                    1)
            .contains(id),
        source: 'global'
      );
    return (enabled: defaultPluginIds.contains(id), source: 'built-in');
  }

  ({bool enabled, String source}) state(String id) => requiredIds.contains(id)
      ? (enabled: true, source: 'required')
      : _state(id, _global, _workspace, _session);

  ({bool enabled, String source}) scopedState(String id, PluginScope scope) =>
      requiredIds.contains(id)
          ? (enabled: true, source: 'required')
          : _state(id, _global, _workspace, _session, scope: scope);

  void apply(
      String id, bool? enabled, PluginScope scope, PluginManager<C> manager) {
    change(id, enabled, scope);
    manager.select(selected);
  }

  String status(String id, PluginManager<C> manager) =>
      _row(id, manager.host.plugins.any((p) => p.id == id), manager);

  List<String> _selection(ConfigDocument global, ConfigDocument workspace,
          Map<String, bool> session,
          {PluginScope scope = PluginScope.session}) =>
      [
        ...{
          _channel(global, workspace),
          for (final id in registry.ids)
            if (_state(id, global, workspace, session, scope: scope).enabled) id
        },
      ];
  List<String> get selected => _selection(_global, _workspace, _session);
  List<String> get features => selected;

  void _validate(ConfigDocument global, ConfigDocument workspace,
      Map<String, bool> session) {
    global.validate(descriptors: descriptors);
    validateWorkspacePlugins(workspace.values);
    for (final layer in [
      parsePluginOverrides(global.values['plugins']),
      parsePluginOverrides(workspace.values['plugins']),
      session
    ]) {
      for (final id in layer.keys) {
        if (retiredPluginIds.contains(id))
          continue; // Retired UI-only registration.
        if (!registry.ids.contains(id))
          throw ArgumentError('unknown plugin: $id');
        if (id == _channel(global, workspace) && layer[id] == false)
          throw ArgumentError('$id is the selected approval channel');
      }
    }
    if (sessionBaseline != null &&
        sessionBaseline!.toSet().length != sessionBaseline!.length) {
      throw ArgumentError('duplicate plugin ID in session selection');
    }
    // Check even disabled/masked baseline entries, so typos cannot hide in config.
    for (final id in [
      ...?((global.values['plugins'] as Map?)?['enabled'] as List?),
      ...?sessionBaseline
    ]) {
      if (retiredPluginIds.contains(id)) continue;
      if (!registry.ids.contains(id))
        throw ArgumentError('unknown plugin: $id');
    }
    final emptyWorkspace = ConfigDocument.empty(workspace.path);
    registry.validate(_selection(global, emptyWorkspace, const {},
        scope: PluginScope.global));
    registry.validate(
        _selection(global, workspace, const {}, scope: PluginScope.workspace));
    registry.validate(_selection(global, workspace, session));
  }

  /// Validate first, then persist only the requested scope. Stale-file checks
  /// and atomic writes are shared with /settings. Null removes an override.
  void change(String id, bool? enabled, PluginScope scope) {
    reload();
    if (requiredIds.contains(id))
      throw ArgumentError('$id: ${blockingReasons[id]!.join('; ')}');
    if (!registry.ids.contains(id)) throw ArgumentError('unknown plugin: $id');
    final global = _global.fork(), workspace = _workspace.fork();
    final session = Map<String, bool>.of(_session);
    if (scope == PluginScope.session) {
      if (enabled == null) {
        session.remove(id);
      } else {
        session[id] = enabled;
      }
    } else {
      if (scope == PluginScope.workspace && _sameFile) {
        throw StateError(
            '--config points at the workspace file; use Global scope for that explicit config or choose a separate global file');
      }
      final document = scope == PluginScope.global ? global : workspace;
      final table = document.table('plugins');
      if (scope == PluginScope.global && table['selection_version'] != 2) {
        table['enabled'] = pluginBaseline(
            (table['enabled'] as List?)?.cast<String>() ?? defaultPluginIds);
        table['selection_version'] = 2;
      }
      final overrides =
          Map<String, dynamic>.from(table['overrides'] as Map? ?? {});
      if (enabled == null) {
        overrides.remove(id);
      } else {
        overrides[id] = enabled;
      }
      if (overrides.isEmpty) {
        table.remove('overrides');
      } else {
        table['overrides'] = overrides;
      }
    }
    _validate(global, workspace, session);
    if (scope == PluginScope.global) {
      global.save(descriptors: descriptors);
    } else if (scope == PluginScope.workspace) {
      workspace.saveWorkspace(
          validateSelection: () => _validate(global, workspace, session));
    }
    _global = global;
    _workspace = workspace;
    _session
      ..clear()
      ..addAll(session);
  }

  String describe(PluginManager<C> manager) {
    final loaded = manager.host.plugins.map((p) => p.id).toSet();
    final ids = {...registry.ids, ...requiredIds}.toList()..sort();
    final lines = <String>[
      'Plugin | configured | loaded | source | change',
      for (final id in ids) _row(id, loaded.contains(id), manager),
      'Global: $globalPath',
      'Workspace: $workspacePath',
      'Settings defaults to Global scope. Restore inheritance removes an override.',
      if (manager.lastError != null) manager.lastError!,
    ];
    return lines.join('\n');
  }

  String _row(String id, bool loaded, PluginManager<C> manager) {
    final resolved = state(id);
    final change = changeStatus(id, manager);
    return '$id | ${resolved.enabled ? 'enabled' : 'disabled'} | ${loaded ? 'yes' : 'no'} | ${resolved.source} | $change';
  }

  String changeStatus(String id, PluginManager<C> manager) {
    final loaded = manager.host.plugins.any((plugin) => plugin.id == id);
    final pending = state(id).enabled != loaded;
    final policy = requiredIds.contains(id)
        ? 'required'
        : registry.definition(id).live
            ? 'live'
            : 'restart required';
    return !pending
        ? policy
        : manager.waitingForIdle
            ? 'pending until idle'
            : registry.ids.contains(id) && registry.definition(id).live
                ? 'pending; live update not applied'
                : 'pending restart';
  }
}
