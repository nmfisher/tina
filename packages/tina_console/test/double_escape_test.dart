import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// The editor's double-Esc gesture (owner bug 2026-08-24: "I pressed Escape
/// twice and the border was still animating"). Two layers had to line up:
///
/// - the PARSER re-emits one EscapeKey per standalone ESC when a fast pair
///   collapses into the `ESC ESC` Alt-prefix path (covered in
///   input_parser_test); these tests drive the bytes `1b 1b` and rely on that.
/// - the EDITOR keeps a 450ms double window across BOTH the dispatch path and
///   the readKey path (a modal — an approval row — eats single Escs as
///   "deny", so the window must survive a swipe that never reaches
///   dispatch). `onDoubleEscape` is the force-cancel hook: consumed on the
///   dispatch path when it returns true, fired as a side call (event still
///   delivered) on the readKey path so the modal can close its row while the
///   run underneath stops.
void main() {
  late FakeStdio io;
  late Screen screen;
  late LineEditor editor;

  setUp(() {
    io = FakeStdio();
    screen = Screen(io: io, layout: ScreenLayout.fromSize(80, 24));
    // 10ms escape timeout so standalone ESCs resolve quickly in tests; the
    // double window itself is a fixed 450ms.
    editor = LineEditor(
        screen: screen, escapeTimeout: const Duration(milliseconds: 10));
  });

  Future<void> flush() async {
    await Future<void>.microtask(() {});
    await Future<void>.microtask(() {});
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }

  // Feed an Esc burst, let the parser resolve it (a real keypress after a
  // double-Esc lands well after the escape window), then submit. Feeding
  // Enter in the same burst would instead pair `ESC CR` into the two-byte
  // escape path and swallow the Enter — a different (pre-existing) quirk.
  Future<void> escEscThenEnter(List<int> before) async {
    io.feedBytes([...before, 0x1b, 0x1b]);
    await flush();
    io.feedBytes([0x0d]);
    await flush();
  }

  test('rapid double-Esc fires the hook and is consumed when it returns true',
      () async {
    var fired = 0;
    editor.onDoubleEscape = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await Future<void>.microtask(() {});
    await escEscThenEnter([0x61]); // 'a' + Esc Esc
    expect(fired, 1);
    expect(await f, 'a',
        reason: 'the consumed double-Esc must not fall through to the '
            'input clear');
  });

  test('a declining hook keeps the idle input-clear behavior', () async {
    var fired = 0;
    editor.onDoubleEscape = () {
      fired++;
      return false;
    };
    final f = editor.readLine('> ');
    await Future<void>.microtask(() {});
    await escEscThenEnter([0x61, 0x62]); // 'ab' + Esc Esc
    expect(fired, 1);
    expect(await f, '', reason: 'idle double-Esc still clears the buffer');
  });

  test('a single Esc does not fire the hook', () async {
    var fired = 0;
    editor.onDoubleEscape = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await Future<void>.microtask(() {});
    io.feedBytes([0x61, 0x1b]); // 'a', one Esc
    await flush();
    io.feedBytes([0x0d]);
    await flush();
    expect(fired, 0);
    expect(await f, 'a');
  });

  test('slow double press (outside the 450ms window) does not fire the hook',
      () async {
    var fired = 0;
    editor.onDoubleEscape = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await Future<void>.microtask(() {});
    io.feedBytes([0x1b]);
    await flush(); // first Esc resolves on its own
    await Future<void>.delayed(
        const Duration(milliseconds: 500)); // window lapses
    io.feedBytes([0x1b]);
    await flush();
    io.feedBytes([0x0d]);
    await flush();
    expect(fired, 0, reason: 'two deliberate single presses are not a gesture');
    expect(await f, '');
  });

  test('double press reaches the hook even when the FIRST Esc was consumed by '
      'onEscape (prompt-path cancel arm)', () async {
    var singles = 0;
    var doubles = 0;
    editor.onEscape = () {
      singles++;
      return true; // consumed — the coordinator arms "Press Esc again"
    };
    editor.onDoubleEscape = () {
      doubles++;
      return true;
    };
    final f = editor.readLine('> ');
    await Future<void>.microtask(() {});
    await escEscThenEnter(const []);
    expect(singles, 1, reason: 'the first Esc is the single-press cancel');
    expect(doubles, 1, reason: 'the second completes the force-cancel');
    expect(await f, '');
  });

  test('readKey path: double-Esc fires the hook AND still delivers the Esc',
      () async {
    // An approval modal (the owner's exact scenario): keys route to a global
    // readKey, which swallows Esc as "deny". The window must survive that
    // swipe — hook fired as a side call, event delivered to the modal.
    var fired = 0;
    editor.onDoubleEscape = () {
      fired++;
      return true; // returning true must NOT swallow the readKey delivery
    };
    final f = editor.readLine('> ');
    await Future<void>.microtask(() {});
    final key = editor.readKey(globalKeys: true);
    io.feedBytes([0x1b]);
    await flush();
    expect(fired, 0, reason: 'the first Esc only arms the window');
    final event1 = await key;
    expect(event1, isA<EscapeKey>(), reason: 'the modal gets its deny');
    final key2 = editor.readKey(globalKeys: true);
    io.feedBytes([0x1b]);
    await flush();
    final event2 = await key2;
    expect(fired, 1, reason: 'the second Esc completes the double');
    expect(event2, isA<EscapeKey>(),
        reason: 'delivery is unconditional on the readKey path');
    io.feedBytes([0x0d]);
    await flush();
    expect(await f, '');
  });
}
