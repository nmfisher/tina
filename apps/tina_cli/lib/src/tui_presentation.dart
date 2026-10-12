import 'dart:convert';
import 'assembly.dart';
import 'config_settings_management.dart';
import 'console_catalog.dart';
import 'plugin_catalog.dart';
import 'package:tina_tui/tina_tui.dart';
import 'session_terminal.dart';

/// Application composition: concrete feature instances and configuration
/// services are wired here, never reached through by a view.
SessionPresentation presentationForAssembly(SessionAssembly assembly) =>
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
          (assembly.terminal as SessionTerminal).listenLines(listener),
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
                  sections: context.settings,
                  management: ConfigSettingsManagement(
                      commandApprovals: assembly.tools.commandApprovals,
                      scopedSettings: assembly.settings,
                      backend: assembly.settingsBackend,
                      applyConfiguration: assembly.applySavedConfiguration,
                      listenConfiguration: assembly.listenSettings,
                      descriptors: assembly.descriptors,
                      validatePlugins: assembly.validatePlugins,
                      pluginDescriptions:
                          pluginDescriptions(assembly.pluginSettings.registry),
                      pluginSettings: assembly.pluginSettings,
                      pluginManager: assembly.pluginManager));
              return saved
                  ? assembly.settings.applicationErrors.isEmpty
                      ? 'Settings saved. Request settings affect the next request; plugin changes may wait for idle or restart.'
                      : 'Settings saved, but some changes could not apply. Reopen Settings for details.'
                  : 'Settings closed.';
            },
            repaint: panel.repaint,
            close: panel.cancel);
      },
    );
