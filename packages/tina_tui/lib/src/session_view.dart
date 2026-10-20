import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'package:tina_console/tina_console.dart';
import 'package:tina_host/tina_host.dart';
import 'completion_sources.dart';
import 'console_commands.dart';
import 'session_presentation.dart';
import 'question_view.dart';

/// A disposable frontend over session operations and presentation capabilities.
/// Runtime implementations and shutdown authority stay with the application.
final class SessionView
    implements
        ConsoleSessionView,
        ConsoleInputReceiver,
        ConsolePendingInput,
        ConsoleInputHistory,
        ConsoleCommandReceiver {
  SessionView(this.connection, this.presentation, {this.showConfig = false}) {
    _stopStatus = connection.listen((_) => _sessionChanged());
  }
  final SessionConnection connection;
  final SessionPresentation presentation;
  final bool showConfig;
  final _attached = <String, ConsoleAttachment>{};
  Iterable<ConsoleContribution> get contributions => List.unmodifiable(
      _attached.values.map((attachment) => attachment.contribution));
  ConsoleContext? _context;
  SessionSettingsView? _settings;
  ConsoleAttachment? _questions;
  SessionAttachment? _observation;
  int _noticeSeq = -1, _noticeHistorySeq = -1;
  Future<void> Function()? _openSettings;
  final _releases = <void Function()>[];
  bool _closed = false, _quitRequested = false;
  late final void Function() _stopStatus;
  final _activity = <Object, void Function()>{};
  final _deferred = Queue<_ViewSubmission>();
  bool _draining = false, _notificationQueued = false;
  // A view-local namespace prevents different controllers choosing the same ID.
  final _requestPrefix = List.generate(16,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
  int _nextRequest = 0;

  SessionStatus get status => connection.status;
  Theme get theme => presentation.theme();
  @override
  bool get canCancel => !_closed && connection.canControl && status.canCancel;
  @override
  bool get busy => !_closed && status.busy;
  @override
  void Function() listenActivity(void Function() listener) {
    if (_closed) throw StateError('session view is closed');
    final key = Object();
    _activity[key] = listener;
    try {
      listener();
    } catch (_) {
      _activity.remove(key);
      rethrow;
    }
    return () => _activity.remove(key);
  }

  void _changed() {
    if (_closed || _notificationQueued) return;
    _notificationQueued = true;
    scheduleMicrotask(() {
      _notificationQueued = false;
      if (_closed) return;
      _context?.refreshStatus();
      for (final entry in _activity.entries.toList()) {
        if (!_activity.containsKey(entry.key)) continue;
        try {
          entry.value();
        } catch (_) {
          _activity.remove(entry.key);
        }
      }
    });
  }

  void _sessionChanged() {
    if (_closed) return;
    if (status.closed || status.stopping) {
      _discardDeferred('Session stopped before queued input was sent.');
    } else {
      _drainDeferred();
    }
    _changed();
  }

  void Function() listenStatus(void Function(SessionStatus) listener) =>
      connection.listen(listener);
  @override
  String get id => status.id;
  @override
  String get label => status.model;
  @override
  Iterable<String> get inputHistory => connection.inputHistory;
  @override
  bool get quitRequested => _quitRequested || presentation.quitRequested();
  @override
  CompletionProvider get commandCompletion =>
      CommandNameCompletionSource(connection);
  @override
  CompletionProvider get fileCompletion =>
      GitFileCompletionSource(workingDir: status.workingDirectory);

  Future<void>? _offerLocalCommand(String text, {bool whileRunning = false}) {
    final call = connection.commandFor(text);
    if (call != null &&
        call.command.name == 'quit' &&
        (!whileRunning || call.command.allowWhileRunning)) {
      _quitRequested = true;
      _discardDeferred();
      return Future.value();
    }
    return offerSettingsCommand(connection, text, _openSettings,
            whileRunning: whileRunning) ??
        offerConsoleCommand(connection, _attached.values, text,
            whileRunning: whileRunning);
  }

  @override
  Future<void> submit(String text) async {
    if (_closed || status.closed || status.stopping)
      throw StateError('session view is closed or stopping');
    if (_quitRequested || text.trim().isEmpty) return;
    final submission = _ViewSubmission(text);
    final wasBusy = busy;
    if (!_dispatch(submission)) {
      _deferred.add(submission);
      notice('Message queued; waiting for current work.');
      _changed();
    } else if (wasBusy &&
        submission.request?.snapshot.inputId != null &&
        submission.request?.snapshot.state == SessionRequestState.accepted) {
      notice('Message queued; waiting for current work.');
    }
    await submission.done.future;
  }

  /// Only unsent lines wait here. A request ID is allocated immediately before
  /// its first send and retained with that action; accepted work is never put
  /// back on this queue, even after rejection, cancellation, expiry or failure.
  bool _dispatch(_ViewSubmission submission) {
    final current = status;
    final call = connection.commandFor(submission.text);
    try {
      // Interactive dialogs (settings, model picker, panels) open even while a
      // turn is running; they only present choices, and their plugin operations
      // still enforce their own idle policy when applied.
      final local =
          _offerLocalCommand(submission.text, whileRunning: current.busy);
      if (local != null) {
        unawaited(_complete(submission, local));
        _changed();
        return true;
      }
      // Other commands follow their command's running-turn policy: those that
      // opt out of running while busy are deferred until the session idles.
      if (current.busy && call != null && !call.command.allowWhileRunning) {
        if (connection.canControl) return false;
      }
      connection.access.requireControl();
      final plain = call == null && !submission.text.trimLeft().startsWith('/');
      if (plain && !current.acceptsInput) return false;
      submission.requestId ??=
          connection.requestWindow.id('$_requestPrefix-${++_nextRequest}');
      final request = submission.request =
          connection.submitRequest(submission.text, id: submission.requestId!);
      unawaited(_complete(submission, request.completed.then((snapshot) {
        if (!_closed && snapshot.result?.notice != null)
          notice(snapshot.result!.notice!);
      })));
    } catch (error) {
      if (!_closed) notice(error.toString());
      submission.done.complete();
    }
    return true;
  }

  Future<void> _complete(_ViewSubmission submission, Future<void> work) async {
    try {
      await work;
    } catch (error) {
      if (!_closed) notice('Command error: $error');
    } finally {
      submission.done.complete();
      _changed();
    }
  }

  void _drainDeferred() {
    if (_closed || _quitRequested || _draining || busy || _deferred.isEmpty)
      return;
    final next = _deferred.removeFirst();
    // Reserve the drain before invoking a local command, which can reenter.
    _draining = true;
    if (!_dispatch(next)) {
      _deferred.addFirst(next);
      _draining = false;
      return;
    }
    _changed();
    unawaited(next.done.future.then((_) {
      _draining = false;
      _drainDeferred();
    }));
  }

  void _discardDeferred([String? message]) {
    while (_deferred.isNotEmpty) {
      _deferred.removeFirst().done.complete();
      if (message != null) notice(message);
    }
  }

  @override
  bool offerInput(String text) {
    if (_closed ||
        _quitRequested ||
        !connection.canControl ||
        !status.running ||
        !status.acceptsInput ||
        text.trim().isEmpty ||
        text.trimLeft().startsWith('/') ||
        connection.commandFor(text) != null) return false;
    return _dispatch(_ViewSubmission(text));
  }

  @override
  int get pendingInputCount =>
      _closed ? 0 : _deferred.length + status.pendingInputCount;
  @override
  Future<void>? offerCommand(String text) {
    if (_closed || _quitRequested || status.closed || status.stopping)
      return null;
    final call = connection.commandFor(text);
    if (call == null || !call.command.allowWhileRunning) return null;
    final submission = _ViewSubmission(text);
    _dispatch(submission);
    return submission.done.future;
  }

  @override
  void cancel() {
    if (_closed) return;
    _settings?.close();
    if (!connection.canControl) return;
    connection.cancel(status.cancellableWork.map((work) => work.id),
        reason: 'escape');
  }

  @override
  void notice(String text) {
    final transcript = contributions.whereType<ConsoleTranscript>().firstOrNull;
    if (transcript != null)
      transcript.writeNotice(text);
    else
      _context?.chat.writeln(text);
  }

  @override
  void attachConsole(ConsoleContext context) {
    if (_closed || status.closed || status.stopping)
      throw StateError('session view is closed or stopping');
    detachConsole();
    _context = context;
    final observation = _observation = connection.attach();
    _questions =
        ConsoleAttachment.attach(QuestionView(connection.questions), context);
    void attach(String id, ConsoleContribution contribution) {
      _attached[id] = ConsoleAttachment.attach(contribution, context);
    }

    _releases.add(presentation.listenViews(
        attach, (id) => _attached.remove(id)?.dispose()));
    for (final entry in presentation.createViews().entries) {
      attach(entry.key, entry.value);
    }
    _noticeSeq = _noticeHistorySeq = -1;
    _showSessionNotices(observation, observation.initial, context);
    unawaited(_observe(observation, context));
    final settings = _settings = presentation.settingsFor(context);
    _releases.add(presentation.listenTheme((theme) {
      context.screen.setTheme(theme);
      context.screen.repaintAfterThemeChange();
      repaintConsole();
    }));
    _openSettings = () => context.interact(() async {
          if (_closed || _context != context || !context.isActive) return;
          if (!connection.canControl) {
            notice('Settings changes require a controlling connection.');
            return;
          }
          try {
            final message = await settings.open();
            if (!_closed && _context == context) notice(message);
          } catch (_) {
            if (!_closed && _context == context)
              notice(
                  'Could not open settings. Check the config file and its permissions.');
          }
          if (!_closed && _context == context) context.chat.repaint();
        });
    if (showConfig) {
      if (presentation.configNote case final note?) notice(note);
    }
  }

  @override
  void repaintConsole() {
    _questions?.contribution.repaintConsole();
    for (final attachment in _attached.values.toList()) {
      attachment.contribution.repaintConsole();
    }
    if (_context?.isActive == true) _settings?.repaint();
  }

  @override
  void detachConsole() {
    _observation?.close();
    _observation = null;
    _questions?.dispose();
    _questions = null;
    _settings?.close();
    _openSettings = null;
    for (final release in _releases.reversed) release();
    _releases.clear();
    for (final attachment in _attached.values.toList().reversed) {
      try {
        attachment.dispose();
      } catch (_) {/* Release every view. */}
    }
    _attached.clear();
    _context = null;
    _settings = null;
  }

  Future<void> _observe(
      SessionAttachment attachment, ConsoleContext context) async {
    try {
      while (identical(_observation, attachment)) {
        final update = await attachment.next();
        if (update == null || !identical(_observation, attachment)) return;
        _showSessionNotices(attachment, update.snapshot, context);
        context.refreshStatus();
      }
    } catch (_) {
      // Presentation failure retires this observer, never the shared session.
      attachment.close();
    }
  }

  void _showSessionNotices(SessionAttachment attachment,
      SessionSnapshot snapshot, ConsoleContext context) {
    if (contributions
        .whereType<ConsoleTranscript>()
        .any((view) => view.observesSessionNotices)) {
      _noticeSeq = snapshot.throughNoticeSeq;
      _noticeHistorySeq = snapshot.throughSeq;
      return;
    }
    // With chat disabled, retain a plain notice display. A later clear retires
    // earlier notices just as it does in the full transcript renderer.
    var clearedThrough = -1;
    while (_noticeHistorySeq < snapshot.throughSeq) {
      final page =
          attachment.history(snapshot: snapshot, afterSeq: _noticeHistorySeq);
      for (final entry in page.entries) {
        if (entry['type'] == 'context_cleared')
          clearedThrough = entry['seq'] as int;
      }
      _noticeHistorySeq = page.nextAfterSeq;
    }
    if (clearedThrough >= 0) context.chat.resetAfterClear();
    while (_noticeSeq < snapshot.throughNoticeSeq) {
      final page = attachment.notices(snapshot: snapshot, afterSeq: _noticeSeq);
      if (page.omittedThroughSeq != null &&
          page.omittedAfterHistorySeq! >= clearedThrough)
        notice(
            'Earlier session notices expired; committed history is unchanged.');
      for (final entry in page.entries) {
        if (entry.afterHistorySeq >= clearedThrough)
          notice(
              '${entry.text}${entry.truncated ? '\n[Notice truncated.]' : ''}');
      }
      _noticeSeq = page.nextAfterSeq;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _stopStatus();
    _activity.clear();
    _discardDeferred();
    try {
      detachConsole();
    } finally {
      connection.close();
    }
  }
}

final class _ViewSubmission {
  _ViewSubmission(this.text);
  final String text;
  final done = Completer<void>();
  SessionRequestId? requestId;
  SessionRequest? request;
}
