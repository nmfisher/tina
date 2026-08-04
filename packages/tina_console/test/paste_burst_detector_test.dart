import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/paste_burst_detector.dart';

/// The notcurses backend has no paste markers (notcurses swallows them), so
/// paste detection relies on temporal clustering. These tests pin the
/// detector's behavior against the timing data the dart_notcurses paste spike
/// measured: paste intra-burst gaps ~15–30µs, typing gaps ≥50ms.
void main() {
  group('PasteBurstDetector', () {
    test('single keystroke emits as-is (no burst)', () {
      final d = PasteBurstDetector();
      final out = d.add(CharInput('a'), 1000);
      expect(out, isEmpty);
      final flushed = d.flush();
      expect(flushed, [CharInput('a')]);
    });

    test('two quick keys below threshold emit individually', () {
      // Two chars within the window, but < minPasteChars (8) → not a paste.
      final d = PasteBurstDetector(minPasteChars: 8);
      d.add(CharInput('a'), 1000);
      final out = d.add(CharInput('b'), 1010);
      expect(out, isEmpty);
      final flushed = d.flush();
      expect(flushed, [CharInput('a'), CharInput('b')]);
    });

    test('a burst of >= threshold chars becomes one PasteInput', () {
      final d = PasteBurstDetector(minPasteChars: 8);
      final text = 'roller.openSpawn'; // 16 chars
      var t = 1000;
      var last = <InputEvent>[];
      for (final c in text.split('')) {
        last = d.add(CharInput(c), t);
        t += 20; // 20µs gaps — well within the join window
      }
      // Nothing emitted until the burst is flushed (gap or explicit flush).
      expect(last, isEmpty);
      final flushed = d.flush();
      expect(flushed, hasLength(1));
      expect(flushed.first, isA<PasteInput>());
      expect((flushed.first as PasteInput).text, text);
    });

    test('a gap larger than the window flushes the previous burst', () {
      final d = PasteBurstDetector(minPasteChars: 8, joinWindow: const Duration(milliseconds: 30));
      // Build a burst of 10 chars at 20µs spacing.
      var t = 1000;
      for (var i = 0; i < 10; i++) {
        d.add(CharInput('x'), t);
        t += 20;
      }
      // Now a key arriving 50ms later — past the join window — flushes first.
      final out = d.add(CharInput('y'), t + 50000);
      // The flush emits the paste; 'y' starts a fresh (single) burst.
      expect(out, hasLength(1));
      expect(out.first, isA<PasteInput>());
      expect((out.first as PasteInput).text, 'x' * 10);
      // 'y' is now buffered alone.
      expect(d.flush(), [CharInput('y')]);
    });

    test('expire flushes a burst that stopped forming', () {
      // The core correctness property: a paste's last event arrives, then no
      // more input. Without expire(), the paste would sit buffered forever.
      final d = PasteBurstDetector(minPasteChars: 8, joinWindow: const Duration(milliseconds: 30));
      var t = 1000;
      for (var i = 0; i < 12; i++) {
        d.add(CharInput('z'), t);
        t += 20;
      }
      // Same instant — nothing expired yet (gap since last event is 0).
      expect(d.expire(t), isEmpty);
      // 31ms later — past the window — the burst flushes as a paste.
      final expired = d.expire(t + 31000);
      expect(expired, hasLength(1));
      expect((expired.first as PasteInput).text, 'z' * 12);
      // Subsequent expire is a no-op.
      expect(d.expire(t + 100000), isEmpty);
    });

    test('a pasted Enter is folded into the PasteInput as newline, not submit', () {
      // The spike showed a paste's trailing newline arrives as NCKEY_ENTER at
      // a 19µs gap — indistinguishable from paste chars. It MUST become \n in
      // the joined paste, not a ControlKey(enter) that submits mid-paste.
      final d = PasteBurstDetector(minPasteChars: 4);
      final out = d.add(CharInput('a'), 1000)
        ..addAll(d.add(CharInput('b'), 1020))
        ..addAll(d.add(CharInput('c'), 1040))
        ..addAll(d.add(ControlKey(ControlCode.enter), 1060));
      expect(out, isEmpty);
      final flushed = d.flush();
      expect(flushed, hasLength(1));
      expect((flushed.first as PasteInput).text, 'abc\n');
    });

    test('a pasted Tab is folded into the PasteInput as tab', () {
      final d = PasteBurstDetector(minPasteChars: 4);
      d.add(CharInput('a'), 1000);
      d.add(CharInput('b'), 1010);
      d.add(ControlKey(ControlCode.tab), 1020);
      d.add(CharInput('c'), 1030);
      d.add(CharInput('d'), 1040);
      final flushed = d.flush();
      expect(flushed, hasLength(1));
      expect((flushed.first as PasteInput).text, 'ab\tcd');
    });

    test('multi-line paste preserves all newlines', () {
      // The whole point: a multi-line paste keeps its embedded newlines so the
      // model receives them, instead of the first newline submitting the line.
      final d = PasteBurstDetector(minPasteChars: 8);
      final lines = ['line1', 'line2', 'line3'];
      var t = 1000;
      for (final line in lines) {
        for (final c in line.split('')) {
          d.add(CharInput(c), t);
          t += 15;
        }
        d.add(ControlKey(ControlCode.enter), t);
        t += 15;
      }
      final flushed = d.flush();
      expect(flushed, hasLength(1));
      expect((flushed.first as PasteInput).text, 'line1\nline2\nline3\n');
      // Rune count = 5+1 + 5+1 + 5+1 = 18.
      expect((flushed.first as PasteInput).text.runes.length, 18);
    });

    test('typing (slow gaps) never forms a paste', () {
      // 10 chars but 100ms apart — clearly typing, not a paste.
      final d = PasteBurstDetector(minPasteChars: 8, joinWindow: const Duration(milliseconds: 30));
      var t = 1000;
      final emitted = <InputEvent>[];
      for (var i = 0; i < 10; i++) {
        emitted.addAll(d.add(CharInput('k'), t));
        t += 100000; // 100ms
      }
      // Each key flushed the previous (single, below-threshold) burst, so
      // each emits individually. The last key is flushed by expire.
      emitted.addAll(d.expire(t));
      // No PasteInput anywhere — all CharInput.
      expect(emitted.whereType<PasteInput>(), isEmpty);
      expect(emitted.whereType<CharInput>(), hasLength(10));
    });

    test('non-text events inside a burst are dropped, not counted', () {
      // An arrow key mid-paste shouldn't break the paste or inflate the char
      // count. It contributes nothing to the joined text. 8 chars clear the
      // threshold; the arrow adds 0, so the burst still qualifies as a paste.
      final d = PasteBurstDetector(minPasteChars: 8);
      d.add(CharInput('a'), 1000);
      d.add(CharInput('b'), 1010);
      d.add(ArrowKey(ArrowDirection.left), 1020);
      d.add(CharInput('c'), 1030);
      d.add(CharInput('d'), 1040);
      d.add(CharInput('e'), 1050);
      d.add(CharInput('f'), 1060);
      d.add(CharInput('g'), 1070);
      d.add(CharInput('h'), 1080);
      d.add(CharInput('i'), 1090);
      final flushed = d.flush();
      expect(flushed, hasLength(1));
      expect((flushed.first as PasteInput).text, 'abcdefghi');
    });

    test('two separate pastes with a typing gap between them', () {
      final d = PasteBurstDetector(minPasteChars: 8, joinWindow: const Duration(milliseconds: 30));
      final emitted = <InputEvent>[];
      // Paste 1: 10 chars, 20µs apart.
      var t = 1000;
      for (var i = 0; i < 10; i++) {
        emitted.addAll(d.add(CharInput('a'), t));
        t += 20;
      }
      // Typing gap: 200ms.
      t += 200000;
      // Paste 2: 10 chars, 20µs apart.
      for (var i = 0; i < 10; i++) {
        emitted.addAll(d.add(CharInput('b'), t));
        t += 20;
      }
      // The first 'b' (200ms after the last 'a') flushes paste 1.
      expect(emitted, hasLength(1));
      expect((emitted.first as PasteInput).text, 'a' * 10);
      // Paste 2 still buffered.
      emitted.clear();
      emitted.addAll(d.expire(t + 50000));
      expect(emitted, hasLength(1));
      expect((emitted.first as PasteInput).text, 'b' * 10);
    });

    test('flush on empty detector is a no-op', () {
      final d = PasteBurstDetector();
      expect(d.flush(), isEmpty);
      expect(d.expire(0), isEmpty);
      expect(d.hasPending, isFalse);
    });

    test('hasPending reflects buffer state', () {
      final d = PasteBurstDetector();
      expect(d.hasPending, isFalse);
      d.add(CharInput('a'), 1000);
      expect(d.hasPending, isTrue);
      d.flush();
      expect(d.hasPending, isFalse);
    });
  });
}
