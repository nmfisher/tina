import 'package:tina_console/tina_console.dart';

import '../tui/settings_panel.dart' show activeAccent;
import '../tui/spawn_overlay.dart' show runListOverlay;

/// One selectable row in the session picker.
///
/// [live] entries switch to an already-open in-process session. On-disk entries
/// ([live] false) resume a saved session into the active conversation (what
/// `/resume <id>` does).
class SessionPickerEntry {
  final String id;
  final bool live;
  final String display;

  const SessionPickerEntry({
    required this.id,
    required this.live,
    required this.display,
  });
}

/// A session-picker overlay: lists live in-process sessions (active marked,
/// with running/unread badges) followed by saved-on-disk sessions that aren't
/// already live. Returns the chosen [SessionPickerEntry], or `null` on cancel
/// (Escape / Ctrl-C). The caller switches or resumes based on [entry.live].
///
/// Reuses [runListOverlay] — the same primitive the model/role pickers use — so
/// navigation, theming, and modal focus hand-off are identical.
Future<SessionPickerEntry?> runSessionPickerOverlay({
  required Screen screen,
  required LineEditor editor,
  required List<({
    String id,
    String label,
    bool isActive,
    bool isRunning,
    int unread
  })> live,
  List<({String id, String title, int messageCount})>? disk,
  String title = 'Switch session',
  Future<InputEvent> Function()? readEvent,
}) {
  final liveIds = live.map((s) => s.id).toSet();
  final resumable = (disk ?? const []).where((d) => !liveIds.contains(d.id));

  String badge(int n) => n > 9 ? '9+' : '$n';

  final entries = <({String display, SessionPickerEntry value})>[
    // Live sessions first — the common case (switch among open sessions).
    for (final s in live)
      (
        display:
            '${s.isActive ? '● ' : '  '}${s.label}${s.isRunning ? ' ⚡' : ''}'
            '${s.unread > 0 ? ' (${badge(s.unread)} new)' : ''}',
        value: SessionPickerEntry(id: s.id, live: true, display: s.label),
      ),
    // Then saved-on-disk sessions that aren't open — resumable.
    for (final d in resumable)
      (
        display: '↻ ${d.title}  (${d.messageCount}msg)',
        value: SessionPickerEntry(id: d.id, live: false, display: d.title),
      ),
  ];

  return runListOverlay<SessionPickerEntry>(
    screen: screen,
    editor: editor,
    entries: entries,
    title: title,
    footer: '↑↓ move · enter select · esc cancel',
    readEvent: readEvent,
    accent: activeAccent(screen),
  );
}
