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
/// hook, and switches on the command word exactly as the controller used to.
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

  /// Legacy adapter for existing integrations. Each family receives a narrow view.
  SessionCommandHandlers(
    CommandContext context, {
    ReleaseChecker? Function(Map<String, String> env)? releaseCheckerFactory,
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

  /// Seam for tests: builds the [ReleaseChecker] `/update` uses. Production
  /// calls leave it null and a real checker (with [Platform.environment])
  /// is constructed per invocation and closed afterwards.

  /// Every recognized slash command, in display order — derived from the
  /// command registry ([registry], via [SessionCommandRegistry.allNames]),
  /// which remains the single source of truth for [dispatch] and the `/`
  /// command-completion palette ([CommandCompletionProvider]). Kept as a
  /// getter (not deleted) because existing tests and callers name it; the
  /// compiler-checked derivation cannot drift from the registry.
  static List<String> get allCommands => registry.allNames;

  /// The ordered command table every command surface dispatches, completes,
  /// and renders help from. Replaced once at startup by [configureFeatures] so
  /// the disabled-feature filtering is decided in one place; before that call
  /// it holds the full table (which is what unit tests want).
  static SessionCommandRegistry registry = SessionCommandRegistry(
    _kSessionCommandEntries,
  );

  /// Point dispatch, `/help`, and the `/` completion palette at the features
  /// this session actually has. Called once by the TUI before it reads any
  /// input; idempotent, so calling it again (or from a second entry point) is
  /// harmless.
  static void configureFeatures({required bool workflow}) {
    registry = SessionCommandRegistry(
      _kSessionCommandEntries,
      hiddenFeatures: workflow
          ? const <String>{}
          : const <String>{kWorkflowFeature},
    );
  }

  Future<CmdResult> dispatch(String trimmed) async {
    final word = trimmed.split(RegExp(r'\s+')).first;
    final entry = registry.lookup(word);
    if (entry == null) {
      if (word.startsWith('/')) {
        ctx.active.host.showMessage(
          '$word: unknown command\n',
          style: HostMessageStyle.error,
        );
        return const CmdHandled();
      }
      return const CmdNotCommand();
    }

    ctx.active.host.showMessage('$trimmed\n', style: HostMessageStyle.user);
    ctx.active.host.showSeparator();

    // Run any registered hook for this command before the default action. The
    // hook may prepare or clear state that the default handler then acts on.
    // Keyed by the typed word, so hooks fire for aliases too (`/quit` fires
    // the `/quit` hook, not the `/exit` one).
    final hook = ctx.commandHooks[word];
    if (hook != null) {
      await hook();
    }

    return entry.handler(this, trimmed);
  }

  void _printHelp() {
    // Rendered structurally from the command registry — same bytes as the
    // pre-registry literal (golden-tested in
    // test/session_commands/session_command_registry_test.dart).
    ctx.active.host.showMessage(registry.renderHelp());
  }
}
