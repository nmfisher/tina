import 'dart:async';
import 'package:classification/plugin.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart'
    show Terminal, LlmProvider, Command;
import 'classification_panel.dart';

/// Presentation adapter for the single tina/classification plugin. Inference
/// remains in the terminal-independent classification package.
final class ClassificationConsolePlugin extends ClassificationPlugin
    implements ConsoleContribution {
  ClassificationConsolePlugin(
      {required super.terminal,
      required super.open,
      super.categories,
      super.learner,
      super.timeout});
  ClassificationConsolePlugin.configured(
      {required Terminal terminal,
      required String configPath,
      required LlmProvider Function() createProvider})
      : super(
            terminal: terminal,
            open: () => openConfiguredClassification(configPath),
            categories: openClassificationCategories(configPath),
            learner: MainAgentCategoryLearner(createProvider),
            timeout: const Duration(seconds: 90));
  ConsoleContext? _console;
  ClassificationPanel? panel;
  void Function()? _release;
  @override
  List<Command> get commands => [
        Command(
          name: 'classification',
          description:
              'inspect live classifier requests, replies, and hierarchy',
          handler: (arguments) async {
            if (arguments.trim() == 'categories' || panel == null) {
              await super.commands.single.handler(arguments);
            } else {
              panel!.show(
                  hierarchy: arguments.trim() == 'hierarchy' ? true : null);
            }
          },
        )
      ];
  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    panel = ClassificationPanel(plugin: this, context: context)..start();
    final subscription = changes.listen((_) => repaintConsole());
    final traceSubscription = trace.changes.listen((_) => repaintConsole());
    final shortcut = context.bindShortcut((event) {
      if (event is FunctionKey && event.code == FunctionKeyCode.f6) {
        panel?.toggle();
        return true;
      }
      return false;
    });
    context.screen.registerAnimation(repaintConsole);
    _release = context.own(() {
      unawaited(subscription.cancel());
      unawaited(traceSubscription.cancel());
      shortcut();
      context.screen.unregisterAnimation(repaintConsole);
      panel?.dispose();
      panel = null;
    });
  }

  @override
  void repaintConsole() => panel?.refresh();
  @override
  void detachConsole() {
    _release?.call();
    _release = null;
    _console?.chat.repaint();
    _console = null;
  }

  @override
  void closeSession() {
    detachConsole();
    super.closeSession();
  }
}
