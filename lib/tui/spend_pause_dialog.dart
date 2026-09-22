import 'package:tina_console/tina_console.dart';
import 'prompts.dart';

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
  final session = Prompts.of(editor).open();
  final read = readEvent ?? session.read;

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
  final overlay = OverlayRegion(
    screen,
    Rect(row: row, col: col, width: boxW, height: boxH),
  );

  final boxed = [for (final l in raw) ' ${l.padRight(maxW)} '];
  void paint() {
    if (session.isActive) overlay.show(boxed);
  }

  session.attach(paint: paint, hide: overlay.hide);
  paint();
  try {
    while (true) {
      final ev = await read();
      if (ev is ControlKey && ev.code == ControlCode.enter) return true;
      if (ev is EscapeKey || ev is ControlKey && ev.code == ControlCode.ctrlC)
        return false;
      // Ignore everything else (arrows, other chars) until Enter/Esc.
    }
  } finally {
    overlay.hide();
    overlay.dispose();
    session.close();
  }
}
