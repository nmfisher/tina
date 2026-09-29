import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_plans/tina_plans.dart';
import 'plan_overlay.dart';

/// The single plans plugin with its optional console attachment.
final class PlansConsolePlugin extends PlansPlugin
    implements ConsoleContribution {
  PlansConsolePlugin({super.terminal, super.approver});
  AgentLoop? _loop;
  ConsoleContext? _console;
  PlanOverlay? overlay;
  void Function()? _release;

  @override
  void mountOn(AgentLoop loop) {
    _loop = loop;
    super.mountOn(loop);
  }

  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    overlay = PlanOverlay(
        screen: context.screen,
        store: store,
        loop: _loop!,
        context: context,
        focusManager: context.input.focusManager)
      ..start();
    final shortcut = context.bindShortcut((event) {
      if (event is ControlKey && event.code == ControlCode.ctrlP) {
        overlay?.toggle();
        return true;
      }
      return false;
    });
    context.screen.registerAnimation(repaintConsole);
    _release = context.own(() {
      shortcut();
      context.screen.unregisterAnimation(repaintConsole);
      overlay?.dispose();
      overlay = null;
    });
  }

  @override
  void repaintConsole() => overlay?.refresh();

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
