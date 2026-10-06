import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

import 'status_layout.dart';

/// Owns the status strip's arrangement on behalf of the session.
///
/// Producers keep using `bindStatus` unchanged: this plugin never renders a
/// line of its own. It only decides how the producers' lines, plus the host
/// mode label, are arranged into the strip row under width pressure — by
/// installing [PriorityStatusLayout] on the screen's single layout slot.
///
/// The slot is exclusive by construction: the screen holds one
/// [StatusLayout] at a time and falls back to `DefaultStatusLayout` when it
/// is cleared or throws. Attaching takes the slot; detaching returns it to
/// the default, so unloading this plugin restores the stock bar. A plugin
/// that wants a different bar ships its own `StatusLayout` and takes the
/// slot the same way — arranging is data-in/rows-out, testable without a
/// screen.
final class StatusStripTuiPlugin extends AgentPlugin
    implements ConsoleContribution {
  StatusStripTuiPlugin();

  @override
  String get id => 'tina/status-strip-tui';

  ConsoleContext? _console;

  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    // The slot is shared across conversation panels; a background view must
    // not rearrange the focused view's bar on attach. The screen repaints
    // the strip itself when the slot changes.
    if (context.isActive) {
      context.screen.setStatusLayout(const PriorityStatusLayout());
    }
  }

  @override
  void repaintConsole() {
    final console = _console;
    if (console == null || !console.isActive) return;
    console.screen.setStatusLayout(const PriorityStatusLayout());
  }

  @override
  void detachConsole() {
    final console = _console;
    _console = null;
    if (console?.isActive == true) console!.screen.setStatusLayout(null);
  }

  @override
  void closeSession() => detachConsole();
}
