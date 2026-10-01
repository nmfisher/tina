import 'dart:io';

import 'package:tina_console/tina_console.dart';
import 'package:tina_persistence/tina_persistence.dart';

/// Main sessions in local activity order. Reading absent history never creates
/// a store, and child sessions cannot accidentally become the next CLI session.
List<StoredSession> resumableSessions(String path) {
  if (!File(path).existsSync()) {
    throw SessionStoreException('no session store at $path');
  }
  final store = SessionStore.open(path);
  try {
    return store.list().where((s) => (s.details?.depth ?? 0) == 0).toList()
      ..sort((a, b) => b.lastActivityKey.compareTo(a.lastActivityKey));
  } finally {
    store.close();
  }
}

/// A line-based picker before the full-screen terminal starts. Blank input,
/// q and EOF cancel without starting an agent or contacting a provider.
String? pickSession(
  List<StoredSession> sessions, {
  required String? Function() readLine,
  required void Function(String) writeLine,
}) {
  for (var i = 0; i < sessions.length; i++) {
    final s = sessions[i];
    // Persisted titles must not inject terminal control sequences.
    final id = s.id.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');
    final summary = _preview(s);
    writeLine(
        '${i + 1}. ${sessionSavedTime(s)}  $summary  ($id, ${s.entries} entries)');
  }
  while (sessions.isNotEmpty) {
    writeLine('Select session [1-${sessions.length}], or Enter/q to cancel:');
    final answer = readLine()?.trim();
    if (answer == null || answer.isEmpty || answer.toLowerCase() == 'q') {
      return null;
    }
    final number = int.tryParse(answer);
    if (number != null && number >= 1 && number <= sessions.length) {
      return sessions[number - 1].id;
    }
    writeLine('Enter a number from 1 to ${sessions.length}.');
  }
  return null;
}

String _preview(StoredSession session) {
  final title = session.title?.trim();
  final text = title != null && title.isNotEmpty
      ? title
      : session.summary ?? 'Untitled session';
  return clipDialogText(text, 160);
}

String sessionSavedTime(StoredSession session) {
  final at = session.lastSavedAt?.toLocal();
  if (at == null) return 'Unknown save time';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
}

/// Startup UI only: selecting a session neither assembles plugins nor calls a
/// model. The caller owns terminal setup/cleanup and resize notifications.
class SessionPicker {
  SessionPicker(this.screen, this.editor, this.sessions, {this.readEvent});
  final Screen screen;
  final LineEditor editor;
  final List<StoredSession> sessions;
  final Future<InputEvent> Function()? readEvent;
  OverlayRegion? _overlay;
  int _selected = 0, _top = 0, _page = 1;

  void repaint() {
    final overlay = _overlay;
    if (overlay == null) return;
    final area = dialogArea(screen.layout);
    final width = area.width.clamp(0, 110);
    final height = area.height;
    final twoRows = height >= 8;
    final rowsPerSession = twoRows ? 2 : 1;
    _page = ((height - 4) ~/ rowsPerSession).clamp(1, sessions.length);
    if (_selected < _top) _top = _selected;
    if (_selected >= _top + _page) _top = _selected - _page + 1;
    final body = <String>[];
    for (var i = _top; i < sessions.length && i < _top + _page; i++) {
      final session = sessions[i];
      final marker = i == _selected ? '❯' : ' ';
      final text = '$marker ${sessionSavedTime(session)}  ${_preview(session)}';
      body.add(i == _selected
          ? screen.colorize(screen.theme.border.selection, text)
          : text);
      if (twoRows) {
        body.add(screen.colorize(screen.theme.chat.dim,
            '  ${clipDialogText(session.model ?? '', width)}  ${clipDialogText(session.id, width)}'));
      }
    }
    final footer = '↑↓ choose · Enter resume · Esc cancel';
    final lines = height < 4
        ? [body.first, footer].take(height).toList()
        : dialogBoxLines(
            width: width,
            height: height,
            title:
                'Resume session · ${_selected + 1}/${sessions.length} · last saved (local)',
            body: body,
            footer: footer,
            paint: (text) => screen.colorize(screen.theme.border.focus, text));
    overlay.update(
        bounds: Rect(
            row: area.row,
            col: area.col + (area.width - width) ~/ 2,
            width: width,
            height: height),
        lines: lines);
  }

  Future<String?> run() async {
    if (sessions.isEmpty) return null;
    _overlay = OverlayRegion(screen, Rect.empty);
    final next = readEvent ?? editor.captureKeyReader();
    try {
      repaint();
      while (true) {
        final event = await next();
        if (event is EscapeKey ||
            (event is ControlKey &&
                (event.code == ControlCode.ctrlC ||
                    event.code == ControlCode.ctrlD))) {
          return null;
        }
        if (event is ControlKey && event.code == ControlCode.enter) {
          return sessions[_selected].id;
        }
        if (event is ArrowKey) {
          _selected = switch (event.direction) {
            ArrowDirection.up => (_selected - 1).clamp(0, sessions.length - 1),
            ArrowDirection.down =>
              (_selected + 1).clamp(0, sessions.length - 1),
            ArrowDirection.pageUp =>
              (_selected - _page).clamp(0, sessions.length - 1),
            ArrowDirection.pageDown =>
              (_selected + _page).clamp(0, sessions.length - 1),
            _ => _selected,
          };
        }
        repaint();
      }
    } finally {
      _overlay!.hide();
      _overlay!.dispose();
      _overlay = null;
    }
  }
}
