/// Session lifecycle and plugin mounting. Storage and feature policy belong
/// to plugins selected by the application assembly.
library;

import 'dart:async';
import 'dart:math';
import 'package:tina_engine_2/tina_engine_2.dart';

import 'commands.dart';
import 'host_config.dart';
import 'session.dart';
import 'session_questions.dart';
import 'snapshot_feature.dart';

part 'session_connection.dart';
part 'session_attachment.dart';

final class Host {
  Host._(this.config, this.session, this.context, this.commands, this._plugins,
      this.questions) {
    _releaseQuestions = questions.listen(_changed);
    _statusSubscription = session.loop.subscribe((entry, event) {
      if (event != LogEvent.appended) return;
      if (entry is TurnStartedEntry) {
        _turnWork = SessionWork('work-${++_nextWork}', 'turn');
        final scope = _turnQuestions = questions.currentScope;
        if (scope != null) {
          unawaited(session.loop.whenCancelled.then((_) => scope.cancel()));
        }
      }
      if (entry is TurnEndedEntry) {
        _turnWork = null;
        _turnQuestions = null;
      }
      _changed();
    });
    _toolObservation = session.loop.toolActivity.listen(_observeTool);
    for (final plugin in _plugins) _observeFeature(plugin);
  }

  final HostConfig config;
  final Session session;
  final PluginSession context;
  final Commands commands;
  final SessionQuestions questions;
  late final void Function() _releaseQuestions;
  final List<AgentPlugin> _plugins;
  bool _closed = false;
  bool _stopping = false;
  Future<void>? _shutdown;
  late final int _statusSubscription;
  int _nextWork = 0;
  SessionWork? _turnWork;
  QuestionScope? _turnQuestions;
  final _commandWork = <String, Command>{};
  final _commandQuestions = <String, QuestionScope>{};
  final _pendingWork = <Completer<void>>{};
  final _connections = <SessionConnection>{};
  bool _notificationQueued = false;
  final _epoch = List.generate(16,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
  int _snapshotRevision = 0;
  SessionSnapshot? _lastSnapshot;
  final _features = <String, _FeatureObservation>{};
  final _featureFailures = <String>{};
  final _activeTools = <String, Object?>{};
  late final StreamSubscription<ToolActivity> _toolObservation;
  bool _capturing = false;

  void _observeFeature(AgentPlugin plugin) {
    try {
      final source = config.snapshotFeatureFor?.call(plugin);
      if (source == null) return;
      final release = source.listen?.call(_changed) ?? () {};
      _features[plugin.id] = _FeatureObservation(source, release);
      _featureFailures.remove(plugin.id);
    } catch (_) {
      _featureFailures.add(plugin.id);
    }
  }

  void _forgetFeature(String id) {
    final feature = _features.remove(id);
    _featureFailures.remove(id);
    try {
      feature?.release();
    } catch (_) {/* Observation cleanup cannot break plugin ownership. */}
  }

  void _observeTool(ToolActivity event) {
    final id = event.call.id;
    if (event is ToolFinished) {
      _activeTools.remove(id);
    } else {
      final state =
          Map<String, Object?>.of(_activeTools[id] as Map<String, Object?>? ??
              {
                'id': id,
                'name': event.call.name,
                'input': freezeSnapshotValue(event.call.input),
                'output': '',
                'output_truncated': false,
              });
      if (event is ToolProgress) state['status'] = event.status;
      if (event is ToolOutput) {
        final text = '${state['output']}${event.text}';
        const limit = 65536;
        state['output'] =
            text.length <= limit ? text : text.substring(0, limit);
        if (text.length > limit) state['output_truncated'] = true;
      }
      _activeTools[id] = state;
    }
    _changed();
  }

  SessionStatus _status() => SessionStatus(
          id: session.id,
          model: model,
          workingDirectory: config.workingDirectory,
          running: session.loop.running,
          pendingInputCount: session.loop.pendingInputCount,
          stopping: _stopping,
          closed: _closed,
          cancellableWork: [
            if (_turnWork case final work?) work,
            for (final entry in _commandWork.entries)
              if (entry.value.cancel != null ||
                  _commandQuestions[entry.key]?.hasPending == true)
                SessionWork(entry.key, 'command', command: entry.value.name),
          ]);

  /// Re-read public projections after application configuration changes that
  /// do not append a log entry. No client callbacks run in this call.
  void refreshSnapshot() => _changed();

  SessionSnapshot _captureSnapshot() {
    if (_capturing || session.loop.publishing) {
      throw StateError(
          'Cannot attach or capture during synchronous publication');
    }
    if (_closed && _lastSnapshot?.status.closed == true) return _lastSnapshot!;
    _capturing = true;
    try {
      final features = <String, Object?>{};
      final unavailable = <String>{..._featureFailures};
      for (final entry in _features.entries.toList()) {
        try {
          features[entry.key] = freezeSnapshotValue(entry.value.source.read());
        } catch (_) {
          unavailable.add(entry.key);
        }
      }
      return _lastSnapshot = SessionSnapshot._(
          SessionCursor(_epoch, ++_snapshotRevision),
          _status(),
          session.loop.publishedSeq,
          session.loop.publicationFailed,
          session.loop.pendingInputs,
          [
            if (_turnWork case final work?) work,
            for (final entry in _commandWork.entries)
              SessionWork(entry.key, 'command', command: entry.value.name),
          ],
          questions.pending,
          _plugins.map((p) => p.id),
          features,
          unavailable,
          _activeTools);
    } finally {
      _capturing = false;
    }
  }

  void _publishSnapshots() {
    final clients = [for (final c in _connections) ...c._attachments];
    if (clients.isEmpty) return;
    final snapshot = _captureSnapshot();
    for (final client in clients) client._offer(snapshot);
  }

  /// A disposable client capability; its lifetime never owns this host.
  SessionConnection connect() {
    _checkOpen();
    final connection = SessionConnection._(this);
    _connections.add(connection);
    return connection;
  }

  void _checkOpen() {
    if (_closed || _stopping) throw StateError('host is closed or stopping');
  }

  void _changed() {
    if (_notificationQueued) return;
    _notificationQueued = true;
    // UI callbacks run outside the loop's synchronous persistence callbacks.
    scheduleMicrotask(() {
      _notificationQueued = false;
      _publishSnapshots();
      for (final connection in _connections.toList()) connection._notify();
    });
  }

  List<AgentPlugin> get plugins => List.unmodifiable(_plugins);
  void Function()? onIdle;

  void _checkIdle() {
    _checkOpen();
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
      commands.validate(declared);
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
      _observeFeature(plugin);
      _plugins.sort((a, b) => a.order != b.order
          ? a.order.compareTo(b.order)
          : a.id.compareTo(b.id));
      _changed();
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
    _forgetFeature(id);
    Object? failure;
    try {
      deactivate?.call(plugin);
    } catch (e) {
      failure = e;
    }
    commands.removeOwner(id);
    session.loop.removePlugin(id);
    _plugins.remove(plugin);
    _changed();
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
    final questions = config.questions ?? SessionQuestions();
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
          plugins,
          questions);
    } catch (_) {
      questions.close();
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

  bool offerInput(String text) {
    if (_closed || _stopping) return false;
    final accepted = session.loop.offerInput(
        Input(text, id: 't-${session.loop.seq}-input-${++_nextInput}'));
    if (accepted) _changed();
    return accepted;
  }

  void switchModel(String model) {
    _checkIdle();
    if (model == this.model) return;
    final provider = config.providerFactory(model);
    session.loop.replaceProvider(provider);
    context.model = model;
    context.notifyChanged();
    _changed();
  }

  Future<Outcome> send(String text, {String? turnId}) async {
    _checkOpen();
    if (session.loop.running) throw StateError('a turn is already running');
    final settled = Completer<void>();
    _pendingWork.add(settled);
    try {
      final outcome = await session.loop.runTurn(
          Input(text, id: turnId ?? 't-${session.loop.seq}'),
          onOutcome: session.turns.add, withTurnScope: (run) async {
        final scope = questions.openScope();
        try {
          return await scope.run(run);
        } finally {
          scope.cancel();
        }
      });
      context.notifyChanged();
      if (!_stopping) onIdle?.call();
      return outcome;
    } finally {
      _turnWork = null;
      _turnQuestions = null;
      _pendingWork.remove(settled);
      settled.complete();
      _changed();
    }
  }

  /// Owner-only shutdown. Reject new work, cancel current work, let its final
  /// log entries persist, then release plugins and the provider exactly once.
  Future<void> shutdown() {
    if (_shutdown case final pending?) return pending;
    final settled = Completer<void>();
    // Publish the shared future before calling any plugin cancellation hook,
    // which may itself request shutdown.
    _shutdown = settled.future;
    settled.complete(_stop());
    return settled.future;
  }

  Future<void> _stop() async {
    if (_closed) return;
    _stopping = true;
    _changed();
    Object? failure;
    StackTrace? trace;
    void attempt(void Function() action) {
      try {
        action();
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
    }

    try {
      // Settle questions before awaiting work which may be parked on an answer.
      questions.close();
      attempt(() => session.loop.cancel('shutdown'));
      for (final command in _commandWork.values.toSet())
        attempt(() => command.cancel?.call());
      await Future.wait([for (final pending in _pendingWork) pending.future]);
    } finally {
      attempt(close);
    }
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  }

  /// Notify plugins when callers change session counters outside a turn.
  void saveDetails() {
    if (_closed) throw StateError('host is closed');
    context.notifyChanged();
  }

  void close() {
    if (_closed) return;
    if (_pendingWork.isNotEmpty || session.loop.running) {
      throw StateError('active host work requires asynchronous shutdown');
    }
    _closed = true;
    questions.close();
    _publishSnapshots();
    unawaited(_toolObservation.cancel());
    for (final id in _features.keys.toList()) _forgetFeature(id);
    _releaseQuestions();
    session.loop.unsubscribe(_statusSubscription);
    _changed();
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
