import 'package:dart_notcurses/dart_notcurses.dart' as nc;
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:tina_console/src/backend/notcurses_input_backend.dart';
import 'package:tina_console/src/backend/reply_sequence_filter.dart';
import 'package:tina_console/src/input_event.dart';

/// Stuck-state release tests for the reply filter (tin-DEAD-KEYBOARD seam).
///
/// The filter exists to swallow terminal capability replies that notcurses
/// fails to decode, but every swallow rule is one bug away from swallowing
/// the user's keyboard: an early prototype that never closed on CSI replies
/// "then swallowed the rest of the session" (see reply_sequence_filter.dart).
/// These tests pin every release path that must exist so a wedge can never
/// be permanent:
///
///  - a lone held ESC is released by the backend's timer (cancel must work);
///  - ESC + non-introducer key releases both (no key loss);
///  - CSI terminates on a final byte (the documented session-wide swallow);
///  - a control key inside a reply aborts the swallow and is delivered;
///  - maxReplyLength is the escape hatch for unterminated replies;
///  - dispose() leaves no live timer behind.
class _FakeKeySource implements KeySource {
  final List<NcKeyEvent> _events = [];

  void add(int id) => _events.add(NcKeyEvent(id, false, false, false));

  @override
  NcKeyEvent? poll() => _events.isEmpty ? null : _events.removeAt(0);

  @override
  void disposeKey(NcKeyEvent key) {}
}

Future<void> pumpMicrotasks() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

NotcursesInputBackend _backend(
  _FakeKeySource source, {
  bool replyFiltering = true,
}) =>
    NotcursesInputBackend(
      source,
      startupDrainMinWindow: Duration.zero,
      startPolling: false,
      temporalPasteDetection: false,
      replySequenceFiltering: replyFiltering,
    );

void main() {
  group('ReplySequenceFilter release rules (pure)', () {
    test('a lone held ESC is released by flush()', () {
      final f = ReplySequenceFilter();
      expect(f.add(0x1b, 0), isEmpty);
      expect(f.isHoldingEscape, isTrue);
      expect(f.flush(), [0x1b]);
      expect(f.isHoldingEscape, isFalse,
          reason: 'flush() is the manual unstick primitive');
    });

    test('a CSI reply terminates on its final byte and swallows nothing after',
        () {
      final f = ReplySequenceFilter();
      final t = 0;
      expect(f.add(0x1b, t), isEmpty); // ESC
      expect(f.add(0x5b, t + 1), isEmpty); // [
      for (final id in '8;40;120'.codeUnits) {
        expect(f.add(id, t + 2), isEmpty, reason: 'parameter byte $id');
      }
      expect(f.add(0x74, t + 3), isEmpty); // 't' — the final byte closes it
      // The keyboard must be fully released afterwards.
      expect(f.add('x'.codeUnitAt(0), t + 4), ['x'.codeUnitAt(0)]);
      expect(f.add(0x1b, t + 5), isEmpty);
      expect(f.flush(), [0x1b], reason: 'a NEW esc after the reply is held');
    });

    test('maxReplyLength abandons an unterminated reply (release hatch)', () {
      final f = ReplySequenceFilter(maxReplyLength: 3);
      final t = 0;
      expect(f.add(0x1b, t), isEmpty);
      expect(f.add(0x50, t + 1), isEmpty); // 'P' — DCS, ST-terminated only
      expect(f.add('a'.codeUnitAt(0), t + 2), isEmpty);
      expect(f.add('b'.codeUnitAt(0), t + 3), isEmpty);
      expect(f.add('c'.codeUnitAt(0), t + 4), isEmpty);
      // Length exceeded: the remainder is ordinary input again.
      expect(f.add('d'.codeUnitAt(0), t + 5), ['d'.codeUnitAt(0)]);
      expect(f.add('e'.codeUnitAt(0), t + 6), ['e'.codeUnitAt(0)]);
    });
  });

  group('backend-level stuck-state release (pump path)', () {
    test('a lone ESC is released by the reply-esc timer with no further keys',
        () {
      fakeAsync((async) {
        final source = _FakeKeySource();
        final backend = _backend(source);
        addTearDown(backend.dispose);
        final emitted = <InputEvent>[];
        backend.events.listen(emitted.add);

        backend.pumpedInputForTest(0x1b);
        async.flushMicrotasks();
        expect(emitted, isEmpty,
            reason: 'the ESC is held pending a possible reply introducer');

        // introducerWindow (5ms) + 1ms slack → the timer decides it was a
        // real Escape press (cancel) and delivers it even though the user
        // will never press another key.
        async.elapse(const Duration(milliseconds: 6));
        expect(emitted, [isA<EscapeKey>()],
            reason: 'without this timer a lone ESC sits held forever — '
                'cancel appears dead');
      });
    });

    test('after a timed ESC release the next key is delivered, not re-held',
        () {
      fakeAsync((async) {
        final source = _FakeKeySource();
        final backend = _backend(source);
        addTearDown(backend.dispose);
        final emitted = <InputEvent>[];
        backend.events.listen(emitted.add);

        backend.pumpedInputForTest(0x1b);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 6));
        backend.pumpedInputForTest('x'.codeUnitAt(0));
        async.flushMicrotasks();
        expect(emitted, [isA<EscapeKey>(), isA<CharInput>()],
            reason: 'release must leave the filter idle, not holding');
      });
    });

    test('ESC followed by a non-introducer key releases both immediately',
        () {
      fakeAsync((async) {
        final source = _FakeKeySource();
        final backend = _backend(source);
        addTearDown(backend.dispose);
        final emitted = <InputEvent>[];
        backend.events.listen(emitted.add);

        // A human's ESC-then-arrow is two events inside the window; 'up' is
        // not a sequence introducer, so both must be delivered untouched.
        backend.pumpedInputForTest(0x1b);
        backend.pumpedInputForTest(nc.NcKey.up);
        async.flushMicrotasks();
        expect(emitted, hasLength(2));
        expect(emitted.first, isA<EscapeKey>());
        expect(emitted.last, isA<ArrowKey>());

        async.elapse(const Duration(milliseconds: 6));
        expect(emitted, hasLength(2),
            reason: 'nothing extra may leak out of the timer afterwards');
      });
    });

    test('a control key inside a reply aborts the swallow and is delivered',
        () {
      fakeAsync((async) {
        final source = _FakeKeySource();
        final backend = _backend(source);
        addTearDown(backend.dispose);
        final emitted = <InputEvent>[];
        backend.events.listen(emitted.add);

        // ESC ] starts an OSC reply; Enter mid-reply is a real key press —
        // the swallow must stop there rather than eat the user's Enter.
        backend.pumpedInputForTest(0x1b);
        backend.pumpedInputForTest(0x5d); // ]
        backend.pumpedInputForTest(nc.NcKey.enter);
        async.flushMicrotasks();
        expect(emitted, [isA<ControlKey>()],
            reason: 'Enter must never be eaten by a reply swallow');

        // And the filter is out of reply state: typing flows normally.
        backend.pumpedInputForTest('q'.codeUnitAt(0));
        async.flushMicrotasks();
        expect(emitted.last, isA<CharInput>());
      });
    });

    test('an unterminated reply is abandoned at maxReplyLength, end to end',
        () {
      fakeAsync((async) {
        final source = _FakeKeySource();
        final backend = NotcursesInputBackend(
          source,
          startupDrainMinWindow: Duration.zero,
          startPolling: false,
          temporalPasteDetection: false,
          replyFilter: ReplySequenceFilter(maxReplyLength: 2),
        );
        addTearDown(backend.dispose);
        final emitted = <InputEvent>[];
        backend.events.listen(emitted.add);

        backend.pumpedInputForTest(0x1b);
        backend.pumpedInputForTest(0x50); // 'P' — DCS: only ESC \ ends it
        backend.pumpedInputForTest('a'.codeUnitAt(0));
        backend.pumpedInputForTest('b'.codeUnitAt(0));
        backend.pumpedInputForTest('c'.codeUnitAt(0));
        async.flushMicrotasks();
        final chars =
            emitted.whereType<CharInput>().map((e) => e.text).join();
        expect(chars, 'c',
            reason: 'the hatch swallows exactly maxReplyLength bytes, then '
                'releases the next one as ordinary typing; without the '
                'hatch the whole keyboard stays swallowed');
      });
    });

    test('the poll path bypasses the reply filter (documented asymmetry)', () {
      final source = _FakeKeySource();
      final backend = _backend(source);
      addTearDown(backend.dispose);
      final emitted = <InputEvent>[];
      backend.events.listen(emitted.add);

      source.add(0x1b);
      backend.pollForTest();
      expect(emitted, [isA<EscapeKey>()],
          reason: 'the wedge can only arrive through the pump path; the '
              'poll path (used by tests and legacy backends) delivers '
              'directly — pinning this so a refactor cannot silently '
              'move the filter in front of it');
    });

    test('dispose() while an ESC is held leaves no live release timer', () {
      fakeAsync((async) {
        final source = _FakeKeySource();
        final backend = _backend(source);
        final emitted = <InputEvent>[];
        backend.events.listen(emitted.add);

        backend.pumpedInputForTest(0x1b);
        async.flushMicrotasks();
        backend.dispose();

        async.elapse(const Duration(milliseconds: 50));
        expect(emitted, isEmpty,
            reason: 'a timer firing after dispose must deliver nothing '
                'and must not throw on a closed controller');
      });
    });
  });
}
