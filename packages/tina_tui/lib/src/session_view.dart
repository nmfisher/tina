import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'dart:convert';
import 'app.dart' show resolveTheme;
import 'completion_sources.dart';
import 'settings_panel.dart';
import 'plugin_catalog.dart';
import 'console_catalog.dart';
import 'console_commands.dart';
import 'tui_session.dart';

/// Adapts a session to UI capabilities. The workspace plugin never imports
/// this application or constructs an engine, provider, or persistence store.
final class SessionView
    implements
        ConsoleSessionView,
        ConsoleInputReceiver,
        ConsolePendingInput,
        ConsoleInputHistory,
        ConsoleCommandReceiver {
  SessionView(this.session, {this.showConfig = false});
  final TuiSession session;
  final bool showConfig;
  final _attached = <AgentPlugin, ConsoleAttachment>{};
  Iterable<ConsoleContribution> get contributions => List.unmodifiable(
      _attached.values.map((attachment) => attachment.contribution));
  ConsoleContext? _context;
  int? _inputStatusListener;
  SettingsPanel? _settings;
  Future<void> Function()? _openSettings;
  final _releases = <void Function()>[];
  @override
  String get id => session.host.session.id;
  @override
  String get label => session.host.model;
  @override
  Iterable<String> get inputHistory => session.inputHistory;
  @override
  bool get quitRequested => session.assembly.quitRequested;
  @override
  CompletionProvider get commandCompletion =>
      CommandNameCompletionSource(session.commands);
  @override
  CompletionProvider get fileCompletion =>
      GitFileCompletionSource(workingDir: session.host.config.workingDirectory);
  @override
  Future<void> submit(String text) async {
    final command =
        offerSettingsCommand(session.commands, text, _openSettings) ??
            offerConsoleCommand(session.commands, _attached.values, text);
    if (command != null) {
      await command;
    } else {
      await session.runLine(text, renderReply: false);
    }
  }

  @override
  bool offerInput(String text) => session.offerInput(text);

  @override
  int get pendingInputCount => session.host.session.loop.pendingInputCount;

  @override
  Future<void>? offerCommand(String text) =>
      offerSettingsCommand(session.commands, text, _openSettings,
          whileRunning: true) ??
      offerConsoleCommand(session.commands, _attached.values, text,
          whileRunning: true) ??
      session.offerCommand(text);

  @override
  void cancel() {
    _settings?.cancel();
    session.cancel();
  }

  @override
  void notice(String text) {
    final transcript = _attached.values
        .map((attachment) => attachment.contribution)
        .whereType<ConsoleTranscript>()
        .firstOrNull;
    if (transcript != null) {
      transcript.writeNotice(text);
    } else {
      _context?.chat.writeln(text);
    }
  }

  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _context = context;
    _inputStatusListener = session.host.session.loop.subscribe((entry, event) {
      if (entry is InputRecordedEntry || entry is TurnEndedEntry) {
        context.refreshStatus();
      }
    });
    final terminal = session.terminal as TuiTerminal;
    _releases.add(terminal.listenLines(notice));
    void attach(AgentPlugin plugin) {
      final contribution = createConsoleView(plugin);
      if (contribution == null) return;
      _attached[plugin] = ConsoleAttachment.attach(contribution, context);
    }

    _releases.add(session.assembly.pluginManager.listen(
        loaded: attach,
        unloading: (plugin) => _attached.remove(plugin)?.dispose()));
    for (final plugin in session.host.plugins) {
      attach(plugin);
    }
    _settings = SettingsPanel(context.screen, context.input);
    var appliedTheme = jsonEncode(session.assembly.theme);
    _releases.add(session.assembly.listenSettings(() {
      final next = jsonEncode(session.assembly.theme);
      if (next != appliedTheme) {
        appliedTheme = next;
        context.screen.setTheme(resolveTheme(session.assembly.theme));
        // setTheme only invalidates retained paint state; without an eager
        // global repaint the new theme reaches the screen lazily — regions
        // behind an open settings panel keep the old colors until they
        // repaint for their own reasons. Repaint now, then let contributions
        // re-render any styled content they cache.
        context.screen.repaintAfterThemeChange();
        repaintConsole();
      }
      _settings?.repaint();
    }));
    _openSettings = () => context.interact(() async {
          if (!context.isActive) return;
          final saved = await _settings!.run(
              scopedSettings: session.assembly.settings,
              settingsBackend: session.assembly.settingsBackend,
              applyConfiguration: session.assembly.applySavedConfiguration,
              path: session.assembly.configPath,
              sections: context.settings,
              descriptors: session.assembly.descriptors,
              validatePlugins: session.assembly.validatePlugins,
              pluginDescriptions:
                  pluginDescriptions(session.assembly.pluginSettings.registry),
              pluginSettings: session.assembly.pluginSettings,
              pluginManager: session.assembly.pluginManager);
          notice(saved
              ? session.assembly.settings.applicationErrors.isEmpty
                  ? 'Settings saved. Request settings affect the next request; plugin changes may wait for idle or restart.'
                  : 'Settings saved, but some changes could not apply. Reopen Settings for details.'
              : 'Settings closed.');
          context.chat.repaint();
        });
    if (showConfig) {
      final note = session.assembly.configNote;
      if (note != null) notice(note);
    }
  }

  @override
  void repaintConsole() {
    for (final attachment in _attached.values.toList()) {
      attachment.contribution.repaintConsole();
    }
    if (_context?.isActive == true) _settings?.repaint();
  }

  @override
  void detachConsole() {
    if (_inputStatusListener case final listener?) {
      session.host.session.loop.unsubscribe(listener);
      _inputStatusListener = null;
    }
    _settings?.cancel();
    _openSettings = null;
    for (final release in _releases.reversed) release();
    _releases.clear();
    for (final attachment in _attached.values.toList().reversed) {
      try {
        attachment.dispose();
      } catch (_) {/* Continue releasing views. */}
    }
    _attached.clear();
    _context = null;
    _settings = null;
  }

  @override
  void close() {
    detachConsole();
    session.close();
  }
}
