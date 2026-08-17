import 'dart:async';

import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// Regression coverage for tin-c5nw: a global shortcut must never become
/// approval-prompt input. While a `readKey(globalKeys: true)` is armed (the
/// shape behind every approval / gate prompt), the focus ring's keys —
/// Ctrl+G / Ctrl+W panel cycling, and every key while cycling is engaged —
/// are handled by the editor. The prompt keeps waiting for its own key.
///
/// Pre-fix, Ctrl+G fell straight into the armed completer: the panels did not
/// cycle and the approval answered the key as a deny (it is not y/a/d).
class _Panel implements Focusable {
  _Panel(this.name, this.boundsRect);

  final String name;
  final Rect boundsRect;

  bool isFocused = false;
  bool isHighlighted = false;

  @override
  bool get hasFocus => isFocused;

  @override
  bool get canFocus => true;

  @override
  Rect get bounds => boundsRect;

  @override
  void focus() {
    isFocused = true;
    isHighlighted = false;
  }

  @override
  void blur() => isFocused = false;

  @override
  void highlight() => isHighlighted = true;

  @override
  void unhighlight() => isHighlighted = false;

  @override
  bool handleEvent(InputEvent event) => false;
}

Future<void> _flush() async {
  await Future<void>.microtask(() {});
  await Future<void>.microtask(() {});
  await Future<void>.delayed(Duration.zero);
}

/// Editor + focus ring with a home panel and one other panel, mirroring the
/// coordinator's wiring (chat is home, a second panel is cyclable).
(LineEditor, FocusManager, _Panel, _Panel) _rig(FakeStdio io) {
  final screen = Screen(
    io: io,
    layout: ScreenLayout.fromSize(80, 24),
    ansi: AnsiCapable.yes,
  );
  final editor = LineEditor(
    screen: screen,
    escapeTimeout: Duration.zero,
  );
  final chat = _Panel('chat', const Rect(row: 0, col: 0, width: 40, height: 20));
  final side =
      _Panel('side', const Rect(row: 0, col: 40, width: 40, height: 20));
  final fm = FocusManager()
    ..register(chat)
    ..register(side);
  fm.home = chat;
  editor.focusManager = fm;
  return (editor, fm, chat, side);
}

void main() {
  group('readKey(globalKeys: true) — the approval shape', () {
    late FakeStdio io;
    setUp(() => io = FakeStdio());

    test('Ctrl+G cycles panels instead of answering the prompt', () async {
      final (editor, fm, chat, side) = _rig(io);
      editor.readLine('> ');
      await _flush();

      final approval = editor.readKey(globalKeys: true);
      io.feedBytes([0x07]); // Ctrl+G
      await _flush();

      // The prompt is still waiting — the key never reached it.
      var answered = false;
      approval.then((_) => answered = true);
      await _flush();
      expect(answered, isFalse, reason: 'Ctrl+G must not answer the approval');
      // And the ring engaged: a panel is highlighted for cycling.
      expect(fm.isCycling, isTrue);

      // Tab moves the highlight; still nothing reaches the prompt.
      io.feedBytes([0x09]);
      await _flush();
      expect(answered, isFalse);
      expect(side.isHighlighted, isTrue, reason: 'Tab moved to the next panel');

      // Enter commits the focus — the ring is modal while cycling, so the
      // commit must not be read as the approval's answer either.
      io.feedBytes([0x0d]);
      await _flush();
      expect(answered, isFalse);
      expect(side.hasFocus, isTrue, reason: 'Enter committed the focus');

      // The prompt's own keys still work: 'y' completes the readKey.
      io.feedBytes([0x79]);
      final event = await approval.timeout(const Duration(seconds: 2));
      expect(event, isA<CharInput>());
      expect((event as CharInput).text, 'y');
    });

    test("Ctrl+W engages cycling too; 'n' answers once cycling is off", () async {
      final (editor, fm, chat, side) = _rig(io);
      editor.readLine('> ');
      await _flush();

      final approval = editor.readKey(globalKeys: true);
      io.feedBytes([0x17]); // Ctrl+W
      await _flush();
      expect(fm.isCycling, isTrue);

      // While cycling the ring is modal — it swallows every key, exactly as
      // it does with no approval open. The prompt must not receive them.
      var answered = false;
      approval.then((_) => answered = true);
      io.feedBytes([0x6e]); // 'n'
      await _flush();
      expect(answered, isFalse, reason: 'cycling is modal over typing too');

      // Esc leaves cycling, and the prompt takes the next key.
      io.feedBytes([0x1b]);
      await _flush();
      expect(fm.isCycling, isFalse);

      io.feedBytes([0x6e]); // 'n'
      final event = await approval.timeout(const Duration(seconds: 2));
      expect((event as CharInput).text, 'n');
    });

    test('Esc returns focus home instead of denying the approval', () async {
      final (editor, fm, chat, side) = _rig(io);
      editor.readLine('> ');
      await _flush();

      // Park the focus on the side panel, then arm an approval.
      fm.focusPanel(side);
      expect(side.hasFocus, isTrue);

      final approval = editor.readKey(globalKeys: true);
      io.feedBytes([0x1b]); // Esc
      await _flush();
      expect(chat.hasFocus, isTrue, reason: 'Esc returned focus to home');

      io.feedBytes([0x64]); // 'd'
      final event = await approval.timeout(const Duration(seconds: 2));
      expect((event as CharInput).text, 'd');
    });
  });

  group('readKey() without globalKeys — the overlay shape', () {
    late FakeStdio io;
    setUp(() => io = FakeStdio());

    test('still delivers Ctrl+G to the caller (screen-owning overlays)', () async {
      final (editor, fm, chat, side) = _rig(io);
      editor.readLine('> ');
      await _flush();

      final overlay = editor.readKey();
      io.feedBytes([0x07]); // Ctrl+G
      final event = await overlay.timeout(const Duration(seconds: 2));
      expect(event, isA<ControlKey>());
      expect((event as ControlKey).code, ControlCode.ctrlG);
      expect(fm.isCycling, isFalse,
          reason: 'a full-screen overlay keeps its keys');
    });
  });
}
