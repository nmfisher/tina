import 'dart:async';

import 'package:classification/observation.dart';
import 'package:tina_console/tina_console.dart';

import 'classification_panel.dart';

/// One attachment's inspector. Inference and history belong to the runtime.
final class ClassificationView
    implements ConsoleContribution, ConsoleCommandHandler {
  ClassificationView(this.classification);
  final ClassificationObservation classification;
  ConsoleContext? _console;
  ClassificationPanel? panel;
  void Function()? _release;

  @override
  Future<void>? handleConsoleCommand(String name, String arguments) {
    if (name != 'classification' ||
        arguments.trim() == 'categories' ||
        _console?.isActive != true ||
        panel == null)
      return null;
    panel!.show(hierarchy: arguments.trim() == 'hierarchy' ? true : null);
    return Future.value();
  }

  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    final inspector = panel = ClassificationPanel(
      classification: classification,
      context: context,
    );
    // Register cleanup before starting, so partial attachment failures release
    // subscriptions, animations and any panel resources already acquired.
    final release = classification.listen(repaintConsole);
    final shortcut = context.bindShortcut((event) {
      if (event is FunctionKey && event.code == FunctionKeyCode.f6) {
        inspector.toggle();
        return true;
      }
      return false;
    });
    context.screen.registerAnimation(repaintConsole);
    _release = context.own(() {
      release();
      shortcut();
      context.screen.unregisterAnimation(repaintConsole);
      inspector.dispose();
      if (identical(panel, inspector)) panel = null;
    });
    inspector.start();
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
}
