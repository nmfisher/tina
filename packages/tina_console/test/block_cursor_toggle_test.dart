import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// The editor's `onBlockCursor` hook (Ctrl+B, byte 0x02): offered at the same
/// dispatch rank as `onRawView` — after the modal layer, before the focus ring —
/// and consumed only when the hook claims it. Driven through real byte input,
/// so this also pins that the parser *maps* 0x02: a control byte it does not
/// know is silently dropped, which is how a "free key" turns out not to be one.
void main() {
  late FakeStdio io;
  late Screen screen;
  late LineEditor editor;

  setUp(() {
    io = FakeStdio();
    screen = Screen(io: io, layout: ScreenLayout.fromSize(80, 24));
    editor = LineEditor(screen: screen);
  });

  Future<void> flush() async {
    await Future<void>.microtask(() {});
    await Future<void>.microtask(() {});
    await Future<void>.delayed(Duration.zero);
  }

  test('ctrl+b fires the hook and is consumed when it returns true', () async {
    var fired = 0;
    editor.onBlockCursor = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x02, 0x0d]); // Ctrl+B, then Enter
    expect(await f, '', reason: 'ctrl+b consumed; Enter alone submits');
    expect(fired, 1);
  });

  test('a declining hook lets the key fall through', () async {
    var fired = 0;
    editor.onBlockCursor = () {
      fired++;
      return false;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x02, 0x0d]);
    expect(await f, '');
    expect(fired, 1);
  });

  test('plain "b" never fires the hook', () async {
    var fired = 0;
    editor.onBlockCursor = () {
      fired++;
      return true;
    };
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x62, 0x0d]); // 'b', Enter
    expect(await f, 'b');
    expect(fired, 0);
  });

  test('ctrl+b fires the hook in queue mode (agent turn running)', () async {
    var fired = 0;
    editor.onBlockCursor = () {
      fired++;
      return true;
    };
    // Queue mode: the cancel monitor is active while an agent turn runs and
    // keys route through _handleQueueEvent, not _dispatchEvent. Reading output
    // mid-turn is exactly when the cursor is wanted.
    var cancelled = false;
    editor.beginCancelMonitor(() => cancelled = true, onQueueSubmit: (_) {});
    await flush();
    io.feedBytes([0x02]); // Ctrl+B
    await flush();
    expect(fired, 1, reason: 'the cursor opens while the agent runs');
    expect(cancelled, isFalse, reason: 'ctrl+b is not a cancel');
    editor.endCancelMonitor();
  });

  test('an unclaimed ctrl+b still types nothing', () async {
    // No hook: the byte must not leak into the buffer as a control character.
    final f = editor.readLine('> ');
    await flush();
    io.feedBytes([0x02, 0x0d]);
    expect(await f, '');
  });
}
