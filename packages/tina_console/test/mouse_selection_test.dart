import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'stdio_fake.dart';

void main() {
  late FakeStdio io;
  late Screen screen;
  late LineEditor editor;
  late ConsoleContext context;
  late MouseTextSelection selection;
  final copied = <String>[];
  setUp(() {
    io = FakeStdio();
    screen =
        Screen(io: io, layout: ScreenLayout.fromSize(60, 12, split: false));
    editor = LineEditor(screen: screen);
    context = ConsoleContext(screen: screen, editor: editor);
    copied.clear();
    selection = MouseTextSelection(context, copyText: (text) async {
      copied.add(text);
      return true;
    });
  });
  tearDown(() {
    selection.close();
    editor.close(reportLatency: false);
    screen.dispose();
    io.close();
  });
  MouseEvent pointer(MouseAction action, int row, int col) => MouseEvent(action,
      row: screen.chat.bounds.row + row, col: screen.chat.bounds.col + col);
  void fill() {
    for (var i = 0; i < 80; i++) {
      screen.chat.writeln('line ${i.toString().padLeft(2, '0')} content');
    }
    screen.chat.scrollBy(-50);
  }

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test(
      'dragging below the viewport selects several pages and copies on release',
      () async {
    fill();
    selection.handleEvent(pointer(MouseAction.press, 1, 0));
    selection
        .handleEvent(pointer(MouseAction.move, screen.chat.usableHeight, 6));
    for (var i = 0; i < 25; i++) {
      selection.autoScroll();
    }
    final expected = selection.selectedText;
    expect(
        expected.split('\n').length, greaterThan(screen.chat.usableHeight * 2));
    expect(copied, isEmpty);
    selection
        .handleEvent(pointer(MouseAction.release, screen.chat.usableHeight, 6));
    await pump();
    expect(copied, [expected]);
    expect(selection.isActive, false);
    expect(screen.chat.scrollOffset, lessThan(50));
    expect(selection.status().single.runs.single.text, startsWith('Copied '));
  });

  test('dragging above the viewport selects earlier rows in natural order',
      () async {
    fill();
    selection.handleEvent(pointer(MouseAction.press, 3, 6));
    selection.handleEvent(pointer(MouseAction.move, -1, 0));
    for (var i = 0; i < 15; i++) {
      selection.autoScroll();
    }
    final expected = selection.selectedText;
    expect(expected.split('\n').length, greaterThan(screen.chat.usableHeight));
    expect(expected.split('\n').first, startsWith('line '));
    selection.handleEvent(pointer(MouseAction.release, -1, 0));
    await pump();
    expect(copied, [expected]);
    expect(screen.chat.scrollOffset, greaterThan(50));
  });

  test('streaming and eviction cannot change a selection snapshot', () async {
    fill();
    selection.handleEvent(pointer(MouseAction.press, 1, 0));
    selection.handleEvent(pointer(MouseAction.move, 4, 9));
    final expected = selection.selectedText;
    for (var i = 0; i < 2200; i++) {
      screen.chat.writeln('new $i');
    }
    expect(selection.selectedText, expected);
    selection.handleEvent(pointer(MouseAction.release, 4, 9));
    await pump();
    expect(copied, [expected]);
  });

  test('clicks, Escape, dialog ownership and resize never copy accidentally',
      () async {
    fill();
    selection.handleEvent(pointer(MouseAction.press, 1, 0));
    selection.handleEvent(pointer(MouseAction.release, 1, 0));
    await pump();
    expect(copied, isEmpty);
    selection.handleEvent(pointer(MouseAction.press, 1, 0));
    selection.handleEvent(pointer(MouseAction.move, 5, 7));
    expect(selection.handleEvent(EscapeKey()), true);
    selection.autoScroll();
    await pump();
    expect(copied, isEmpty);
    selection.handleEvent(pointer(MouseAction.press, 1, 0));
    selection.handleEvent(pointer(MouseAction.move, 5, 7));
    final session = editor.openInputSession();
    selection.autoScroll();
    expect(selection.isActive, false);
    session.dispose();
    selection.handleEvent(pointer(MouseAction.press, 1, 0));
    screen.resize(ScreenLayout.fromSize(40, 10, split: false));
    selection.autoScroll();
    expect(selection.isActive, false);
    await pump();
    expect(copied, isEmpty);
  });

  test('Unicode cells copy whole characters and strip rendering escapes',
      () async {
    for (var i = 0; i < 20; i++) {
      screen.chat.writeln('\x1b[31mA界\u0301😀B\x1b[0m');
    }
    selection.handleEvent(pointer(MouseAction.press, 1, 1));
    selection.handleEvent(pointer(MouseAction.move, 1, 3));
    selection.handleEvent(pointer(MouseAction.release, 1, 3));
    await pump();
    expect(copied, ['界\u0301😀']);
  });

  test('button-up motion cancels a release lost outside the terminal',
      () async {
    fill();
    selection.handleEvent(pointer(MouseAction.press, 1, 0));
    selection.handleEvent(pointer(MouseAction.move, 4, 5));
    selection.handleEvent(pointer(MouseAction.hover, 4, 5));
    expect(selection.isActive, false);
    selection.handleEvent(pointer(MouseAction.release, 4, 5));
    await pump();
    expect(copied, isEmpty);
  });

  test('clipboard failure is reported without claiming the text was copied',
      () async {
    selection.close();
    selection = MouseTextSelection(context, copyText: (_) async => false);
    fill();
    selection.handleEvent(pointer(MouseAction.press, 1, 0));
    selection.handleEvent(pointer(MouseAction.move, 4, 5));
    selection.handleEvent(pointer(MouseAction.release, 4, 5));
    await pump();
    expect(selection.status().single.runs.single.text,
        'Could not copy selection to clipboard');
  });

  test('mouse reporting is leased and paused for dialogs', () {
    screen.enterAltScreen();
    io.written.clear();
    final release = screen.bindMouseSelection();
    expect(io.written.toString(), contains('\x1b[?1002h'));
    io.written.clear();
    final session = editor.openInputSession();
    expect(io.written.toString(), contains('\x1b[?1002l'));
    io.written.clear();
    session.dispose();
    expect(io.written.toString(), contains('\x1b[?1002h'));
    io.written.clear();
    release();
    expect(io.written.toString(), contains('\x1b[?1002l'));
    release();
  });
}
