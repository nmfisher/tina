part of 'host.dart';

enum SessionRole { observer, controller }

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

/// A cancellation target allocated by the host. A new turn, command or operation gets a
/// new ID, including a steered turn inside the same send operation.
final class SessionWork {
  const SessionWork(this.id, this.kind,
      {this.command, this.plugin, this.operation});
  final String id, kind;
  final String? command;
  final String? plugin, operation;
}

final class SessionStatus {
  SessionStatus(
      {required this.id,
      required this.model,
      required this.workingDirectory,
      required this.running,
      required this.busy,
      required this.acceptsInput,
      required this.pendingInputCount,
      required this.stopping,
      required this.closed,
      required Iterable<SessionWork> cancellableWork})
      : cancellableWork = List.unmodifiable(cancellableWork);
  final String id, model, workingDirectory;
  final bool running, stopping, closed;

  /// Includes whole plugin operations and commands without cancellation hooks.
  final bool busy;

  /// Plain input can start or steer now. An availability hint, not acceptance.
  final bool acceptsInput;
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
  SessionConnection._(this._host, this.role);
  final Host _host;
  final SessionRole role;
  late final ClientAccess access = ClientAccess(
      canControl: role == SessionRole.controller,
      checkActive: () {
        _checkOpen();
        _host._checkOpen();
      });
  bool get canControl => access.canControl;
  bool _closed = false;
  QuestionClient? _questions;
  QuestionClient get questions {
    _checkOpen();
    return _questions ??= _host.questions.connect(access: access);
  }

  final _listeners = <Object, void Function(SessionStatus)>{};
  final _attachments = <SessionAttachment>{};

  /// Capture current state and register delivery synchronously, without an
  /// await or a user callback between them. Updates replace the initial state.
  SessionAttachment attach() {
    _checkOpen();
    _host._checkOpen();
    final snapshot = _host._captureSnapshot();
    final attachment = SessionAttachment._(this, snapshot);
    _attachments.add(attachment);
    return attachment;
  }

  SessionHistoryPage history(
      {required SessionSnapshot snapshot, int afterSeq = -1, int limit = 128}) {
    _checkOpen();
    if (snapshot.cursor.epoch != _host._epoch) {
      throw ArgumentError('Snapshot belongs to another running session');
    }
    if (limit < 1 ||
        limit > 512 ||
        afterSeq < -1 ||
        afterSeq > snapshot.throughSeq) {
      throw RangeError('Invalid history page bounds');
    }
    final entries = _host.session.loop.publishedEntries(
        afterSeq: afterSeq, throughSeq: snapshot.throughSeq, limit: limit);
    final next = entries.isEmpty ? afterSeq : entries.last.seq;
    return SessionHistoryPage._(
        _host._epoch, snapshot.throughSeq, next, next < snapshot.throughSeq,
        entries.map((entry) {
      final data = freezeSnapshotValue({...entry.toJson(), 'seq': entry.seq})
          as Map<String, Object?>;
      final features = <String, Object?>{};
      final unavailable = <String>[];
      for (final feature in _host._features.entries.toList()) {
        try {
          final project = feature.value.source.historyMetadata;
          if (project == null) continue;
          // Extension projection callbacks never receive a live log entry.
          final metadata =
              project(SessionEntry.fromJson(Map<String, dynamic>.from(data)));
          if (metadata.isNotEmpty) {
            features[feature.key] = freezeSnapshotValue(metadata);
          }
        } catch (_) {
          unavailable.add(feature.key);
        }
      }
      return freezeSnapshotValue({
        ...data,
        if (features.isNotEmpty) 'features': features,
        if (unavailable.isNotEmpty) 'unavailable_features': unavailable,
      }) as Map<String, Object?>;
    }));
  }

  void _checkOpen() {
    if (_closed) throw StateError('session connection is closed');
  }

  /// Bounded session output through a fixed snapshot. Expiry is explicit;
  /// reading never subscribes a responder or changes session state.
  SessionNoticePage notices(
      {required SessionSnapshot snapshot, int afterSeq = -1, int limit = 128}) {
    _checkOpen();
    if (snapshot.cursor.epoch != _host._epoch)
      throw ArgumentError('Snapshot belongs to another running session');
    if (limit < 1 ||
        limit > 512 ||
        afterSeq < -1 ||
        afterSeq > snapshot.throughNoticeSeq)
      throw RangeError('Invalid notice page bounds');
    return _host.notices._page(snapshot, afterSeq, limit);
  }

  SessionStatus get status {
    _checkOpen();
    return _host._status();
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
    // Extension completion callbacks can execute arbitrary work. Observers
    // retain static command metadata, without invoking those callbacks.
    if (!canControl) return const [];
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
    access.requireControl();
    final trimmed = line.trim();
    final call = _commandFor(trimmed);
    if (call != null) {
      if ((_host.session.loop.running || _host._operation != null) &&
          !call.command.allowWhileRunning)
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

  /// Namespace for new caller-supplied IDs. Persist the resulting whole ID on
  /// the client before sending; never refresh its window when retrying.
  SessionRequestWindow get requestWindow {
    _checkOpen();
    _host._checkOpen();
    return _host._requests.window;
  }

  /// Observe a retained receipt without executing it. Null means unknown in a
  /// current window; an unknown retired ID explicitly throws expiry instead.
  SessionRequest? request(SessionRequestId id) {
    _checkOpen();
    return _host._requests.find(id)?.client;
  }

  /// Invoke a plugin operation through the owner, using only serializable data.
  /// Retries retain the same receipt; detach never stops accepted work.
  SessionRequest submitOperation(String plugin, String operation,
      {Map<String, Object?> arguments = const {},
      required SessionRequestId id}) {
    _checkOpen();
    _host._checkOpen();
    access.requireControl();
    final values = _operationValue(arguments) as Map<String, Object?>;
    final identity = jsonEncode([plugin, operation, values]);
    final requests = _host._requests;
    final existing = requests.find(id);
    if (existing != null) {
      if (existing.kind != 'operation' || existing.text != identity) {
        throw const SessionRequestError(SessionRequestErrorCode.conflict);
      }
      return existing.client;
    }
    final record = requests.accept(id, identity, kind: 'operation');
    unawaited(_host
        ._runOperation(record, plugin, operation, values)
        .catchError((Object error) {
      record.finish(
          SessionRequestState.failed,
          SessionResult(
              stopReason: StopReason.error,
              detail: 'Operation failed (${error.runtimeType})'));
    }));
    return record.client;
  }

  /// Read bounded output without invoking code. Observers have the same access
  /// as controllers; expiry and missing output are explicit.
  SessionOutputPage output(SessionRequestId id, {int afterSeq = -1}) {
    _checkOpen();
    final record = _host._requests.find(id);
    if (record == null) throw ArgumentError('Unknown request');
    if (afterSeq < -1 || afterSeq > record.outputSeq)
      throw RangeError('Invalid output cursor');
    return SessionOutputPage(
        record.output.where((e) => e.seq > afterSeq),
        record.outputSeq,
        record.output.isNotEmpty && afterSeq < record.output.first.seq - 1);
  }

  /// Synchronously admit a retryable submission and return its receipt. Plain
  /// input steers a running turn through the engine's existing queue; commands
  /// retain their plugin's allowWhileRunning policy. Rejected admissions are
  /// also retained, so a retry cannot change meaning when session state changes.
  /// Unlike [submit], completion describes this individual input, not the whole
  /// drain of subsequent steered inputs. Existing one-shot methods retain their
  /// embedded-client behavior and do not promise retry safety.
  SessionRequest submitRequest(String line, {required SessionRequestId id}) {
    _checkOpen();
    _host._checkOpen();
    access.requireControl();
    final requests = _host._requests;
    final existing = requests.find(id);
    if (existing != null) {
      if (existing.kind != 'input' || existing.text != line) {
        throw const SessionRequestError(SessionRequestErrorCode.conflict);
      }
      return existing.client;
    }
    final record = requests.accept(id, line);
    void reject(String detail) => record.finish(
        SessionRequestState.rejected, SessionResult(detail: detail));
    final trimmed = line.trim();
    final call = _commandFor(trimmed);
    if (call != null) {
      if ((_host.session.loop.running || _host._operation != null) &&
          !call.command.allowWhileRunning) {
        reject('Command requires an idle session.');
      } else if (call.command.cancel != null &&
          _host._commandWork.containsValue(call.command)) {
        reject(
            'A ${call.command.name} command is already running in this session.');
      } else {
        // Receipt completion handles failures even when all clients detach.
        unawaited(_runCommand(call.command, call.argument, request: record)
            .then<void>((_) {}, onError: (Object error, StackTrace stack) {}));
      }
    } else if (trimmed.startsWith('/')) {
      reject(
          'unknown command: /${trimmed.substring(1).split(RegExp(r'\s')).first}');
    } else if (trimmed.isEmpty) {
      reject('Input is empty.');
    } else if (_host._operation != null && !_host.session.loop.running) {
      reject('A session operation is running; input was not queued.');
    } else {
      final inputId = 't-${_host.session.loop.seq}-input-${++_host._nextInput}';
      record.setInput(inputId);
      if (_host.session.loop.running) {
        if (!_host.session.loop.offerInput(Input(line, id: inputId))) {
          reject('Session is between turns or stopping; input was not queued.');
        } else {
          _host._changed();
        }
      } else {
        // Input settlements report each turn independently. This future drains
        // the existing queue and may finish after this receipt's own turn.
        unawaited(_host.send(trimmed, turnId: inputId).then<void>((_) {},
            onError: (Object error, StackTrace stack) {
          record.finish(
              SessionRequestState.failed,
              SessionResult(
                  stopReason: StopReason.error,
                  detail: 'Input failed (${error.runtimeType})'));
        }));
      }
    }
    return record.client;
  }

  /// Retains the loop's existing steering queue; commands never enter it.
  bool offerInput(String line) {
    if (_closed ||
        _host._closed ||
        _host._stopping ||
        line.trimLeft().startsWith('/') ||
        _commandFor(line) != null) return false;
    access.requireControl();
    return _host.offerInput(line);
  }

  Future<SessionResult>? offerCommand(String line) {
    if (_closed || _host._closed || _host._stopping) return null;
    access.requireControl();
    final call = _commandFor(line);
    return call != null && call.command.allowWhileRunning
        ? _runCommand(call.command, call.argument)
        : null;
  }

  Future<SessionResult> _runCommand(Command command, String argument,
      {_RequestRecord? request}) async {
    _host._checkOpen();
    access.requireControl();
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
    if (request != null) {
      _host._requests.byCommand[id] = request;
      request.start(id);
    }
    final scope = _host._commandQuestions[id] = _host.questions.openScope();
    _host._pendingWork.add(settled);
    _host._changed();
    try {
      await scope.run(() => command.handler(argument));
      request?.finish(
          request.cancellationRequested
              ? SessionRequestState.cancelled
              : SessionRequestState.completed,
          SessionResult(
              stopReason:
                  request.cancellationRequested ? StopReason.cancelled : null));
      return const SessionResult();
    } catch (error) {
      request?.finish(
          SessionRequestState.failed,
          SessionResult(
              stopReason: StopReason.error,
              detail: 'Command failed (${error.runtimeType})'));
      rethrow;
    } finally {
      scope.cancel();
      _host._commandQuestions.remove(id);
      _host._commandWork.remove(id);
      _host._requests.byCommand.remove(id);
      _host._pendingWork.remove(settled);
      settled.complete();
      _host._changed();
      if (!_host._stopping && !_host.busy) _host.onIdle?.call();
    }
  }

  /// Only the named work can be cancelled. A stale request is a no-op even if
  /// another turn or invocation of the same command is now running.
  bool cancel(Iterable<String> workIds, {String reason = 'client'}) {
    if (_closed || _host._closed) return false;
    access.requireControl();
    var cancelled = false;
    final ids = workIds.toSet();
    if (_host._operation case final operation?
        when ids.contains(operation._record.snapshot.workId)) {
      operation._stop(reason);
      cancelled = true;
    }
    if (_host._turnWork case final work?
        when _host.session.loop.running && ids.contains(work.id)) {
      _host._turnQuestions?.cancel();
      _host.session.loop.cancel(reason);
      cancelled = true;
    }
    for (final id in ids) {
      final questions = _host._commandQuestions[id];
      if (questions?.hasPending == true) {
        _host._requests.byCommand[id]?.cancellationRequested = true;
        questions!.cancel();
        cancelled = true;
      }
      final command = _host._commandWork[id];
      if (command?.cancel case final cancel?) {
        _host._requests.byCommand[id]?.cancellationRequested = true;
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
    for (final attachment in _attachments.toList()) attachment.close();
    _questions?.close();
    _listeners.clear();
    _host._connections.remove(this);
  }
}
