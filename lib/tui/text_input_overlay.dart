import 'package:tina_console/tina_console.dart';

import 'spawn_overlay.dart' show modalTakeFocus, modalRestoreFocus;

Future<String?> runTextInputOverlay({
  required Screen screen,
  required LineEditor editor,
  required String prompt,
  Future<InputEvent> Function()? readEvent,
}) => _TextInputOverlay(
  screen: screen,
  editor: editor,
  prompt: prompt,
  readEvent: readEvent,
).run();

class _TextInputOverlay {
  final Screen screen;
  final LineEditor editor;
  final String prompt;
  final Future<InputEvent> Function()? readEvent;
  _TextInputOverlay({
    required this.screen,
    required this.editor,
    required this.prompt,
    this.readEvent,
  });

  Future<String?> run() async {
    var val = '';
    final lr = screen.layout;
    final w = (lr.width - 8).clamp(40, 80);
    final overlay = OverlayRegion(
      screen,
      Rect(row: lr.height ~/ 2, col: (lr.width - w) ~/ 2, width: w, height: 3),
    );

    List<String> frame() {
      final inner = w - 4;
      final shown = val.length > inner
          ? val.substring(val.length - inner)
          : val;
      final title = prompt.length > w - 4 ? prompt.substring(0, w - 4) : prompt;
      return [
        '┌ $title ${'─' * (w - 4 - title.length - 1)}┐',
        '│ $shown${' ' * (inner - shown.length)} │',
        '└${'─' * (w - 2)}┘',
      ];
    }

    void paint() => overlay.show(frame());

    final read = readEvent ?? editor.captureKeyReader();
    final prev = modalTakeFocus(editor);
    try {
      paint();
      while (true) {
        final ev = await read();
        if (ev is EscapeKey ||
            (ev is ControlKey && ev.code == ControlCode.ctrlC)) {
          return null;
        }
        if (ev is ControlKey &&
            (ev.code == ControlCode.enter || ev.code == ControlCode.ctrlS)) {
          return val;
        }
        if (ev is ControlKey && ev.code == ControlCode.backspace) {
          if (val.isNotEmpty) val = val.substring(0, val.length - 1);
        } else if (ev is CharInput) {
          val += ev.text;
        }
        paint();
      }
    } finally {
      overlay.hide();
      overlay.dispose();
      modalRestoreFocus(editor, prev);
    }
  }
}
