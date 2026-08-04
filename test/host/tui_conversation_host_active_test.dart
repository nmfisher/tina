import 'dart:async';
import 'dart:typed_data';

import 'package:tina_console/tina_console.dart';
import 'package:tina/host/tui_conversation_host.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';

/// A [TerminalBackend] that records every cell erase at its absolute (row, col),
/// so a test can tell whether the chat area was blanked during a host state
/// change. A real terminal would show a blanked chat area as a flicker; this
/// captures the same signal without rendering.
class _RecordBackend implements TerminalBackend {
  final List<({int row, int col, int n})> erases = [];

  void clear() => erases.clear();

  @override
  void beginFrame() {}

  @override
  void endFrame() {}

  @override
  void parkCursor(int row, int col) {}

  @override
  void moveCursor(int row, int col) {}

  @override
  void eraseCells(int row, int col, int n) => erases.add((row: row, col: col, n: n));

  @override
  void writeText(String text) {}

  @override
  void saveCursor() {}

  @override
  void restoreCursor() {}

  @override
  void flush() {}

  @override
  void enterAltScreen() {}

  @override
  void leaveAltScreen() {}

  @override
  void enableBracketedPaste() {}

  @override
  void disableBracketedPaste() {}

  @override
  bool get supportsColor => true;

  @override
  String colorize(String code, String text) => '\x1b[${code}m$text\x1b[0m';

  @override
  Stream<List<int>> get stdin => const Stream.empty();

  @override
  int get terminalColumns => 120;

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

  @override
  BackendSurface createSurface(Rect bounds) =>
      throw UnimplementedError('not used in this test');

  @override
  bool get coalescesPaints => false;
}

void main() {
  // Regression guard for the spawned -> main focus-return flicker. Re-activating
  // a PRIMARY host whose chat region was never detached (the side-panel-shared
  // screen case, where stayAttachedWhenInactive keeps it visible) must NOT blank
  // the chat area. The erase+attach recovery is only correct when the region was
  // actually hidden — otherwise it reads as a blank-then-redraw flicker. The
  // recovery path itself is covered by the second test below.
  group('TuiConversationHost.setActive (primary)', () {
    late _RecordBackend backend;
    late Screen screen;
    late Spinner spinner;
    late TuiConversationHost host;

    setUp(() {
      final io = FakeStdio()
        ..columns = 120
        ..hasTerminalValue = false;
      final layout = ScreenLayout.fromSize(120, 24);
      backend = _RecordBackend();
      screen = Screen.withBackend(
        backend: backend,
        io: io,
        layout: layout,
        ansi: AnsiCapable.yes,
      );
      spinner = Spinner(enabled: false, region: screen.status);
      host = TuiConversationHost(
        conversationId: 'c1',
        chat: screen.chat,
        screen: screen,
        spinner: spinner,
        primary: true,
      )..stayAttachedWhenInactive = true;
    });

    /// True if any recorded erase landed inside the chat rect — i.e. the chat
    /// area was blanked. eraseChatArea() erases every chat row at chat.col for
    /// chat.width; matching the row range is sufficient to detect it.
    bool erasedChatArea() {
      final chat = screen.layout.chat;
      final top = chat.row;
      final bottom = chat.row + chat.height;
      return backend.erases.any((e) => e.row >= top && e.row < bottom);
    }

    test('re-activating an already-attached region does not blank the chat area',
        () {
      // Seed some history so the region is attached and has rendered content.
      host.text('first turn\n');
      host.text('second turn\n');
      expect(screen.chat.isDetached, isFalse,
          reason: 'primary chat starts attached and visible');

      backend.clear(); // observe only the setActive repaint
      host.setActive(true);

      expect(erasedChatArea(), isFalse,
          reason: 'focus returning to an already-visible main panel must not '
              'erase its history — that erase frame is the flicker');
    });

    test('re-activating a detached region still erases and re-attaches', () {
      // Seed history, then detach (as if a modal or single-panel deactivate hid
      // the region). The recovery path must still fire on re-activation.
      host.text('first turn\n');
      screen.chat.detach();
      expect(screen.chat.isDetached, isTrue);

      backend.clear();
      host.setActive(true);

      expect(erasedChatArea(), isTrue,
          reason: 'a region that was actually hidden must be erased and '
              're-attached on activation so its saved rows repaint');
      expect(screen.chat.isDetached, isFalse,
          reason: 'attach() reattaches the region');
    });
  });
}
