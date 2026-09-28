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
  Set<String> get requiredIds => {
        'tina/providers',
        'tina/persona',
        'tina/mode',
        'tina/tools',
        'tina/approvals',
        channel
      };

  ({bool enabled, String source}) _state(String id, ConfigDocument global,
      ConfigDocument workspace, Map<String, bool> session) {
    if (session.containsKey(id))
      return (enabled: session[id]!, source: 'session');
    if (sessionBaseline != null)
      return (enabled: sessionBaseline!.contains(id), source: 'session');
    final local = parsePluginOverrides(workspace.values['plugins']);
    if (local.containsKey(id))
      return (enabled: local[id]!, source: 'workspace');
    final overrides = parsePluginOverrides(global.values['plugins']);
    if (overrides.containsKey(id))
      return (enabled: overrides[id]!, source: 'global');
    final baseline = (global.values['plugins'] as Map?)?['enabled'] as List?;
    if (baseline != null)
      return (enabled: baseline.contains(id), source: 'global');
    return (enabled: defaultPluginIds.contains(id), source: 'built-in');
  }

  ({bool enabled, String source}) state(String id) => requiredIds.contains(id)
      ? (enabled: true, source: 'required')
      : _state(id, _global, _workspace, _session);

  List<String> _selection(ConfigDocument global, ConfigDocument workspace,
          Map<String, bool> session) =>
      [
        'tina/approvals',
        _channel(global, workspace),
        'tina/tools',
        for (final id in registry.ids)
          if (_state(id, global, workspace, session).enabled) id,
      ];
  List<String> get selected => _selection(_global, _workspace, _session);
  List<String> get features => selected.skip(3).toList();

  void _validate(ConfigDocument global, ConfigDocument workspace,
      Map<String, bool> session) {
    global.validate(descriptors: descriptors);
    validateWorkspacePlugins(workspace.values);
    final fixed = {
      'tina/providers',
      'tina/persona',
      'tina/mode',
      'tina/tools',
      'tina/approvals',
      _channel(global, workspace)
    };
    for (final layer in [
      parsePluginOverrides(global.values['plugins']),
      parsePluginOverrides(workspace.values['plugins']),
      session
    ]) {
      for (final id in layer.keys) {
        if (!registry.ids.contains(id) && !fixed.contains(id))
          throw ArgumentError('unknown plugin: $id');
        if (fixed.contains(id))
          throw ArgumentError(
              '$id is required; its enablement cannot be overridden');
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
      if (!registry.ids.contains(id))
        throw ArgumentError('unknown plugin: $id');
    }
    registry.validate(_selection(global, workspace, session));
  }

  /// Validate first, then persist only the requested scope. Stale-file checks
  /// and atomic writes are shared with /settings. Null removes an override.
  void change(String id, bool? enabled, PluginScope scope) {
    reload();
    if (requiredIds.contains(id))
      throw ArgumentError(
          '$id is required and cannot be disabled or enabled separately');
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
            '--config points at the workspace file; use --global for that explicit config or choose a separate global file');
      }
      final document = scope == PluginScope.global ? global : workspace;
      final table = document.table('plugins');
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
      'Default scope: session. reset removes an override and restores inheritance.',
      if (manager.lastError != null) manager.lastError!,
    ];
    return lines.join('\n');
  }

  String _row(String id, bool loaded, PluginManager<C> manager) {
    final resolved = state(id);
    final pending = resolved.enabled != loaded;
    final policy = requiredIds.contains(id)
        ? 'required'
        : registry.definition(id).live
            ? 'live'
            : 'restart required';
    final change = !pending
        ? policy
        : manager.waitingForIdle
            ? 'pending until idle'
            : registry.ids.contains(id) && registry.definition(id).live
                ? 'pending; live update not applied'
                : 'pending restart';
    return '$id | ${resolved.enabled ? 'enabled' : 'disabled'} | ${loaded ? 'yes' : 'no'} | ${resolved.source} | $change';
  }

  void command(
      String argument, PluginManager<C> manager, void Function(String) write) {
    try {
      final parts = argument.trim().isEmpty
          ? <String>[]
          : argument.trim().split(RegExp(r'\s+'));
      if (parts.isEmpty || (parts.length == 1 && parts.single == 'list')) {
        reload();
        write(describe(manager));
        return;
      }
      if (parts.length < 2 ||
          parts.length > 3 ||
          !['enable', 'disable', 'reset'].contains(parts[0])) {
        throw ArgumentError(
            'usage: /plugins [enable|disable|reset ID [--session|--workspace|--global]]');
      }
      final flag = parts.length == 3 ? parts[2] : '--session';
      final scope = switch (flag) {
        '--session' => PluginScope.session,
        '--workspace' => PluginScope.workspace,
        '--global' => PluginScope.global,
        _ => throw ArgumentError('unknown scope: $flag'),
      };
      change(
          parts[1], parts[0] == 'reset' ? null : parts[0] == 'enable', scope);
      manager.select(selected);
      write(
          '${scope.name} override ${parts[0] == 'reset' ? 'removed' : 'updated'} for ${parts[1]}.');
      write(_row(parts[1], manager.host.plugins.any((p) => p.id == parts[1]),
          manager));
      if (manager.lastError != null) write(manager.lastError!);
    } on ArgumentError catch (e) {
      write('Plugins: ${e.message}');
    } on FormatException catch (e) {
      write('Plugins: ${e.message}');
    } on FileSystemException {
      write('Plugins: could not read or save plugin configuration.');
    } on StateError catch (e) {
      write('Plugins: ${e.message}');
    }
  }
}

/// Complete the plugin command from the same registry used for validation.
List<String> completePlugins(String argument, Iterable<String> ids) {
  final words = argument.split(' ');
  if (words.length == 1)
    return ['list', 'enable', 'disable', 'reset']
        .where((v) => v.startsWith(argument))
        .toList();
  if (!['enable', 'disable', 'reset'].contains(words.first)) return [];
  final prefix = words.last;
  final before = words.take(words.length - 1).join(' ');
  final choices =
      words.length == 2 ? ids : ['--session', '--workspace', '--global'];
  return [
    for (final value in choices)
      if (value.startsWith(prefix)) '$before $value'
  ];
}
