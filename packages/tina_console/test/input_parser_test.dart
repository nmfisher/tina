import 'package:tina_console/src/input_event.dart';
import 'package:tina_console/src/input_parser.dart';
import 'package:test/test.dart';

void main() {
  group('InputParser', () {
    late InputParser parser;

    setUp(() => parser = InputParser());

    test('ASCII printable characters produce CharInput', () {
      final event = parser.feed(0x41); // 'A'
      expect(event, isA<CharInput>());
      expect((event as CharInput).text, 'A');
    });

    test('control codes produce ControlKey', () {
      expect(parser.feed(0x17), ControlKey(ControlCode.ctrlW));
      expect(parser.feed(0x07), ControlKey(ControlCode.ctrlG));
      expect(parser.feed(0x03), ControlKey(ControlCode.ctrlC));
      expect(parser.feed(0x04), ControlKey(ControlCode.ctrlD));
      expect(parser.feed(0x0d), ControlKey(ControlCode.enter));
      expect(parser.feed(0x0a), ControlKey(ControlCode.enter));
      expect(parser.feed(0x09), ControlKey(ControlCode.tab));
      expect(parser.feed(0x7f), ControlKey(ControlCode.backspace));
      expect(parser.feed(0x08), ControlKey(ControlCode.backspace));
      expect(parser.feed(0x0c), ControlKey(ControlCode.ctrlL));
      expect(parser.feed(0x13), ControlKey(ControlCode.ctrlS));
    });

    test('Ctrl-A produces EditingAction.home', () {
      expect(parser.feed(0x01), EditingKey(EditingAction.home));
    });

    test('Ctrl-E produces EditingAction.end', () {
      expect(parser.feed(0x05), EditingKey(EditingAction.end));
    });

    test('Ctrl-K produces EditingAction.killToEnd', () {
      expect(parser.feed(0x0b), EditingKey(EditingAction.killToEnd));
    });

    test('Ctrl-U produces EditingAction.killToStart', () {
      expect(parser.feed(0x15), EditingKey(EditingAction.killToStart));
    });

    test('other control chars < 0x20 are ignored', () {
      expect(parser.feed(0x02), isNull);
      expect(parser.feed(0x06), isNull);
      expect(parser.feed(0x10), isNull);
    });

    test('CSI 1;5A produces Ctrl+ArrowUp (spatial nav)', () {
      parser.feed(0x1b);
      parser.feed(0x5b);
      parser.feed(0x31); // '1'
      parser.feed(0x3b); // ';'
      parser.feed(0x35); // '5' — modifier: Ctrl
      expect(parser.feed(0x41),
          equals(ArrowKey(ArrowDirection.up, hasCtrl: true)));
    });

    test('CSI 1;5C produces Ctrl+ArrowRight', () {
      parser.feed(0x1b);
      parser.feed(0x5b);
      parser.feed(0x31);
      parser.feed(0x3b);
      parser.feed(0x35);
      expect(parser.feed(0x43),
          equals(ArrowKey(ArrowDirection.right, hasCtrl: true)));
    });

    test('CSI 1;2A (Shift+Arrow) does NOT set hasCtrl', () {
      // Modifier 2 = shift only. Falls through to plain-arrow shape.
      parser.feed(0x1b);
      parser.feed(0x5b);
      parser.feed(0x31);
      parser.feed(0x3b);
      parser.feed(0x32);
      final ev = parser.feed(0x41);
      expect(ev, isA<ArrowKey>());
      expect((ev as ArrowKey).hasCtrl, isFalse);
    });

    test('CSI Z produces backtab (Shift+Tab), distinct from plain Tab', () {
      parser.feed(0x1b);
      parser.feed(0x5b);
      expect(parser.feed(0x5a), equals(ControlKey(ControlCode.backtab)));
      // Plain Tab (0x09) remains its own key — completion, not cycling.
      expect(parser.feed(0x09), equals(ControlKey(ControlCode.tab)));
    });

    test('ESC Z (no bracket) is still Alt+z, not backtab', () {
      parser.feed(0x1b);
      expect(parser.feed(0x5a), isA<AltKey>());
    });

    test('plain arrow ArrowKey equality treats hasCtrl:false as default', () {
      // Regression fence for the equality contract — existing test files
      // rely on `ArrowKey(dir)` matching parser output.
      expect(ArrowKey(ArrowDirection.up),
          equals(ArrowKey(ArrowDirection.up, hasCtrl: false)));
    });

    test('ESC ESC [ D (macOS Terminal Alt+Left) produces Alt+ArrowLeft', () {
      parser.feed(0x1b);
      expect(parser.feed(0x1b), isNull);
      expect(parser.feed(0x5b), isNull); // '['
      expect(parser.feed(0x44), // 'D'
          equals(ArrowKey(ArrowDirection.left, hasAlt: true)));
    });

    test('ESC ESC [ C (macOS Terminal Alt+Right) produces Alt+ArrowRight', () {
      parser.feed(0x1b);
      expect(parser.feed(0x1b), isNull);
      expect(parser.feed(0x5b), isNull);
      expect(parser.feed(0x43),
          equals(ArrowKey(ArrowDirection.right, hasAlt: true)));
    });

    test('ESC ESC [ 1;5C (Alt+Ctrl+Arrow) sets both modifiers', () {
      parser.feed(0x1b);
      parser.feed(0x1b);
      parser.feed(0x5b);
      parser.feed(0x31); // '1'
      parser.feed(0x3b); // ';'
      parser.feed(0x35); // '5' — Ctrl
      expect(parser.feed(0x43),
          equals(ArrowKey(ArrowDirection.right, hasCtrl: true, hasAlt: true)));
    });

    test('ESC ESC [ D leaves no Alt residue on later sequences', () {
      parser.feed(0x1b);
      parser.feed(0x1b);
      parser.feed(0x5b);
      expect(parser.feed(0x44),
          equals(ArrowKey(ArrowDirection.left, hasAlt: true)));
      parser.feed(0x1b);
      parser.feed(0x5b);
      expect(parser.feed(0x44), equals(ArrowKey(ArrowDirection.left)));
    });

    test('ESC ESC [ A produces plain ArrowUp (Alt stamp only matters for editor word-motion)', () {
      // The parser stamps hasAlt on any ESC-prefixed arrow; consumers that
      // don't care about Alt (spatial nav, pickers) ignore it.
      parser.feed(0x1b);
      parser.feed(0x1b);
      parser.feed(0x5b);
      expect(parser.feed(0x41), equals(ArrowKey(ArrowDirection.up, hasAlt: true)));
    });

    test('ESC [ A produces ArrowUp', () {
      expect(parser.feed(0x1b), isNull); // ESC start
      expect(parser.feed(0x5b), isNull); // '['
      final event = parser.feed(0x41); // 'A'
      expect(event, ArrowKey(ArrowDirection.up));
    });

    test('ESC [ B produces ArrowDown', () {
      parser.feed(0x1b);
      parser.feed(0x5b);
      expect(parser.feed(0x42), ArrowKey(ArrowDirection.down));
    });

    test('ESC [ C produces ArrowRight', () {
      parser.feed(0x1b);
      parser.feed(0x5b);
      expect(parser.feed(0x43), ArrowKey(ArrowDirection.right));
    });

    test('ESC [ D produces ArrowLeft', () {
      parser.feed(0x1b);
      parser.feed(0x5b);
      expect(parser.feed(0x44), ArrowKey(ArrowDirection.left));
    });

    test('ESC [ H produces EditingAction.home', () {
      parser.feed(0x1b);
      parser.feed(0x5b);
      expect(parser.feed(0x48), EditingKey(EditingAction.home));
    });

    test('ESC [ F produces EditingAction.end', () {
      parser.feed(0x1b);
      parser.feed(0x5b);
      expect(parser.feed(0x46), EditingKey(EditingAction.end));
    });

    test('ESC [ 3 ~ produces EditingAction.delete', () {
      parser.feed(0x1b);
      parser.feed(0x5b);
      parser.feed(0x33); // '3'
      expect(parser.feed(0x7e), EditingKey(EditingAction.delete)); // '~'
    });

    test('ESC [ 5 ~ produces ArrowKey(ArrowDirection.pageUp)', () {
      parser.feed(0x1b);
      parser.feed(0x5b);
      parser.feed(0x35); // '5'
      expect(parser.feed(0x7e),
          ArrowKey(ArrowDirection.pageUp)); // '~'
    });

    test('ESC [ 6 ~ produces ArrowKey(ArrowDirection.pageDown)', () {
      parser.feed(0x1b);
      parser.feed(0x5b);
      parser.feed(0x36); // '6'
      expect(parser.feed(0x7e),
          ArrowKey(ArrowDirection.pageDown)); // '~'
    });

    test('ESC O H (SS3 Home) produces EditingAction.home', () {
      parser.feed(0x1b);
      parser.feed(0x4f); // 'O'
      expect(parser.feed(0x48), EditingKey(EditingAction.home));
    });

    test('ESC O F (SS3 End) produces EditingAction.end', () {
      parser.feed(0x1b);
      parser.feed(0x4f); // 'O'
      expect(parser.feed(0x46), EditingKey(EditingAction.end));
    });

    // -- Alt+letter ----------------------------------------------------------

    test('ESC + lowercase letter produces AltKey', () {
      parser.feed(0x1b);
      final event = parser.feed(0x66); // 'f'
      expect(event, isA<AltKey>());
      expect((event as AltKey).letter, 0x66);
    });

    test('ESC + uppercase letter normalizes to lowercase', () {
      parser.feed(0x1b);
      final event = parser.feed(0x46); // 'F'
      expect(event, isA<AltKey>());
      expect((event as AltKey).letter, 0x66); // lowercase 'f'
    });

    test('ESC + digit produces AltKey', () {
      parser.feed(0x1b);
      final event = parser.feed(0x31); // '1'
      expect(event, isA<AltKey>());
      expect((event as AltKey).letter, 0x31);
    });

    // -- Function keys -------------------------------------------------------

    test('F1 via SS3 produces FunctionKey.f1', () {
      parser.feed(0x1b);
      parser.feed(0x4f); // 'O'
      expect(parser.feed(0x50), FunctionKey(FunctionKeyCode.f1)); // 'P'
    });

    test('F4 via SS3 produces FunctionKey.f4', () {
      parser.feed(0x1b);
      parser.feed(0x4f);
      expect(parser.feed(0x53), FunctionKey(FunctionKeyCode.f4));
    });

    test('F5 via CSI 15~ produces FunctionKey.f5', () {
      parser.feed(0x1b);
      parser.feed(0x5b);
      parser.feed(0x31); // '1'
      expect(parser.feed(0x35), isNull); // '5' — not final
      expect(parser.feed(0x7e), FunctionKey(FunctionKeyCode.f5));
    });

    test('F10 via CSI 21~ produces FunctionKey.f10', () {
      parser.feed(0x1b);
      parser.feed(0x5b);
      parser.feed(0x32); // '2'
      parser.feed(0x31); // '1'
      expect(parser.feed(0x7e), FunctionKey(FunctionKeyCode.f10));
    });

    test('F12 via CSI 24~ produces FunctionKey.f12', () {
      parser.feed(0x1b);
      parser.feed(0x5b);
      parser.feed(0x32); // '2'
      parser.feed(0x34); // '4'
      expect(parser.feed(0x7e), FunctionKey(FunctionKeyCode.f12));
    });

    test('two-byte escape (ESC + non-bracket) produces AltKey', () {
      parser.feed(0x1b);
      // ESC followed by a byte that isn't [ or O — Alt+letter.
      final result = parser.feed(0x50); // 'P'
      expect(result, isA<AltKey>());
      expect((result as AltKey).letter, 0x70); // normalized to lowercase
    });

    test('ESC + non-printable produces no event', () {
      parser.feed(0x1b);
      final result = parser.feed(0x01); // non-printable
      expect(result, isNull);
    });

    test('long CSI sequence is consumed until final byte without leaking', () {
      // Simulate a long terminal query response like DA2: \e[>65;6003;1c
      // (14 bytes). Previously the parser aborted at 8 bytes, leaking the
      // remaining bytes as visible characters. Now it swallows everything
      // until the CSI final byte.
      parser.feed(0x1b); // ESC
      parser.feed(0x5b); // [
      // Feed 10 parameter bytes (no final byte yet) — exceeds old 8-byte limit
      for (var i = 0; i < 10; i++) {
        expect(parser.feed(0x30 + (i % 10)), isNull);
      }
      // Final byte 'c' (0x63) ends the sequence — must not produce an event
      expect(parser.feed(0x63), isNull);
      // Bytes after the sequence are treated as fresh input (no leakage)
      final next = parser.feed(0x41); // 'A'
      expect(next, isA<CharInput>());
      expect((next as CharInput).text, 'A');
    });

    test('OSC 11 reply (BEL-terminated) is consumed silently', () {
      // \e]11;rgb:1e1f/2223/2628\x07 — xterm/GNOME OSC 11 background reply.
      // Previously `ESC]` fell through as `AltKey(']')` and the payload bytes
      // leaked as CharInput. Now the whole sequence is discarded.
      final bytes = <int>[
        0x1b, 0x5d, // ESC ]
        0x31, 0x31, // '11'
        0x3b, // ';'
        ...'rgb:1e1f/2223/2628'.codeUnits,
        0x07, // BEL terminator
      ];
      InputEvent? ev;
      for (final b in bytes) {
        ev = parser.feed(b);
        expect(ev, isNull, reason: 'OSC payload byte 0x${b.toRadixString(16)} '
            'must not produce an event');
      }
      expect(parser.isMidSequence, isFalse,
          reason: 'OSC ended by BEL — parser must be idle');
      // Normal typing resumes cleanly after the discarded OSC.
      expect(parser.feed(0x41), CharInput('A'));
    });

    test('OSC reply (ST-terminated) is consumed silently', () {
      // \e]11;rgb:0/0/0\e\\ — ST-terminated OSC (some terminals use ESC \
      // instead of BEL). The ESC mid-payload is the ST lead byte; the
      // following '\' closes the sequence.
      final bytes = <int>[
        0x1b, 0x5d, // ESC ]
        ...'11;rgb:0/0/0'.codeUnits,
        0x1b, 0x5c, // ST (ESC \)
      ];
      InputEvent? ev;
      for (final b in bytes) {
        ev = parser.feed(b);
        expect(ev, isNull, reason: 'ST-terminated OSC byte 0x${b.toRadixString(16)} '
            'must not produce an event');
      }
      expect(parser.isMidSequence, isFalse);
      expect(parser.feed(0x42), CharInput('B'));
    });

    test('OSC payload containing a bare ESC does not terminate early', () {
      // A stray ESC inside an OSC payload that isn't followed by '\' must not
      // close the sequence — keep discarding until the real terminator.
      final bytes = <int>[
        0x1b, 0x5d, // ESC ]
        ...'11;'.codeUnits,
        0x1b, // bare ESC (not ST — next byte isn't '\')
        ...'oops'.codeUnits,
        0x1b, 0x5c, // real ST terminator
      ];
      InputEvent? ev;
      for (final b in bytes) {
        ev = parser.feed(b);
        expect(ev, isNull);
      }
      expect(parser.isMidSequence, isFalse);
      expect(parser.feed(0x43), CharInput('C'));
    });

    test('OSC without a terminator does not leak payload as input', () {
      // A truncated OSC (no BEL/ST) must not surface its payload as AltKey/
      // CharInput. The parser stays mid-sequence and a subsequent reset
      // cleanly reclaims it.
      final bytes = <int>[0x1b, 0x5d, ...'11;rgb:cafe'.codeUnits];
      for (final b in bytes) {
        expect(parser.feed(b), isNull);
      }
      expect(parser.isMidSequence, isTrue, reason: 'unterminated OSC is pending');
      parser.reset();
      expect(parser.isMidSequence, isFalse);
      expect(parser.feed(0x44), CharInput('D'));
    });

    test('OSC 11 reply interleaved with typing produces only the typed chars', () {
      // Type 'hi', then a late OSC 11 reply arrives, then type 'bye' — only
      // h,i,b,y,e should surface; the OSC payload is discarded entirely.
      expect(parser.feed(0x68), CharInput('h'));
      expect(parser.feed(0x69), CharInput('i'));
      final osc = <int>[
        0x1b, 0x5d,
        ...'11;rgb:ffff/ffff/ffff'.codeUnits,
        0x07,
      ];
      for (final b in osc) {
        expect(parser.feed(b), isNull);
      }
      expect(parser.feed(0x62), CharInput('b'));
      expect(parser.feed(0x79), CharInput('y'));
      expect(parser.feed(0x65), CharInput('e'));
    });

    test('bracketed paste start \\e[200~ begins collecting', () {
      // \e[200~ — terminal sends this before pasted text. The marker is
      // consumed (returns null) and the parser enters paste-collection mode.
      for (final b in [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]) {
        expect(parser.feed(b), isNull);
      }
      expect(parser.isMidSequence, isTrue,
          reason: 'a paste is in progress; more bytes are needed');
      // Bytes inside a paste are buffered, not decoded — they return null
      // until the end marker arrives.
      expect(parser.feed(0x41), isNull); // 'A' buffered, not a CharInput
    });

    test('bracketed paste end \\e[201~ without a start is consumed silently', () {
      // A stray end marker (no matching start) is harmlessly consumed and does
      // not leave the parser in a weird state.
      for (final b in [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]) {
        expect(parser.feed(b), isNull);
      }
      expect(parser.feed(0x42), isA<CharInput>()); // 'B' — normal typing resumes
    });

    test('full bracketed paste emits a single PasteInput', () {
      // Simulate \e[200~Hello\e[201~
      for (final b in [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]) {
        parser.feed(b); // paste start — consumed
      }
      expect(parser.feed(0x48), isNull); // 'H' buffered
      expect(parser.feed(0x65), isNull); // 'e' buffered
      InputEvent? paste;
      for (final b in [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]) {
        paste = parser.feed(b); // paste end — flushes a PasteInput
      }
      expect(paste, isA<PasteInput>());
      expect((paste as PasteInput).text, 'He');
      expect(parser.isMidSequence, isFalse);
      // Normal typing resumes.
      expect(parser.feed(0x58), isA<CharInput>()); // 'X'
    });

    test('paste preserves embedded newlines and tabs', () {
      // \e[200~line1\nline2\tend\e[201~ — newlines/tabs must survive rather
      // than becoming Enter/Tab keystrokes.
      final bytes = <int>[
        0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e, // start
        ...'line1\nline2\tend'.codeUnits, // content
        0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e, // end
      ];
      InputEvent? paste;
      for (final b in bytes) {
        paste = parser.feed(b);
      }
      expect(paste, isA<PasteInput>());
      expect((paste as PasteInput).text, 'line1\nline2\tend');
    });

    test('paste preserves multi-byte UTF-8', () {
      // "é" = 0xC3 0xA9, "世" = 0xE4 0xB8 0x96.
      const bytes = [
        0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e, // start
        0xC3, 0xA9, 0xE4, 0xB8, 0x96, // é世
        0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e, // end
      ];
      InputEvent? paste;
      for (final b in bytes) {
        paste = parser.feed(b);
      }
      expect(paste, isA<PasteInput>());
      expect((paste as PasteInput).text, 'é世');
    });

    test('reset cancels an in-progress paste', () {
      for (final b in [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]) {
        parser.feed(b); // start
      }
      parser.feed(0x48); // buffer 'H'
      expect(parser.isMidSequence, isTrue);
      parser.reset();
      expect(parser.isMidSequence, isFalse);
      // After reset, normal typing resumes (no leftover paste state).
      expect(parser.feed(0x58), isA<CharInput>()); // 'X'
    });

    test('isMidSequence tracks pending state', () {
      expect(parser.isMidSequence, false);
      parser.feed(0x1b);
      expect(parser.isMidSequence, true);
      parser.feed(0x5b);
      expect(parser.isMidSequence, true);
      parser.feed(0x41); // ArrowUp completes
      expect(parser.isMidSequence, false);
    });

    test('reset clears pending state', () {
      parser.feed(0x1b);
      parser.feed(0x5b);
      expect(parser.isMidSequence, true);
      parser.reset();
      expect(parser.isMidSequence, false);
    });

    test('UTF-8 2-byte sequence produces CharInput', () {
      // 'é' = 0xC3 0xA9
      expect(parser.feed(0xc3), isNull);
      final event = parser.feed(0xa9);
      expect(event, isA<CharInput>());
      expect((event as CharInput).text, 'é');
    });

    test('UTF-8 3-byte sequence produces CharInput', () {
      // '€' = 0xE2 0x82 0xAC
      expect(parser.feed(0xe2), isNull);
      expect(parser.feed(0x82), isNull);
      final event = parser.feed(0xac);
      expect(event, isA<CharInput>());
      expect((event as CharInput).text, '€');
    });

    test('multiple events in sequence', () {
      expect(parser.feed(0x41), CharInput('A'));
      expect(parser.feed(0x42), CharInput('B'));
      parser.feed(0x1b);
      parser.feed(0x5b);
      expect(parser.feed(0x43), ArrowKey(ArrowDirection.right));
      expect(parser.feed(0x43), CharInput('C'));
    });
  });

  group('InputParser escapeTimeout', () {
    test('standalone ESC produces EscapeKey after timeout', () async {
      InputEvent? timeoutEvent;
      final p = InputParser(
        escapeTimeout: const Duration(milliseconds: 10),
        onTimeout: (e) => timeoutEvent = e,
      );
      expect(p.feed(0x1b), isNull);
      expect(timeoutEvent, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(timeoutEvent, isA<EscapeKey>());
      expect(p.isMidSequence, isFalse);
    });

    test('ESC + following byte cancels timeout and produces AltKey', () async {
      InputEvent? timeoutEvent;
      final p = InputParser(
        escapeTimeout: const Duration(milliseconds: 10),
        onTimeout: (e) => timeoutEvent = e,
      );
      p.feed(0x1b);
      final event = p.feed(0x66); // 'f' — cancels timeout
      expect(event, isA<AltKey>());
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(timeoutEvent, isNull); // timeout never fired
    });

    test('ESC + arrow key cancels timeout', () async {
      InputEvent? timeoutEvent;
      final p = InputParser(
        escapeTimeout: const Duration(milliseconds: 10),
        onTimeout: (e) => timeoutEvent = e,
      );
      p.feed(0x1b);
      p.feed(0x5b); // '['
      final event = p.feed(0x41); // 'A' = arrow up
      expect(event, ArrowKey(ArrowDirection.up));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(timeoutEvent, isNull);
    });

    test('dispose cancels pending timeout', () async {
      InputEvent? timeoutEvent;
      final p = InputParser(
        escapeTimeout: const Duration(milliseconds: 10),
        onTimeout: (e) => timeoutEvent = e,
      );
      p.feed(0x1b);
      p.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(timeoutEvent, isNull);
    });

    test('no timeout when escapeTimeout is null', () async {
      InputEvent? timeoutEvent;
      final p = InputParser(
        onTimeout: (e) => timeoutEvent = e,
      );
      p.feed(0x1b);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(timeoutEvent, isNull);
      expect(p.isMidSequence, isTrue); // ESC still pending
    });
  });

  group('InputParser macosOptionAsMeta', () {
    test('macOS Option+F (ƒ) maps to AltKey(f)', () {
      final p = InputParser(macosOptionAsMeta: true);
      // ƒ = U+0192, UTF-8: 0xC6 0x92
      expect(p.feed(0xC6), isNull);
      final event = p.feed(0x92);
      expect(event, isA<AltKey>());
      expect((event as AltKey).letter, 0x66); // 'f'
    });

    test('macOS Option+V (√) maps to AltKey(v)', () {
      final p = InputParser(macosOptionAsMeta: true);
      // √ = U+221A, UTF-8: 0xE2 0x88 0x9A
      expect(p.feed(0xE2), isNull);
      expect(p.feed(0x88), isNull);
      final event = p.feed(0x9A);
      expect(event, isA<AltKey>());
      expect((event as AltKey).letter, 0x76); // 'v'
    });

    test('unmapped UTF-8 char passes through as CharInput', () {
      final p = InputParser(macosOptionAsMeta: true);
      // é = U+00E9 — not in the Option map
      expect(p.feed(0xC3), isNull);
      final event = p.feed(0xA9);
      expect(event, isA<CharInput>());
      expect((event as CharInput).text, 'é');
    });

    test('macOS Option chars are CharInput when flag is off', () {
      final p = InputParser(macosOptionAsMeta: false);
      // ƒ = U+0192, UTF-8: 0xC6 0x92
      expect(p.feed(0xC6), isNull);
      final event = p.feed(0x92);
      expect(event, isA<CharInput>());
      expect((event as CharInput).text, 'ƒ');
    });
  });
}
