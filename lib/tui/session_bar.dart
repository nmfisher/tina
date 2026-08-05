import 'package:tina_console/tina_console.dart';

/// A session's display summary for the session bar / picker.
typedef SessionSummary = ({
  String id,
  String label,
  bool isActive,
  bool isRunning,
  int unread,
});

/// A compact, always-refreshed session list rendered into the screen's info
/// region — a tmux-style window bar. Each open session is shown with an active
/// marker, a running indicator, and an unread badge for background activity.
///
/// Backed by [InfoPanel] (the screen's static info surface), so it uses only
/// public region APIs — no border/backend reaching. It renders when there are
/// no spawned side panels competing for the info column and there is more than
/// one session; otherwise it hides (and the session picker, Alt+S, remains the
/// always-available switcher). Refreshed by the coordinator on every session
/// change and on resize.
class SessionBar {
  final InfoPanel _panel;

  SessionBar(Screen screen) : _panel = InfoPanel(screen, title: 'sessions');

  /// Repaint the bar from [sessions]. Pass [hasSidePanels] = true to hide it
  /// (spawned panels own the info column then).
  void refresh({
    required List<SessionSummary> sessions,
    required bool hasSidePanels,
  }) {
    if (hasSidePanels || sessions.length <= 1) {
      // Nothing to show: a single session needs no bar, and side panels own
      // the column. Hide so we never fight a spawned panel for pixels.
      _panel.hide();
      return;
    }
    final lines = <String>[];
    for (var i = 0; i < sessions.length && i < 9; i++) {
      final s = sessions[i];
      final marker = s.isActive ? '●' : ' ';
      final running = s.isRunning ? ' ⚡' : '';
      final unread =
          s.unread > 0 ? ' (${s.unread > 9 ? "9+" : s.unread})' : '';
      // Truncate long model labels so the narrow info column stays readable.
      final label =
          s.label.length > 18 ? '${s.label.substring(0, 17)}…' : s.label;
      lines.add('$marker${i + 1} $label$running$unread');
    }
    if (sessions.length > 9) {
      lines.add('  …+${sessions.length - 9}');
    }
    _panel.setContent(lines);
    _panel.show();
  }

  /// Clear the bar (e.g. on teardown).
  void hide() => _panel.hide();
}
