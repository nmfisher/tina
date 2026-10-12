part of 'host.dart';

/// Immutable command vocabulary. Handlers, registry mutation and cancellation
/// callbacks remain private to the host.
final class SessionCommand {
  const SessionCommand(this.name, this.description,
      {this.allowWhileRunning = false, this.inputPrefix});
  final String name, description;
  final bool allowWhileRunning;
  final String? inputPrefix;
}

final class SessionCommandCall {
  const SessionCommandCall(this.command, this.argument);
  final SessionCommand command;
  final String argument;
}

/// A cancellation target allocated by the host. A new turn or command gets a
/// new ID, including a steered turn inside the same send operation.
final class SessionWork {
  const SessionWork(this.id, this.kind, {this.command});
  final String id, kind;
  final String? command;
}

final class SessionStatus {
  SessionStatus(
      {required this.id,
      required this.model,
      required this.workingDirectory,
      required this.running,
      required this.pendingInputCount,
      required this.stopping,
      required this.closed,
      required Iterable<SessionWork> cancellableWork})
      : cancellableWork = List.unmodifiable(cancellableWork);
  final String id, model, workingDirectory;
  final bool running, stopping, closed;
  final int pendingInputCount;
  final List<SessionWork> cancellableWork;
  bool get canCancel => cancellableWork.isNotEmpty;
}

/// Result of submitted input; feature command output uses its existing notice
/// channel. No loop, provider or mutable transcript crosses this boundary.
final class SessionResult {
  const SessionResult({this.stopReason, this.detail = ''});
  final StopReason? stopReason;
  final String detail;
  String? get notice =>
      detail.isNotEmpty && stopReason != StopReason.complete ? detail : null;
}

/// Concrete in-process client connection. Closing it removes only its own
/// observers. It cannot close the host, mutate a registry or obtain a plugin.
final class SessionConnection {
  SessionConnection._(this._host);
  final Host _host;
  bool _closed = false;
  QuestionClient? _questions;
  QuestionClient get questions {
    _checkOpen();
    return _questions ??= _host.questions.connect();
  }

  final _listeners = <Object, void Function(SessionStatus)>{};

  void _checkOpen() {
    if (_closed) throw StateError('session connection is closed');
  }

  SessionStatus get status {
    _checkOpen();
    final host = _host;
    return SessionStatus(
      id: host.session.id,
      model: host.model,
      workingDirectory: host.config.workingDirectory,
      running: host.session.loop.running,
      pendingInputCount: host.session.loop.pendingInputCount,
      stopping: host._stopping,
      closed: host._closed,
      cancellableWork: [
        if (host._turnWork case final work?) work,
        for (final entry in host._commandWork.entries)
          if (entry.value.cancel != null ||
              _host._commandQuestions[entry.key]?.hasPending == true)
            SessionWork(entry.key, 'command', command: entry.value.name),
      ],
    );
  }

  List<String> get inputHistory {
    _checkOpen();
    final log = _host.session.loop.log;
    final recorded =
        log.whereType<InputRecordedEntry>().map((e) => e.turnId).toSet();
    return List.unmodifiable([
      for (final entry in log)
        if (entry is InputRecordedEntry && entry.text.isNotEmpty)
          entry.text
        else if (entry is MessageAppendedEntry &&
            entry.message.role == Role.user &&
            !recorded.contains(entry.turnId))
          for (final block in entry.message.content.whereType<TextBlock>())
            if (block.text.isNotEmpty) block.text,
    ]);
  }

  SessionCommand _describe(Command command) =>
      SessionCommand(command.name, command.description,
          allowWhileRunning: command.allowWhileRunning,
          inputPrefix: command.inputPrefix);

  List<SessionCommand> get commands {
    _checkOpen();
    return List.unmodifiable(_host.commands.all.map(_describe));
  }

  ({Command command, String argument})? _commandFor(String line) {
    final trimmed = line.trim();
    final prefixed = _host.commands.matchPrefix(trimmed);
    if (prefixed != null) return prefixed;
    if (!trimmed.startsWith('/')) return null;
    final rest = trimmed.substring(1);
    final split = RegExp(r'\s').firstMatch(rest);
    final name = split == null ? rest : rest.substring(0, split.start);
    final command = _host.commands[name];
    if (command == null) return null;
    return (
      command: command,
      argument: split == null ? '' : rest.substring(split.end).trim()
    );
  }

  SessionCommandCall? commandFor(String line) {
    _checkOpen();
    final call = _commandFor(line);
    return call == null
        ? null
        : SessionCommandCall(_describe(call.command), call.argument);
  }

  Future<List<String>> completeCommand(String name, String prefix) async {
    _checkOpen();
    _host._checkOpen();
    final complete = _host.commands[name]?.complete;
    if (complete == null) return const [];
    final settled = Completer<void>();
    _host._pendingWork.add(settled);
    try {
      return List.unmodifiable(await complete(prefix));
    } finally {
      _host._pendingWork.remove(settled);
      settled.complete();
    }
  }

  Future<SessionResult> submit(String line) async {
    _checkOpen();
    _host._checkOpen();
    final trimmed = line.trim();
    final call = _commandFor(trimmed);
    if (call != null) {
      if (_host.session.loop.running && !call.command.allowWhileRunning)
        throw StateError('command requires an idle session');
      return _runCommand(call.command, call.argument);
    }
    if (trimmed.startsWith('/')) {
      return SessionResult(
          detail:
              'unknown command: /${trimmed.substring(1).split(RegExp(r'\s')).first}');
    }
    if (trimmed.isEmpty) return const SessionResult();
    final result = await _host.send(trimmed);
    return SessionResult(stopReason: result.stopReason, detail: result.detail);
  }

  /// Retains the loop's existing steering queue; commands never enter it.
  bool offerInput(String line) {
    if (_closed || line.trimLeft().startsWith('/') || _commandFor(line) != null)
      return false;
    return _host.offerInput(line);
  }

  Future<SessionResult>? offerCommand(String line) {
    if (_closed || _host._closed || _host._stopping) return null;
    final call = _commandFor(line);
    return call != null && call.command.allowWhileRunning
        ? _runCommand(call.command, call.argument)
        : null;
  }

  Future<SessionResult> _runCommand(Command command, String argument) async {
    _host._checkOpen();
    // Legacy command cancellation belongs to the command instance. Admit one
    // cancellable invocation at a time so its callback cannot stop a different
    // invocation that happened to start later through another connection.
    if (command.cancel != null && _host._commandWork.containsValue(command)) {
      return SessionResult(
          detail:
              'A ${command.name} command is already running in this session.');
    }
    final id = 'work-${++_host._nextWork}';
    final settled = Completer<void>();
    _host._commandWork[id] = command;
    final scope = _host._commandQuestions[id] = _host.questions.openScope();
    _host._pendingWork.add(settled);
    _host._changed();
    try {
      await scope.run(() => command.handler(argument));
      return const SessionResult();
    } finally {
      scope.cancel();
      _host._commandQuestions.remove(id);
      _host._commandWork.remove(id);
      _host._pendingWork.remove(settled);
      settled.complete();
      _host._changed();
    }
  }

  /// Only the named work can be cancelled. A stale request is a no-op even if
  /// another turn or invocation of the same command is now running.
  bool cancel(Iterable<String> workIds, {String reason = 'client'}) {
    if (_closed || _host._closed) return false;
    var cancelled = false;
    final ids = workIds.toSet();
    if (_host._turnWork case final work? when ids.contains(work.id)) {
      _host._turnQuestions?.cancel();
      _host.session.loop.cancel(reason);
      cancelled = true;
    }
    for (final id in ids) {
      final questions = _host._commandQuestions[id];
      if (questions?.hasPending == true) {
        questions!.cancel();
        cancelled = true;
      }
      final command = _host._commandWork[id];
      if (command?.cancel case final cancel?) {
        cancel();
        cancelled = true;
      }
    }
    if (cancelled) _host._changed();
    return cancelled;
  }

  /// Starts with current status, then coalesced status updates. History and
  /// feature observations retain their existing plugin-owned contracts.
  void Function() listen(void Function(SessionStatus) listener) {
    _checkOpen();
    final key = Object();
    _listeners[key] = listener;
    try {
      listener(status);
    } catch (_) {
      _listeners.remove(key);
      rethrow;
    }
    return () => _listeners.remove(key);
  }

  void _notify() {
    if (_closed) return;
    final value = status;
    for (final entry in _listeners.entries.toList()) {
      if (!_listeners.containsKey(entry.key)) continue;
      try {
        entry.value(value);
      } catch (_) {
        _listeners.remove(entry.key);
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _questions?.close();
    _listeners.clear();
    _host._connections.remove(this);
  }
}
