import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/notcurses_backend.dart';

import 'notcurses_backend_platform_test.dart' show RecordingPlatform;
import 'stdio_fake.dart';
import 'virtual_terminal.dart';

class _CursorPlatform extends RecordingPlatform {
  bool visible = true;
  (int, int)? position;
  @override
  void cursorEnable(int row, int col) {
    visible = true;
    position = (row, col);
    super.cursorEnable(row, col);
  }

  @override
  void cursorDisable() {
    visible = false;
    super.cursorDisable();
  }
}

void main() {
  for (final native in [false, true]) {
    group('cursor ownership (${native ? 'notcurses' : 'ANSI'})', () {
      late FakeStdio io;
      late _CursorPlatform platform;
      late TerminalBackend backend;
      late Screen screen;
      setUp(() {
        io = FakeStdio();
        platform = _CursorPlatform();
        if (native) {
          backend = NotcursesBackend.forTesting(io: io, platform: platform);
        } else {
          backend = AnsiBackend(io: io, ansi: AnsiCapable.yes);
        }
        screen = Screen.withBackend(
            backend: backend,
            io: io,
            layout: ScreenLayout.fromSize(80, 24, split: false));
        screen.input.render(prompt: '> ', buffer: 'draft', cursor: 5);
      });
      tearDown(() {
        screen.dispose();
        io.close();
      });
      // Older frames precede the shrink and use the original, larger layout.
      VirtualTerminal terminal() =>
          VirtualTerminal(width: 80, height: 24)..feed(io.written.toString());
      bool visible() => native ? platform.visible : terminal().cursorVisible;
      (int, int)? position() => native
          ? platform.position
          : (terminal().cursorRow, terminal().cursorCol);

      test('choice ownership survives output, input refresh and resize', () {
        final cursor = screen.claimCursor();
        expect(visible(), isFalse);
        platform.calls.clear();
        for (var i = 0; i < 3; i++) {
          screen.chat.writeln('Background output $i');
          screen.setStatusLines([
            RenderLine(runs: [RenderRun('processing $i', null)])
          ]);
          screen.input.repaint();
        }
        screen.resize(ScreenLayout.fromSize(60, 12, split: false));
        screen.refresh();
        expect(visible(), isFalse);
        expect(
            platform.calls.where((c) => c.startsWith('cursorEnable')), isEmpty);
        screen.input.render(prompt: '> ', buffer: 'new draft', cursor: 3);
        cursor.release();
        expect(visible(), isTrue);
        expect(
            position(), (screen.input.bounds.row, screen.input.bounds.col + 5));
      });

      test('a text field keeps its cursor while the conversation redraws', () {
        final cursor = screen.claimCursor()..place(5, 12);
        expect(visible(), isTrue);
        screen.chat.writeln('Background output');
        screen.input.render(prompt: '> ', buffer: 'other draft', cursor: 2);
        expect(position(), (5, 12));
        cursor.hide(); // Return from the field to its settings menu.
        screen.input.repaint();
        expect(visible(), isFalse);
        cursor.release();
        expect(visible(), isTrue);
        expect(
            position(), (screen.input.bounds.row, screen.input.bounds.col + 4));
      });

      test('nested owners and late releases cannot steal the current cursor',
          () {
        final menu = screen.claimCursor();
        final field = screen.claimCursor()..place(4, 10);
        final confirmation = screen.claimCursor();
        field.place(4, 13);
        menu.release(); // Disposing an older attachment leaves the dialog hidden.
        expect(visible(), isFalse);
        confirmation.release();
        expect(visible(), isTrue);
        expect(position(), (4, 13));
        field.release();
        field.place(1, 1); // A disposed plugin cannot resurrect its cursor.
        field.release();
        expect(
            position(), (screen.input.bounds.row, screen.input.bounds.col + 7));
      });

      test('failed console interactions restore the conversation cursor',
          () async {
        final editor = LineEditor(screen: screen);
        final context = ConsoleContext(screen: screen, editor: editor);
        try {
          await expectLater(context.interact<void>(() async {
            expect(visible(), isFalse);
            screen.input.repaint();
            expect(visible(), isFalse);
            throw StateError('dialog failed');
          }), throwsStateError);
          expect(visible(), isTrue);
          await context.interact<void>(() async => expect(visible(), isFalse));
          expect(visible(), isTrue);
        } finally {
          editor.close(reportLatency: false);
        }
      });
    });
  }

  test('ANSI restores a hidden cursor on leaving the terminal', () {
    final io = FakeStdio();
    final backend = AnsiBackend(io: io, ansi: AnsiCapable.yes);
    backend.enterAltScreen();
    backend.setCursorVisible(false);
    backend.flush();
    expect(
        VirtualTerminal(width: 80, height: 24)..feed(io.written.toString()),
        isA<VirtualTerminal>()
            .having((v) => v.cursorVisible, 'visible', false));
    backend.leaveAltScreen();
    backend.flush();
    expect(
        (VirtualTerminal(width: 80, height: 24)..feed(io.written.toString()))
            .cursorVisible,
        isTrue);
    io.close();
  });

  test('late cursor cleanup cannot hide the shell cursor after exit', () {
    final io = FakeStdio();
    final screen =
        Screen(io: io, layout: ScreenLayout.fromSize(80, 24, split: false));
    screen.enterAltScreen();
    final owner = screen.claimCursor();
    screen.leaveAltScreen();
    io.written.clear();
    owner.place(2, 3);
    owner.hide();
    owner.release();
    screen.dispose();
    expect(io.written.toString(), isEmpty);
    io.close();
  });
}
