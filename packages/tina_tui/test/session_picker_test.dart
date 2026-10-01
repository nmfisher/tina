import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_tui/src/session_selection.dart';

class _Io implements Stdio {
  final output = StringBuffer();
  @override
  Stream<List<int>> get stdin => const Stream.empty();
  @override
  void write(String text) => output.write(text);
  @override
  int get terminalColumns => 80;
  @override
  bool get hasTerminal => false;
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal signal) =>
      const Stream.empty();
}

void main() {
  late _Io io;
  late Screen screen;
  late LineEditor editor;
  setUp(() {
    io = _Io();
    screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(80, 24, split: false),
        ansi: AnsiCapable.yes);
    editor = LineEditor(screen: screen);
  });
  tearDown(() {
    editor.close(reportLatency: false);
    screen.dispose();
  });
  final sessions = List.generate(
      20,
      (i) => StoredSession(
          id: 'session-$i',
          registryKey: i,
          entries: 10,
          model: 'provider/model',
          lastSavedAt: DateTime(2026, 10, 1, 20, i),
          summary: 'Inspect mesh $i'));
  String visible() {
    final vt = VirtualTerminal(width: 80, height: 24)
      ..feed(io.output.toString());
    return List.generate(24, vt.rowText).join('\n');
  }

  test('shows saved time and preview, arrows choose, Enter resumes', () async {
    final events = <InputEvent>[
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.down),
      ArrowKey(ArrowDirection.up),
      ControlKey(ControlCode.enter),
    ].iterator;
    var first = true;
    final result =
        await SessionPicker(screen, editor, sessions, readEvent: () async {
      if (first) {
        expect(visible(), contains('2026-10-01 20:00'));
        expect(visible(), contains('Inspect mesh 0'));
        expect(visible(), contains('provider/model'));
        first = false;
      }
      events.moveNext();
      return events.current;
    }).run();
    expect(result, 'session-1');
  });
  test('scrolls and reflows without losing the selected session', () async {
    late SessionPicker picker;
    var calls = 0;
    picker = SessionPicker(screen, editor, sessions, readEvent: () async {
      if (calls++ < 16) return ArrowKey(ArrowDirection.down);
      screen.resize(ScreenLayout.fromSize(30, 10, split: false));
      picker.repaint();
      expect(io.output.toString(), contains('mesh 16'));
      return ControlKey(ControlCode.enter);
    });
    expect(await picker.run(), 'session-16');
  });
  test('Escape and Ctrl-C cancel, and an empty list reads no input', () async {
    for (final event in [EscapeKey(), ControlKey(ControlCode.ctrlC)]) {
      expect(
          await SessionPicker(screen, editor, sessions,
              readEvent: () async => event).run(),
          isNull);
    }
    expect(
        await SessionPicker(screen, editor, [],
            readEvent: () async => throw StateError('must not read')).run(),
        isNull);
  });
  test('saved titles cannot inject controls into the terminal', () async {
    final unsafe = StoredSession(
        id: 's',
        registryKey: 1,
        entries: 1,
        title: 'mesh\n\x1b[1;1HM',
        summary: 'unused');
    await SessionPicker(screen, editor, [unsafe], readEvent: () async {
      final vt = VirtualTerminal(width: 80, height: 24)
        ..feed(io.output.toString());
      expect(vt.rowText(0).trim(), isEmpty);
      expect(visible(), contains('mesh'));
      return EscapeKey();
    }).run();
  });
}
