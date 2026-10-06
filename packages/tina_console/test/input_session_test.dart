import 'dart:async';

import 'package:test/test.dart';
import 'package:dart_notcurses/dart_notcurses.dart' as nc;
import 'package:tina_console/src/backend/notcurses_input_backend.dart'
    as native;
import 'package:tina_console/tina_console.dart';

import 'stdio_fake.dart';

Future<void> tick() => Future<void>.delayed(Duration.zero);

class _EmptyKeySource implements native.KeySource {
  @override
  native.NcKeyEvent? poll() => null;
  @override
  void disposeKey(native.NcKeyEvent key) {}
}

void main() {
  late FakeStdio io;
  late Screen screen;
  late LineEditor editor;
  setUp(() {
    io = FakeStdio();
    screen = Screen(io: io, layout: ScreenLayout.fromSize(80, 24));
    editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
  });
  tearDown(() {
    editor.close(reportLatency: false);
    screen.dispose();
    io.close();
  });

  for (final delay in [Duration.zero, const Duration(milliseconds: 40)]) {
    test('queued navigation survives repaint delay $delay', () async {
      final input = editor.openInputSession();
      // No reader is armed when this entire burst arrives.
      io.feedBytes('\x1b[B\x1b[A\t\r'.codeUnits);
      await tick();
      final events = <InputEvent>[];
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(delay);
        screen.chat.repaint();
        events.add(await input.read());
      }
      expect(events, [
        ArrowKey(ArrowDirection.down),
        ArrowKey(ArrowDirection.up),
        ControlKey(ControlCode.tab),
        ControlKey(ControlCode.enter)
      ]);
      input.dispose();
    });
  }

  for (final pasteDetection in [false, true]) {
    test(
        'native buffered batch stays with closing dialog (paste=$pasteDetection)',
        () async {
      editor.close(reportLatency: false);
      final backend = native.NotcursesInputBackend(_EmptyKeySource(),
          startupDrainMinWindow: Duration.zero,
          startPolling: false,
          temporalPasteDetection: pasteDetection,
          replySequenceFiltering: false);
      editor = LineEditor(screen: screen, input: backend);
      addTearDown(backend.dispose);
      final first = editor.openInputSession();
      backend.pumpedBatchForTest([
        nc.PumpedInput(nc.NcKey.down, 0, 1000000),
        nc.PumpedInput(nc.NcKey.enter, 0, 1001000),
        nc.PumpedInput('a'.codeUnitAt(0), 0, 1002000),
      ]);
      if (!pasteDetection) {
        expect(editor.keyCount, 3,
            reason: 'batch must enter the queue before yielding');
      }
      first.dispose();
      final second = editor.openInputSession();
      var answered = false;
      final pending = second.read().then((event) {
        answered = true;
        return event;
      });
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(answered, false,
          reason: 'old native paste/typing buffers cannot answer a new dialog');
      backend.pumpedInputForTest('n'.codeUnitAt(0));
      expect(await pending, CharInput('n'));
      second.dispose();
    });
  }

  test('pending readers receive keys in order', () async {
    final input = editor.openInputSession();
    final reads = [input.read(), input.read(), input.read()];
    io.feedBytes('yn\r'.codeUnits);
    expect(await Future.wait(reads),
        [CharInput('y'), CharInput('n'), ControlKey(ControlCode.enter)]);
  });

  test('dialog closure discards all extra answers before next dialog',
      () async {
    final first = editor.openInputSession();
    io.feedBytes('\rayn\x1b[B\r'.codeUnits);
    expect(await first.read(), ControlKey(ControlCode.enter));
    await tick();
    first.dispose();
    final second = editor.openInputSession();
    var answered = false;
    final pending = second.read().then((event) {
      answered = true;
      return event;
    });
    await tick();
    expect(answered, false);
    io.feedBytes('n'.codeUnits);
    expect(await pending, CharInput('n'));
  });

  test('disposal cancels every pending reader and is idempotent', () async {
    final input = editor.openInputSession();
    final reads = [input.read(), input.read()];
    input.dispose();
    input.dispose();
    expect(
        await Future.wait(reads), everyElement(ControlKey(ControlCode.ctrlC)));
    expect(await input.read(), ControlKey(ControlCode.ctrlC));
    expect(input.isClosed, true);
    await input.closed;
    expect(editor.isReadingKey, false);
  });

  test('only one dialog can own input at a time', () {
    final input = editor.openInputSession();
    expect(editor.openInputSession, throwsStateError);
    input.dispose();
    editor.openInputSession().dispose();
  });

  test('late cancellation cannot cancel a new owner', () async {
    final cancellation = Completer<void>();
    final first = editor.openInputSession(cancelSignal: cancellation.future);
    first.dispose();
    final second = editor.openInputSession();
    cancellation.complete();
    await tick();
    expect(second.isClosed, false);
    io.feedBytes('a'.codeUnits);
    expect(await second.read(), CharInput('a'));
  });

  test('cancellation discards queued approval answers', () async {
    final cancellation = Completer<void>();
    final input = editor.openInputSession(cancelSignal: cancellation.future);
    io.feedBytes('a\r'.codeUnits);
    await tick();
    cancellation.complete();
    await tick();
    expect(await input.read(), ControlKey(ControlCode.ctrlC));
    input.dispose();
  });

  test('legacy read waits for the entire dialog lifetime', () async {
    final owned = editor.openInputSession();
    var legacyAnswered = false;
    final legacy = editor.readKey().then((event) {
      legacyAnswered = true;
      return event;
    });
    io.feedBytes('a'.codeUnits);
    expect(await owned.read(), CharInput('a'));
    await tick();
    expect(legacyAnswered, false);
    owned.dispose();
    await tick();
    io.feedBytes('n'.codeUnits);
    expect(await legacy, CharInput('n'));
  });

  test('approval paste remains in draft until all dialogs close', () async {
    final draft = editor.readLine('> ');
    io.feedBytes('old '.codeUnits);
    await tick();
    final approval =
        editor.openInputSession(globalKeys: true, acceptPaste: false);
    io.feedBytes('\x1b[200~new\x1b[201~'.codeUnits);
    await tick();
    expect(editor.editState.buffer, 'old ');
    approval.dispose();
    // A newly opened settings text field must not receive the earlier paste.
    final settings = editor.openInputSession();
    await tick();
    expect(editor.editState.buffer, 'old ');
    io.feedBytes('x'.codeUnits);
    expect(await settings.read(), CharInput('x'));
    settings.dispose();
    await tick();
    expect(editor.editState.buffer, 'old new');
    io.feedBytes('\r'.codeUnits);
    expect(await draft, 'old new');
  });

  test('fresh paste belongs to the owned form field', () async {
    final input = editor.openInputSession();
    io.feedBytes('\x1b[200~filter\x1b[201~\r'.codeUnits);
    expect(await input.read(), PasteInput('filter'));
    expect(await input.read(), ControlKey(ControlCode.enter));
    expect(editor.editState.buffer, isEmpty);
  });

  test('Escape can dismiss nested form while parent keeps its queue', () async {
    final input = editor.openInputSession();
    io.feedBytes('\x1b'.codeUnits);
    expect(await input.read(), isA<EscapeKey>());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    io.feedBytes('\x1b[B\r'.codeUnits);
    expect(await input.read(), ArrowKey(ArrowDirection.down));
    expect(await input.read(), ControlKey(ControlCode.enter));
    expect(input.isClosed, false);
  });

  test('approval Escape releases ownership before following draft text',
      () async {
    final draft = editor.readLine('> ');
    final input = editor.openInputSession(releaseOnEscape: true);
    io.feedBytes('\x1b'.codeUnits);
    expect(await input.read(), isA<EscapeKey>());
    expect(editor.isReadingKey, false);
    io.feedBytes('fresh\r'.codeUnits);
    input.dispose();
    expect(await draft, 'fresh');
  });

  test('double Escape closes dialog and discards held paste and queued answers',
      () async {
    final input = editor.openInputSession(acceptPaste: false);
    io.feedBytes('\x1b[200~old\x1b[201~a'.codeUnits);
    await tick();
    io.feedBytes('\x1b'.codeUnits);
    await tick();
    io.feedBytes('\x1b'.codeUnits);
    await input.closed;
    expect(await input.read(), ControlKey(ControlCode.ctrlC));
    expect(editor.editState.buffer, isEmpty);
    final next = editor.openInputSession();
    io.feedBytes('n'.codeUnits);
    expect(await next.read(), CharInput('n'));
  });
}
