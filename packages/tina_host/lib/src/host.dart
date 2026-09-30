/// Session lifecycle and plugin mounting. Storage and feature policy belong
/// to plugins selected by the application assembly.
library;

import 'package:tina_engine_2/tina_engine_2.dart';

import 'commands.dart';
import 'host_config.dart';
import 'session.dart';

final class Host {
  Host._(this.config, this.session, this.context, this.commands, this._plugins);

  final HostConfig config;
  final Session session;
  final PluginSession context;
  final Commands commands;
  final List<AgentPlugin> _plugins;
  bool _closed = false;
  List<AgentPlugin> get plugins => List.unmodifiable(_plugins);
  void Function()? onIdle;

  void _checkIdle() {
    if (_closed) throw StateError('host is closed');
    if (session.loop.running)
      throw StateError('plugin changes require an idle session');
  }

  /// Caller validates capability dependencies before changing the graph.
  void attachPlugin(AgentPlugin plugin,
      {void Function(AgentPlugin)? activate}) {
    _checkIdle();
    if (_plugins.any((p) => p.id == plugin.id))
      throw StateError('plugin already loaded: ${plugin.id}');
    var addedToLoop = false;
    try {
      final declared = plugin.commands;
      final names = <String>{};
      for (final command in declared) {
        if (commands[command.name] != null || !names.add(command.name)) {
          throw StateError('command "${command.name}" is already published');
        }
      }
      final seed = plugin.openSession(context);
      if (seed != null)
        throw StateError('history restoration requires a new session');
      session.loop.addPlugin(plugin);
      addedToLoop = true;
      session.loop.mountPlugin(plugin);
      for (final command in declared) {
        commands.publish(command, owner: plugin.id);
      }
      activate?.call(plugin);
      _plugins.add(plugin);
      _plugins.sort((a, b) => a.order != b.order
          ? a.order.compareTo(b.order)
          : a.id.compareTo(b.id));
    } catch (_) {
      commands.removeOwner(plugin.id);
      if (addedToLoop) session.loop.removePlugin(plugin.id);
      try {
        plugin.closeSession();
      } catch (_) {/* Preserve activation error. */}
      rethrow;
    }
  }

  void detachPlugin(String id, {void Function(AgentPlugin)? deactivate}) {
    _checkIdle();
    final matches = _plugins.where((plugin) => plugin.id == id);
    if (matches.isEmpty) return;
    final plugin = matches.single;
    Object? failure;
    try {
      deactivate?.call(plugin);
    } catch (e) {
      failure = e;
    }
    commands.removeOwner(id);
    session.loop.removePlugin(id);
    _plugins.remove(plugin);
    try {
      plugin.closeSession();
    } catch (e) {
      failure ??= e;
    }
    if (failure != null)
      throw StateError('plugin $id detached with cleanup failure: $failure');
  }

  static Host child({
    required int depth,
    required List<AgentPlugin> plugins,
    required String workingDirectory,
    required ProviderFactory providerFactory,
    String model = 'scripted',
    String? sessionId,
  }) =>
      start(
          HostConfig(
            providerFactory: providerFactory,
            model: model,
            workingDirectory: workingDirectory,
            plugins: plugins,
            details: SessionDetails(depth: depth),
          ),
          sessionId:
              sessionId ?? 's-${DateTime.now().microsecondsSinceEpoch}-child');

  static Host start(HostConfig config, {String? sessionId}) => _open(
      config, sessionId ?? 's-${DateTime.now().microsecondsSinceEpoch}', false);

  static Host resume(HostConfig config, String sessionId) =>
      _open(config, sessionId, true);

  static Host _open(HostConfig config, String id, bool resuming) {
    // Validate declarations before opening any resources.
    final commands = Commands();
    final ids = <String>{};
    for (final plugin in config.plugins) {
      validatePluginId(plugin.id);
      if (!ids.add(plugin.id))
        throw ArgumentError('duplicate plugin id: ${plugin.id}');
      for (final command in plugin.commands) {
        commands.publish(command, owner: plugin.id);
      }
    }
    final plugins = List<AgentPlugin>.of(config.plugins)
      ..sort((a, b) => a.order != b.order
          ? a.order.compareTo(b.order)
          : a.id.compareTo(b.id));
    late final PluginSession context;
    context = PluginSession(
      id: id,
      workingDirectory: config.workingDirectory,
      title: config.sessionTitle,
      model: config.model,
      resuming: resuming,
      details: config.details,
      notifyChanged: () {
        for (final plugin in plugins) {
          plugin.sessionChanged(context);
        }
      },
    );
    final opened = <AgentPlugin>[];
    LlmProvider? provider;
    try {
      SessionSeed? seed;
      for (final plugin in plugins) {
        opened.add(plugin); // Close even if opening partially succeeds.
        final restored = plugin.openSession(context);
        if (restored != null) {
          if (seed != null)
            throw StateError('multiple plugins supplied session history');
          seed = restored;
          context.details = restored.details;
          if (config.restoreModel && restored.model != null) {
            context.model = restored.model;
          }
        }
      }
      if (resuming && seed == null) {
        throw StateError('no loaded plugin restored session $id');
      }
      provider = config.providerFactory(context.model!);
      final loop = AgentLoop(
        provider: provider,
        plugins: plugins,
        settings: SessionSettings(systemPrompt: config.systemPrompt),
        seedLog: seed?.log ?? const [],
      );
      for (final plugin in plugins) {
        loop.mountPlugin(plugin);
      }
      return Host._(
          config,
          Session(id: id, loop: loop, details: context.details),
          context,
          commands,
          plugins);
    } catch (_) {
      for (final plugin in opened.reversed) {
        try {
          plugin.closeSession();
        } catch (_) {/* Preserve opening error. */}
      }
      try {
        provider?.close();
      } catch (_) {/* Preserve opening error. */}
      rethrow;
    }
  }

  String get model => context.model!;
  int _nextInput = 0;

  bool offerInput(String text) =>
      !_closed &&
      session.loop.offerInput(
          Input(text, id: 't-${session.loop.seq}-input-${++_nextInput}'));

  void switchModel(String model) {
    _checkIdle();
    if (model == this.model) return;
    final provider = config.providerFactory(model);
    session.loop.replaceProvider(provider);
    context.model = model;
    context.notifyChanged();
  }

  Future<Outcome> send(String text, {String? turnId}) async {
    if (_closed) throw StateError('host is closed');
    final outcome = await session.loop.runTurn(
        Input(text, id: turnId ?? 't-${session.loop.seq}'),
        onOutcome: session.turns.add);
    context.notifyChanged();
    onIdle?.call();
    return outcome;
  }

  /// Notify plugins when callers change session counters outside a turn.
  void saveDetails() {
    if (_closed) throw StateError('host is closed');
    context.notifyChanged();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    onIdle = null;
    Object? failure;
    StackTrace? trace;
    void attempt(void Function() action) {
      try {
        action();
      } catch (e, st) {
        failure ??= e;
        trace ??= st;
      }
    }

    attempt(context.notifyChanged);
    for (final plugin in _plugins.reversed) {
      attempt(() => session.loop.removePlugin(plugin.id));
      attempt(plugin.closeSession);
    }
    attempt(session.loop.provider.close);
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  }
}
