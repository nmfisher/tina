import 'dart:convert';
import 'assembly.dart';
import 'config_settings_management.dart';
import 'plugin_build_contribution.dart';
import 'console_catalog.dart';
import 'plugin_catalog.dart';
import 'package:tina_providers/tina_providers.dart'
    show
        profileApproverModelSetting,
        profileMainModelSetting,
        profileSubagentModelSetting;
import 'package:tina_tui/tina_tui.dart';
import 'package:tina_host/tina_host.dart';

/// Application composition: concrete feature instances and configuration
/// services are wired here, never reached through by a view.
SessionPresentation presentationForAssembly(SessionAssembly assembly,
    {required SessionConnection connection,
    ConsoleViewFactory viewFactory = createConsoleView}) {
  // Settings whose text value is a `provider/model` ref, so they open the
  // searchable model picker instead of a free-form line. Wired once here;
  // every settings panel consults this list by setting identity before its
  // built-in editors. The three profile legs are the current values;
  // the deprecated classifier model stays on the plain text editor.
  final modelRefEditors = [
    ModelSettingEditor([
      profileMainModelSetting,
      profileSubagentModelSetting,
      profileApproverModelSetting,
    ])
  ];
  return SessionPresentation(
      theme: () => resolveTheme(assembly.theme),
      configNote: assembly.configNote,
      quitRequested: () => assembly.quitRequested,
      createViews: () => {
        for (final plugin in assembly.host.plugins)
          if (viewFactory(plugin, connection: connection) case final view?)
            plugin.id: view,
        // The host-side half of /plugins build: intercepts the command
        // family locally (the compile needs the local Dart SDK; the
        // engine component cannot spawn processes). Attached as a view
        // so the console's command-offering layer reaches it.
        'tina/plugin-build': PluginBuildContribution(connection),
      },
      listenViews: (loaded, unloading) => assembly.pluginManager.listen(
        loaded: (plugin) {
          if (viewFactory(plugin, connection: connection) case final view?)
            loaded(plugin.id, view);
        },
        unloading: (plugin) => unloading(plugin.id),
      ),
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
        final panel = SettingsPanel(context.screen, context.input,
            editors: modelRefEditors);
        return SessionSettingsView(
            open: () async {
              connection.access.requireControl();
              final saved = await panel.run(
                  sections: context.settings,
                  management: ConfigSettingsManagement(
                      access: connection.access,
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
              if (!saved) return 'Settings closed.';
              if (assembly.settings.applicationErrors.isNotEmpty) {
                return 'Some settings changes could not apply. Reopen Settings for details.';
              }
              if (!assembly.settingsBackend.persistsConfiguration) {
                return 'Settings updated for this Wasm session. Use the native settings editor for durable configuration.';
              }
              return 'Settings saved. Request settings affect the next request; plugin changes may wait for idle or restart.';
            },
            repaint: panel.repaint,
            close: panel.cancel);
      },
    );
}
