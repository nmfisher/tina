import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';

import '../self_update/release_checker.dart';
import '../self_update/updater.dart';
import '../version.g.dart';
import 'package:tina_app/tina_app.dart';
import '../tmux/tmux_support.dart';

part 'session_command_registry.dart';
part 'command_families.dart';

/// Names the DOT-workflow feature in [SessionCommandEntry.feature] so the
/// `/workflow` command disappears with the rest of the surface when it is
/// disabled (see [RuntimeConfig.enableWorkflow]).
const kWorkflowFeature = 'workflow';

/// The slash-command handlers, lifted out of [SessionController] so they can be
/// read and tested in isolation. Operates purely through a [CommandContext] —
/// no input loop, no host of its own. [dispatch] is the entry point the
/// controller calls each input line; it echoes the command, runs any registered
/// hook, and dispatches through the scoped plugin command registry.
class SessionCommandHandlers {
  final DispatchCapabilities ctx;
  final UsageCommands usage;
  final UpdateCommands update;
  final FrontendCommands frontend;
  final SessionsCommands sessions;
  final HistoryCommands history;
  final PermissionsCommands permissions;
  final IndexCommands index;
  final WorkflowCapabilities workflow;
  final PluginScope? pluginScope;
  final Set<String>? hiddenFeatures;
  PluginRuntime? _runtime;
  CommandRegistry? _commands;

  /// Legacy adapter for existing integrations. Each family receives a narrow view.
  SessionCommandHandlers(
    CommandContext context, {
    ReleaseChecker? Function(Map<String, String> env)? releaseCheckerFactory,
    PluginScope? pluginScope,
    Set<String>? hiddenFeatures,
  }) : this.withCapabilities(
         dispatch: context,
         usage: context,
         update: context,
         frontend: context,
         sessions: context,
         history: context,
         permissions: context,
         index: context,
         workflow: context,
         releaseCheckerFactory: releaseCheckerFactory,
         pluginScope: pluginScope,
         hiddenFeatures: hiddenFeatures,
       );

  SessionCommandHandlers.withCapabilities({
    required DispatchCapabilities dispatch,
    required UsageCapabilities usage,
    required UpdateCapabilities update,
    required FrontendCapabilities frontend,
    required SessionsCapabilities sessions,
    required HistoryCapabilities history,
    required PermissionsCapabilities permissions,
    required IndexCapabilities index,
    required this.workflow,
    this.pluginScope,
    this.hiddenFeatures,
    ReleaseChecker? Function(Map<String, String> env)? releaseCheckerFactory,
  }) : ctx = dispatch,
       usage = UsageCommands(usage),
       update = UpdateCommands(
         update,
         releaseCheckerFactory: releaseCheckerFactory,
       ),
       frontend = FrontendCommands(frontend),
       sessions = SessionsCommands(sessions),
       history = HistoryCommands(history),
       permissions = PermissionsCommands(permissions),
       index = IndexCommands(index);

  /// Built-ins and extensions are ordinary contributions in one live view.
  /// The frontend-owned child borrows app plugins and never disposes them.
  CommandRegistry get commands {
    if (_commands != null) return _commands!;
    final runtime = PluginRuntime(
      name: 'session-commands',
      parent: pluginScope,
      plugins: [
        PluginDescriptor(
          id: 'tina.commands',
          factory: FnPluginFactory((context) {
            for (final entry in _kSessionCommandEntries) {
              context.register(
                Command(
                  names: entry.names,
                  argsHint: entry.argsHint,
                  summary: entry.summary,
                  helpOrder: entry.helpOrder,
                  helpContinuation: entry.helpContinuation,
                  inHelp: entry.inHelp,
                  feature: entry.feature,
                  handler: (call) => entry.handler(this, call.line),
                ),
                id: 'tina.command.${entry.primary.substring(1)}',
              );
            }
            return Object();
          }),
        ),
      ],
    );
    _runtime = runtime;
    runtime.activateSync();
    return _commands = CommandRegistry(
      runtime.scope,
      hiddenFeatures: hiddenFeatures ?? registry.hiddenFeatures,
    );
  }

  Future<void> dispose() async => _runtime?.dispose();

  /// Compatibility catalog of built-in names. Live frontends use [commands],
  /// which includes plugin contributions and per-instance feature settings.
  static List<String> get allCommands => registry.allNames;

  /// Compatibility metadata only; not used for live dispatch or help.
  static SessionCommandRegistry registry = SessionCommandRegistry(
    _kSessionCommandEntries,
  );

  /// Legacy catalog configuration. New frontends pass [hiddenFeatures] on
  /// construction so one frontend cannot change another's command surface.
  static void configureFeatures({required bool workflow}) {
    registry = SessionCommandRegistry(
      _kSessionCommandEntries,
      hiddenFeatures: workflow
          ? const <String>{}
          : const <String>{kWorkflowFeature},
    );
  }

  Future<CmdResult> dispatch(String trimmed, {Future<void>? cancelSignal}) =>
      commands.dispatch(
        trimmed,
        host: ctx.active.host,
        conversationId: ctx.active.id,
        cancelSignal: cancelSignal,
        hooks: ctx.commandHooks,
      );

  void _printHelp() {
    // Rendered structurally from the command registry — same bytes as the
    // pre-registry literal (golden-tested in
    // test/session_commands/session_command_registry_test.dart).
    ctx.active.host.showMessage(commands.renderHelp());
  }
}
