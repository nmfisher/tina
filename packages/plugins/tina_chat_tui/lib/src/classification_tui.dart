import 'dart:async';
import 'package:classification/plugin.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart' show Terminal;

/// Presentation adapter for the single tina/classification plugin. Inference
/// remains in the terminal-independent classification package.
final class ClassificationConsolePlugin extends ClassificationPlugin
    implements ConsoleContribution {
  ClassificationConsolePlugin.configured(
      {required Terminal terminal, required String configPath})
      : super(
            terminal: terminal,
            open: () => openConfiguredClassification(configPath));
  ConsoleContext? _console;
  void Function()? _release;
  void Function()? _unsubscribe;
  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    _release = context.bindStatus(
        () => status.phase == ClassificationPhase.idle
            ? []
            : [
                RenderLine(runs: [
                  RenderRun(
                      'intent: ${status.label}', context.screen.theme.chat.dim)
                ])
              ],
        priority: 30);
    final subscription = changes.listen((_) => repaintConsole());
    _unsubscribe = context.own(() => unawaited(subscription.cancel()));
  }

  @override
  void repaintConsole() => _console?.refreshStatus();
  @override
  void detachConsole() {
    _unsubscribe?.call();
    _unsubscribe = null;
    _release?.call();
    _release = null;
    _console = null;
  }

  @override
  void closeSession() {
    detachConsole();
    super.closeSession();
  }
}
