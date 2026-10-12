import 'dart:convert';
import 'package:tina_console/tina_console.dart';
import 'assembly.dart';
import 'console_catalog.dart';
import 'plugin_catalog.dart';
import 'session_presentation.dart';
import 'settings_panel.dart';
import 'theme.dart';
import 'tui_terminal.dart';

/// Transitional application composition: concrete feature instances and
/// configuration services are wired here, never reached through by a view.
SessionPresentation presentationForAssembly(TuiAssembly assembly) =>
    SessionPresentation(
      theme: () => resolveTheme(assembly.theme),
      configNote: assembly.configNote,
      quitRequested: () => assembly.quitRequested,
      createViews: () => {
        for (final plugin in assembly.host.plugins)
          if (createConsoleView(plugin) case final view?) plugin.id: view,
      },
      listenViews: (loaded, unloading) => assembly.pluginManager.listen(
        loaded: (plugin) {
          if (createConsoleView(plugin) case final view?)
            loaded(plugin.id, view);
        },
        unloading: (plugin) => unloading(plugin.id),
      ),
      listenNotices: (listener) =>
          (assembly.terminal as TuiTerminal).listenLines(listener),
      listenTheme: (listener) {
        var previous = jsonEncode(assembly.theme);
        return assembly.listenSettings(() {
          final next = jsonEncode(assembly.theme);
          if (next == previous) return;
          previous = next;
          listener(resolveTheme(assembly.theme));
        });
      },
      settingsFor: (context) {
        final panel = SettingsPanel(context.screen, context.input);
        return SessionSettingsView(
            open: () async {
              final saved = await panel.run(
                  commandApprovals: assembly.tools.commandApprovals,
                  scopedSettings: assembly.settings,
                  settingsBackend: assembly.settingsBackend,
                  applyConfiguration: assembly.applySavedConfiguration,
                  path: assembly.configPath,
                  sections: context.settings,
                  descriptors: assembly.descriptors,
                  validatePlugins: assembly.validatePlugins,
                  pluginDescriptions:
                      pluginDescriptions(assembly.pluginSettings.registry),
                  pluginSettings: assembly.pluginSettings,
                  pluginManager: assembly.pluginManager);
              return saved
                  ? assembly.settings.applicationErrors.isEmpty
                      ? 'Settings saved. Request settings affect the next request; plugin changes may wait for idle or restart.'
                      : 'Settings saved, but some changes could not apply. Reopen Settings for details.'
                  : 'Settings closed.';
            },
            repaint: panel.repaint,
            close: panel.cancel);
      },
      createWorkspace: () => assembly.host.plugins
          .map(createConsoleView)
          .whereType<ConsoleWorkspace>()
          .firstOrNull,
    );
