import 'dart:typed_data';

import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// Regression coverage for tin-6a2f: a background writer streaming while an
/// approval prompt awaits its answer character must NOT merge its text onto
/// the prompt's open row. The approval's prompt+answer pair carries a row
/// ownership token (TuiConversationHost.askPermission); any other writer's
/// text starts a fresh row instead of appending to the owned partial row.
void main() {
  test('background writer during a pending approval starts its own row',
      () {
    final io = FakeStdio()..columns = 80;
    final backend = _RecordingBackend();
    final screen = Screen.withBackend(
      backend: backend,
      io: io,
      layout: ScreenLayout.fromSize(80, 24, split: false),
      clock: () => _now(),
    );
    final chat = screen.chat;
    chat.handleResize();

    // Approval A: header (complete row), prompt (owned partial row). While
    // the readKey pends, a background writer (the env ceremony) streams a
    // chunk ending with a newline. Then the answer arrives.
    chat.yellow('  bash: pwd && ls -la\n');
    final token = Object();
    chat.write('  approve? [y/n/a/d]  (a/d remember "pwd && ls -la") › ',
        rowOwner: token);
    chat.write('This repository is a small Dart monorepo.\n');
    chat.write('y\n', rowOwner: token);
    // Approval B: header + prompt.
    chat.yellow('  bash: pwd\n');
    chat.write('  approve? [y/n/a/d]  (a/d remember "pwd") › ');
    // One presentation for the whole window.
    screen.absorbPendingChat();

    final surface = backend.surface;
    final rows = <int, String>{};
    for (final call in surface.putAtCalls) {
      rows[call.relRow] = call.text; // last write wins, like the real surface
    }
    final texts = rows.values.join('\n');

    // The approval prompt row holds exactly the prompt — the background
    // chunk never lands on it (pre-fix it was spliced in: "…› This
    // repository is a small Dart monorepo.").
    expect(
      texts,
      contains('approve? [y/n/a/d]  (a/d remember "pwd && ls -la") › \n'),
      reason: 'the prompt row must not carry the background chunk',
    );
    // The background chunk renders on its own row, not spliced into the
    // prompt line.
    expect(
      texts,
      contains('This repository is a small Dart monorepo.\n'),
    );
    // The answer character is displayed (its own row — the interleaved
    // writer pushed it off the prompt row, but it must never be lost).
    expect(
      texts,
      contains('\ny\n'),
      reason: 'the answer char must render',
    );
    // The second approval is untouched.
    expect(
      texts,
      contains('approve? [y/n/a/d]  (a/d remember "pwd") › '),
    );
  });

  test('unowned streaming chunks still append to each other', () {
    // Sanity: without an owner, consecutive chunks join on one row (the
    // normal streaming behavior must not regress).
    final io = FakeStdio()..columns = 80;
    final backend = _RecordingBackend();
    final screen = Screen.withBackend(
      backend: backend,
      io: io,
      layout: ScreenLayout.fromSize(80, 24, split: false),
      clock: () => _now(),
    );
    final chat = screen.chat;
    chat.handleResize();
    chat.write('first chunk ');
    chat.write('second chunk\n');
    screen.absorbPendingChat();

    final rows = <int, String>{};
    for (final call in backend.surface.putAtCalls) {
      rows[call.relRow] = call.text;
    }
    expect(rows.values.join('\n'), contains('first chunk second chunk'));
  });
}

int _now() => _t++;
int _t = 0;

class _RecordingBackend implements TerminalBackend {
  late _RecSurface surface;

  @override
  BackendSurface createSurface(Rect bounds) {
    surface = _RecSurface(bounds);
    return surface;
  }

  @override
  bool get coalescesPaints => true;
  @override
  bool get supportsColor => true;
  @override
  String colorize(String code, String text) => text;
  @override
  Stream<List<int>> get stdin => const Stream.empty();
  @override
  int get terminalColumns => 80;
  @override
  void beginFrame() {}
  @override
  void endFrame() {}
  @override
  void moveCursor(int row, int col) {}
  @override
  void parkCursor(int row, int col) {}
  @override
  void eraseCells(int row, int col, int n) {}
  @override
  void writeText(String text) {}
  @override
  void saveCursor() {}
  @override
  void restoreCursor() {}
  @override
  void flush() {}
  @override
  void refresh() {}
  @override
  void enterAltScreen() {}
  @override
  void leaveAltScreen() {}
  @override
  void enableBracketedPaste() {}
  @override
  void disableBracketedPaste() {}
  @override
  void renderImageAbsolute({
    required int row,
    required int col,
    required Uint32List rgba,
    required int width,
    required int height,
    required int maxCols,
    BackendSurface? targetSurface,
  }) {}
}

class _RecSurface implements BackendSurface {
  final List<({int relRow, String text})> putAtCalls = [];

  _RecSurface(this.bounds);

  @override
  Rect bounds;

  @override
  void putAt({
    required int relRow,
    required int relCol,
    required String text,
    required int maxCols,
    required bool moveCursor,
    int? clearCells,
  }) {
    putAtCalls.add((relRow: relRow, text: text));
  }

  @override
  void eraseAt({
    required int relRow,
    required int relCol,
    required int n,
    required bool moveCursor,
  }) {}

  @override
  void moveTo(int row, int col) {}
  @override
  void resize(int width, int height) {}
  @override
  bool scrollRows(int count) => true;
  @override
  void raiseToTop() {}
  @override
  void lowerToBottom() {}
  @override
  void destroy() {}
}
