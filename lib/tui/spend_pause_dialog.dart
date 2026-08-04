import 'package:tina_console/tina_console.dart';

/// Modal shown when an agent trips its per-session token limit and pauses all
/// agents. Returns `true` for Continue (resume + reset), `false` for Abort (Esc
/// — abort the tripped agent's turn). Driven by [LineEditor.readKey] — the
/// exclusive-capture path also used by the permission/setup modals; serialized
/// with them by the editor's readKey mutex, so a trip during `/settings` or an
/// `askPermission` y/n waits its turn rather than orphaning that readKey.
/// [readEvent] is injectable for tests.
Future<bool> runSpendPauseDialog({
  required Screen screen,
  required LineEditor editor,
  Future<InputEvent> Function()? readEvent,
}) async {
  final read = readEvent ?? editor.readKey;

  final raw = <String>[
    'Per-session token limit reached.',
    'All agents are paused.',
    '',
    '[Enter] continue    [Esc] abort',
  ];
  final maxW = raw.fold(0, (m, l) => l.length > m ? l.length : m);
  final boxW = maxW + 4;
  final boxH = raw.length + 2;
  final row = (screen.layout.height - boxH) ~/ 2;
  final col = (screen.layout.width - boxW) ~/ 2;
  final overlay = OverlayRegion(screen, Rect(row: row, col: col, width: boxW, height: boxH));

  final boxed = [for (final l in raw) ' ${l.padRight(maxW)} '];
  overlay.show(boxed);
  try {
    while (true) {
      final ev = await read();
      if (ev is ControlKey && ev.code == ControlCode.enter) return true;
      if (ev is EscapeKey) return false;
      // Ignore everything else (arrows, other chars) until Enter/Esc.
    }
  } finally {
    // Re-show before hide: sub-agent streams may have overprinted the overlay
    // while the dialog was up (the pause parks them at their NEXT request, but
    // ones already mid-stream finish first). This leaves the last painted state
    // matching what the user saw.
    overlay.show(boxed);
    overlay.hide();
    overlay.dispose();
  }
}
