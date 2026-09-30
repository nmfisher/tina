import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'completion_sources.dart';
import 'settings_panel.dart';
import 'plugin_catalog.dart';
import 'tui_session.dart';

/// Adapts a session to UI capabilities. The workspace plugin never imports
/// this application or constructs an engine, provider, or persistence store.
final class SessionView implements ConsoleSessionView {
  SessionView(this.session, {this.showConfig = false});
  final TuiSession session;
  final bool showConfig;
  final _attached = <ConsoleContribution, ConsoleAttachment>{};
  ConsoleContext? _context;
  SettingsPanel? _settings;
  @override
  String get id => session.host.session.id;
  @override
  String get label => session.host.model;
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
    await session.runLine(text, renderReply: false);
  }

  @override
  void cancel() => session.host.session.loop.cancel('escape');
  @override
  void notice(String text) {
    final transcript =
        _attached.keys.whereType<ConsoleTranscript>().firstOrNull;
    if (transcript != null) {
      transcript.writeNotice(text);
    } else {
      _context?.chat.writeln(text);
    }
  }

  @override
  void attachConsole(ConsoleContext context) {
    _context = context;
    final terminal = session.terminal as TuiTerminal;
    terminal.onLine = notice;
    void attach(AgentPlugin plugin) {
      if (plugin is! ConsoleContribution) return;
      final contribution = plugin as ConsoleContribution;
      _attached[contribution] = ConsoleAttachment.attach(contribution, context);
    }

    session.assembly.pluginManager.onLoaded = attach;
    session.assembly.pluginManager.onUnloading = (plugin) {
      if (plugin is! ConsoleContribution) return;
      final contribution = plugin as ConsoleContribution;
      _attached.remove(contribution)?.dispose();
    };
    for (final plugin in session.host.plugins) {
      attach(plugin);
    }
    _settings = SettingsPanel(context.screen, context.input);
    session.assembly.openSettings = () => context.interact(() async {
          final saved = await _settings!.run(
              applyGeneration: session.assembly.applySavedGeneration,
              path: session.assembly.configPath,
              sections: context.settings,
              descriptors: session.assembly.descriptors,
              validatePlugins: session.assembly.validatePlugins,
              pluginIds: session.assembly.pluginSettings.registry.ids,
              pluginDescriptions:
                  pluginDescriptions(session.assembly.pluginSettings.registry),
              pluginSettings: session.assembly.pluginSettings,
              pluginManager: session.assembly.pluginManager);
          notice(saved
              ? 'Settings saved. Generation applies to the next request.'
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
    for (final contribution in _attached.keys.toList()) {
      contribution.repaintConsole();
    }
    if (_context?.isActive == true) _settings?.repaint();
  }

  @override
  void detachConsole() {
    session.assembly.openSettings = null;
    session.assembly.pluginManager.onLoaded = null;
    session.assembly.pluginManager.onUnloading = null;
    for (final attachment in _attached.values.toList().reversed) {
      try {
        attachment.dispose();
      } catch (_) {/* Continue releasing views. */}
    }
    _attached.clear();
    (session.terminal as TuiTerminal).onLine = null;
    _context = null;
    _settings = null;
  }

  @override
  void close() {
    detachConsole();
    session.close();
  }
}
