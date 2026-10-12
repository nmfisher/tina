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
  SessionView(this.connection, this.presentation, {this.showConfig = false});
  final SessionConnection connection;
  final SessionPresentation presentation;
  final bool showConfig;
  final _attached = <String, ConsoleAttachment>{};
  Iterable<ConsoleContribution> get contributions => List.unmodifiable(
      _attached.values.map((attachment) => attachment.contribution));
  ConsoleContext? _context;
  SessionSettingsView? _settings;
  ConsoleAttachment? _questions;
  Future<void> Function()? _openSettings;
  final _releases = <void Function()>[];
  bool _closed = false, _quitRequested = false;

  SessionStatus get status => connection.status;
  Theme get theme => presentation.theme();
  bool get canCancel => !_closed && status.canCancel;
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
    final command = _offerLocalCommand(text);
    if (command != null) {
      await command;
    } else {
      final result = await connection.submit(text);
      if (!_closed && result.notice != null) notice(result.notice!);
    }
  }

  @override
  bool offerInput(String text) => !_closed && connection.offerInput(text);
  @override
  int get pendingInputCount => status.pendingInputCount;
  @override
  Future<void>? offerCommand(String text) {
    if (_closed || status.closed || status.stopping) return null;
    return _offerLocalCommand(text, whileRunning: true) ??
        connection.offerCommand(text)?.then((result) {
          if (!_closed && result.notice != null) notice(result.notice!);
        });
  }

  @override
  void cancel() {
    if (_closed) return;
    _settings?.close();
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
    _questions =
        ConsoleAttachment.attach(QuestionView(connection.questions), context);
    _releases.add(connection.listen((_) => context.refreshStatus()));
    _releases.add(presentation.listenNotices(notice));
    void attach(String id, ConsoleContribution contribution) {
      _attached[id] = ConsoleAttachment.attach(contribution, context);
    }

    _releases.add(presentation.listenViews(
        attach, (id) => _attached.remove(id)?.dispose()));
    for (final entry in presentation.createViews().entries) {
      attach(entry.key, entry.value);
    }
    final settings = _settings = presentation.settingsFor(context);
    _releases.add(presentation.listenTheme((theme) {
      context.screen.setTheme(theme);
      context.screen.repaintAfterThemeChange();
      repaintConsole();
    }));
    _openSettings = () => context.interact(() async {
          if (_closed || _context != context || !context.isActive) return;
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

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      detachConsole();
    } finally {
      connection.close();
    }
  }
}
