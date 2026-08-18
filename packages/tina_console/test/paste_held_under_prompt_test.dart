import 'dart:async';

import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// Regression coverage for tin-w8dl: a paste arriving while a
/// `readKey(globalKeys: true)` is armed (the shape behind every approval /
/// gate prompt) must not land in the editor buffer underneath the prompt.
///
/// Pre-fix, the PasteInput skipped the armed completer (correctly — a paste
/// must not answer y/n/a/d) but fell straight through to `_dispatchEvent`,
/// so the paste landed in the buffer with the prompt still open. The user's
/// next Enter then answered the prompt (denyOnce — the "ceremony's answer"
/// on screen in the live repro) and the paste was stranded with no Enter
/// left to submit it. Deterministic repro: tool/w8dl_hunt.sh with the
/// w8dl_ceremony stub scenario; audit trail on the ticket.
///
/// The fix mirrors askPermission's arm-guard (which defers arming while a
/// readLine has unsent content): hold the paste while the prompt's readKey
/// is armed, deliver it through the full pipeline once the prompt resolves.
/// Held pastes are never dropped — not by a chained prompt, not by close().
Future<void> _flush() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.microtask(() {});
  }
  await Future<void>.delayed(Duration.zero);
}

(LineEditor, Screen) _rig(FakeStdio io) {
  final screen = Screen(
    io: io,
    layout: ScreenLayout.fromSize(80, 24),
    ansi: AnsiCapable.yes,
  );
  final editor = LineEditor(
    screen: screen,
    escapeTimeout: Duration.zero,
  );
  return (editor, screen);
}

void main() {
  group('tin-w8dl: paste under an armed global readKey', () {
    late FakeStdio io;
    setUp(() => io = FakeStdio());

    test('held while the prompt waits, delivered once it resolves', () async {
      final (editor, _) = _rig(io);
      final line = editor.readLine('> ');
      await _flush();

      final approval = editor.readKey(globalKeys: true);
      await _flush();

      editor.inject(PasteInput('pasted under the prompt'));
      await _flush();

      // The paste neither answers the prompt nor lands in the buffer yet.
      var answered = false;
      approval.then((_) => answered = true);
      await _flush();
      expect(answered, isFalse, reason: 'a paste must not answer a prompt');
      expect(editor.editState.buffer, isEmpty,
          reason: 'the paste is held behind the prompt, not dispatched');

      // The user's Enter answers the visible prompt (modal semantics)…
      editor.inject(ControlKey(ControlCode.enter));
      final answer = await approval.timeout(const Duration(seconds: 2));
      expect(answer, isA<ControlKey>());
      // …and only then does the held paste reach the editor buffer.
      await _flush();
      expect(editor.editState.buffer, 'pasted under the prompt');

      // The readLine is still pending — its Enter was consumed by the prompt.
      var submitted = false;
      line.then((_) => submitted = true);
      await _flush();
      expect(submitted, isFalse);

      // A second Enter submits the paste as an ordinary turn.
      editor.inject(ControlKey(ControlCode.enter));
      final text = await line.timeout(const Duration(seconds: 2));
      expect(text, 'pasted under the prompt');
      editor.close();
    });

    test('a chained prompt re-holds; every paste is delivered in order',
        () async {
      final (editor, _) = _rig(io);
      editor.readLine('> ');
      await _flush();

      final first = editor.readKey(globalKeys: true);
      // The prompt's awaiter chains straight into the next prompt — the
      // shape of an approval flow that asks again after a denial.
      late final Future<InputEvent> second;
      first.then((_) {
        second = editor.readKey(globalKeys: true);
      });
      editor.inject(PasteInput('first paste'));
      await _flush();
      expect(editor.editState.buffer, isEmpty);

      editor.inject(ControlKey(ControlCode.enter)); // answers prompt 1
      await _flush();

      // The delivery microtask runs after the completer's awaiter, so the
      // chained readKey is already armed: the paste is re-held, not lost.
      expect(editor.editState.buffer, isEmpty,
          reason: 'the chained prompt re-holds the paste');

      editor.inject(CharInput('y')); // answers prompt 2
      await second.timeout(const Duration(seconds: 2));
      await _flush();
      expect(editor.editState.buffer, 'first paste');
      editor.close();
    });

    test('a split paste (two PasteInputs) delivers every char in order',
        () async {
      final (editor, _) = _rig(io);
      editor.readLine('> ');
      await _flush();

      final approval = editor.readKey(globalKeys: true);
      // The burst detector's join-window shape when a delivery stall splits
      // one paste: two PasteInputs, e.g. 5412 + 588 chars (the live
      // truncation). Both must survive the prompt — as one paste or two,
      // never dropped — and submit whole.
      editor.inject(PasteInput('a' * 20));
      editor.inject(PasteInput('b' * 10));
      await _flush();
      expect(editor.editState.buffer, isEmpty);

      editor.inject(CharInput('y')); // answers the prompt
      await approval.timeout(const Duration(seconds: 2));
      await _flush();

      expect(editor.editState.buffer, 'a' * 20 + 'b' * 10,
          reason: 'both halves delivered, in order, nothing dropped');
      editor.close();
    });

    test('a paste after the prompt resolves lands directly (no hold)', () async {
      final (editor, _) = _rig(io);
      editor.readLine('> ');
      await _flush();

      final approval = editor.readKey(globalKeys: true);
      editor.inject(ControlKey(ControlCode.enter));
      await approval.timeout(const Duration(seconds: 2));
      await _flush();

      // No readKey armed anymore — the paste dispatches immediately, the
      // pre-tin-w8dl healthy path.
      editor.inject(PasteInput('plain paste'));
      await _flush();
      expect(editor.editState.buffer, 'plain paste');
      editor.close();
    });

    test('close() delivers a still-held paste instead of dropping it',
        () async {
      final (editor, _) = _rig(io);
      editor.readLine('> ');
      await _flush();

      final approval = editor.readKey(globalKeys: true);
      editor.inject(PasteInput('held at shutdown'));
      await _flush();
      expect(editor.editState.buffer, isEmpty);

      // Shutdown with the prompt still open: the paste must reach the
      // buffer (a pending readLine could still submit it), never vanish.
      editor.close();
      expect(editor.editState.buffer, 'held at shutdown');
      await approval.timeout(const Duration(seconds: 2)).catchError((_) {
        // The readKey never completing at close is pre-existing behavior.
        return ControlKey(ControlCode.ctrlC);
      });
    });
  });
}
