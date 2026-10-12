import 'package:tina_console/tina_console.dart';
import 'package:tina_tui/tina_tui.dart';
import 'config_settings_management.dart';
import 'plugin_catalog.dart';
import 'settings_stack.dart';
import 'tui_session.dart';

/// The embedded CLI owns its root and child sessions. The reusable renderer
/// invokes these callbacks but has no access to their hosts or configuration.
Future<int> runTui(
  TuiSession session, {
  Screen? screen,
  LineEditor Function(Screen)? editorFor,
  ConsoleContext Function(Screen, LineEditor)? consoleContextFor,
  Stream<ScreenLayout>? resizes,
  String backend = 'auto',
  StartupTerminal? startup,
  Map<String, String>? environment,
}) async {
  final owned = <ConsoleSessionView, TuiSession>{};
  Future<void>? shutdownResult;
  Future<void> shutdown() => shutdownResult ??= Future.wait(
    {session, ...owned.values}.map((owner) => owner.shutdown()),
  );
  try {
    if (session.terminal is! SessionTerminal) {
      throw ArgumentError('runTui requires a SessionTerminal');
    }
    final view = session.createView(showConfig: true);
    owned[view] = session;
    return await runApp(
      view,
      screen: screen,
      editorFor: editorFor,
      consoleContextFor: consoleContextFor,
      resizes: resizes,
      backend: backend,
      startup: startup,
      environment: environment,
      workspace: session.createWorkspace(),
      createSession: (model) async {
        final child = session.spawn(model);
        try {
          final childView = child.createView();
          owned[childView] = child;
          return childView;
        } catch (_) {
          await child.shutdown();
          rethrow;
        }
      },
      onViewClosed: (view, pendingWork) async {
        final owner = owned[view];
        if (owner == null) return;
        // The root supplies configuration and new sessions until app exit.
        if (identical(owner, session)) {
          owner.cancel();
          await pendingWork;
        } else {
          await Future.wait([owner.shutdown(), pendingWork]);
        }
        owned.remove(view);
      },
      onExit: shutdown,
    );
  } finally {
    // Also covers screen initialization and workspace failures before teardown.
    for (final view in owned.keys) {
      view.close();
    }
    await shutdown();
  }
}

/// Initial configuration has no conversation or session settings layer.
/// The application owns the stack; the editor receives checked operations.
Future<bool> runConfigEditor(
  String path, {
  String backend = 'auto',
  StartupTerminal? startup,
}) async {
  final descriptors = configuredDescriptors();
  final stack = ScopedSettingsStack.build(
    globalPath: path,
    workspacePath: path,
    descriptors: descriptors,
  );
  final management = ConfigSettingsManagement(
    scopedSettings: stack.settings,
    backend: stack.backend,
    descriptors: descriptors,
    pluginDescriptions: pluginDescriptions(stack.registry),
    validatePlugins: stack.registry.validate,
  );
  try {
    return await runSettingsEditor(
      management,
      backend: backend,
      startup: startup,
    );
  } finally {
    management.close();
    stack.settings.close();
  }
}
