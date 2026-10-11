import 'dart:async';

import 'package:tina_console/tina_console.dart';
import 'package:tina_plans/tina_plans.dart';
import 'plan_overlay.dart';

/// One console's presentation of the session-owned plans feature.
final class PlansView implements ConsoleContribution {
  PlansView(this.plans);
  final PlanObservation plans;
  ConsoleContext? _console;
  PlanOverlay? overlay;
  void Function()? _release;

  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    final browser = PlanOverlay(
      screen: context.screen,
      plans: plans,
      context: context,
      focusManager: context.input.focusManager,
    );
    overlay = browser;
    void Function()? shortcut;
    void Function()? releaseStatus;
    StreamSubscription<void>? statusChanges;
    final repaintOverlay = browser.refresh;
    _release = context.own(() {
      shortcut?.call();
      unawaited(statusChanges?.cancel());
      releaseStatus?.call();
      context.screen.unregisterAnimation(repaintOverlay);
      browser.dispose();
      overlay = null;
    });
    // Preserve the plan's place before the chat's goal/session status lines.
    releaseStatus = context.bindStatus(_statusLines, priority: 90);
    statusChanges = plans.changes.listen((_) {
      if (context.isActive) context.refreshStatus();
    });
    browser.start();
    shortcut = context.bindShortcut((event) {
      if (event is ControlKey && event.code == ControlCode.ctrlP) {
        overlay?.toggle();
        return true;
      }
      return false;
    });
    context.screen.registerAnimation(repaintOverlay);
  }

  @override
  void repaintConsole() {
    overlay?.refresh();
    _console?.refreshStatus();
  }

  List<RenderLine> _statusLines() {
    final console = _console;
    final plan = plans.state;
    if (console == null || plan.isEmpty) return const [];
    final items = plan.items;
    final active =
        items.where((item) => item.state == 'in_progress').firstOrNull?.text;
    return [
      RenderLine(runs: [
        RenderRun('plan: ', console.screen.theme.chat.dim),
        RenderRun(
            [
              if (active != null) active,
              '${items.where((item) => item.state == 'done').length}/${items.length} done',
              if (plan.needsApproval) 'needs approval',
            ].join(' · '),
            null),
      ]),
    ];
  }

  @override
  void detachConsole() {
    _release?.call();
    _release = null;
    _console?.chat.repaint();
    _console = null;
  }
}
