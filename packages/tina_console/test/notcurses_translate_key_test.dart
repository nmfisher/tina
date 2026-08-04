import 'package:test/test.dart';

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/notcurses_input_backend.dart';
import 'package:dart_notcurses/dart_notcurses.dart' as nc;

/// Exercises the pure key-translation function used by [NotcursesInputBackend].
///
/// Goal: prove the mapping table delivers the same semantic events that the
/// ANSI [InputParser] does, so swapping the backend doesn't silently change
/// line-editor behavior.
void main() {
  InputEvent? translate(
    int id, {
    bool hasAlt = false,
    bool hasCtrl = false,
    bool isSynthesized = false,
  }) =>
      translateNcKey(
        id: id,
        hasAlt: hasAlt,
        hasCtrl: hasCtrl,
        isSynthesized: isSynthesized,
      );

  group('printable ASCII', () {
    test('lowercase letter → CharInput', () {
      expect(translate(0x61), equals(CharInput('a')));
      expect(translate(0x7A), equals(CharInput('z')));
    });

    test('uppercase letter → CharInput', () {
      expect(translate(0x41), equals(CharInput('A')));
      expect(translate(0x5A), equals(CharInput('Z')));
    });

    test('digit → CharInput', () {
      expect(translate(0x30), equals(CharInput('0')));
      expect(translate(0x39), equals(CharInput('9')));
    });

    test('space → CharInput', () {
      expect(translate(0x20), equals(CharInput(' ')));
    });

    test('printable with Alt → AltKey, uppercase normalized to lowercase', () {
      // Matches input_parser.dart so menu shortcuts match without case.
      expect(translate(0x61, hasAlt: true), equals(AltKey(0x61))); // alt+a
      expect(translate(0x41, hasAlt: true), equals(AltKey(0x61))); // alt+shift+a
      expect(translate(0x46, hasAlt: true), equals(AltKey(0x66))); // alt+f
      expect(translate(0x39, hasAlt: true), equals(AltKey(0x39))); // alt+9 unchanged
    });
  });

  group('UTF-8 / extended codepoints', () {
    test('non-ASCII printable (not synthesized) → CharInput', () {
      // 'é' = U+00E9
      expect(translate(0x00E9), equals(CharInput('é')));
    });

    test('synthesized id above 0x7F → not a CharInput', () {
      // NcKey.up lives in the preterunicode range; even though id > 0x7F
      // it must not collapse to a printable character.
      expect(translate(nc.NcKey.up, isSynthesized: true),
          equals(ArrowKey(ArrowDirection.up)));
    });

    test('non-ASCII with Alt → AltKey', () {
      expect(translate(0x00E9, hasAlt: true), equals(AltKey(0x00E9)));
    });
  });

  group('basic control keys', () {
    test('Enter (raw 0x0d)', () {
      expect(translate(0x0d), equals(ControlKey(ControlCode.enter)));
    });

    test('Enter (NcKey.enter)', () {
      expect(translate(nc.NcKey.enter, isSynthesized: true),
          equals(ControlKey(ControlCode.enter)));
    });

    test('Tab (raw 0x09)', () {
      expect(translate(0x09), equals(ControlKey(ControlCode.tab)));
    });

    test('Backspace (raw 0x08)', () {
      expect(translate(0x08), equals(ControlKey(ControlCode.backspace)));
    });

    test('Backspace (raw 0x7F / DEL)', () {
      expect(translate(0x7F), equals(ControlKey(ControlCode.backspace)));
    });

    test('Backspace (NcKey.backspace)', () {
      expect(translate(nc.NcKey.backspace, isSynthesized: true),
          equals(ControlKey(ControlCode.backspace)));
    });

    test('Escape (raw 0x1b)', () {
      expect(translate(0x1b), isA<EscapeKey>());
    });
  });

  group('Ctrl+letter — line editor expectations', () {
    // The ANSI parser maps these to specific editing actions (see
    // input_parser.dart). Anything the line editor uses must survive the
    // notcurses backend too, or keystrokes silently no-op.
    //
    // Each test documents both the ANSI parser's mapping (the contract) and
    // what the notcurses backend currently produces. A `skip:` marker on the
    // expectation pins the present-but-incorrect behavior so it's visible.

    test('Ctrl-C → ctrlC', () {
      // The first dedicated check requires !hasCtrl, so the fallback range
      // catches this. Either path must produce ctrlC.
      expect(translate(0x03, hasCtrl: true),
          equals(ControlKey(ControlCode.ctrlC)));
      expect(translate(0x03), equals(ControlKey(ControlCode.ctrlC)));
    });

    test('Ctrl-D → ctrlD', () {
      expect(translate(0x04, hasCtrl: true),
          equals(ControlKey(ControlCode.ctrlD)));
      expect(translate(0x04), equals(ControlKey(ControlCode.ctrlD)));
    });

    test('Ctrl-L → ctrlL', () {
      expect(translate(0x0c, hasCtrl: true),
          equals(ControlKey(ControlCode.ctrlL)));
      expect(translate(0x0c), equals(ControlKey(ControlCode.ctrlL)));
    });

    test('Ctrl-A → home', () {
      expect(translate(0x01), equals(EditingKey(EditingAction.home)));
    });

    test('Ctrl-E → end', () {
      expect(translate(0x05), equals(EditingKey(EditingAction.end)));
    });

    test('Ctrl-K → killToEnd', () {
      expect(translate(0x0b), equals(EditingKey(EditingAction.killToEnd)));
    });

    test('Ctrl-U → killToStart', () {
      expect(translate(0x15), equals(EditingKey(EditingAction.killToStart)));
    });

    test('Ctrl-W → ctrlW (FocusManager panel toggle)', () {
      expect(translate(0x17), equals(ControlKey(ControlCode.ctrlW)));
    });

    test('Ctrl-G → ctrlG (alternative panel toggle)', () {
      expect(translate(0x07), equals(ControlKey(ControlCode.ctrlG)));
      // Folded form: notcurses may deliver (letter, hasCtrl) instead of the
      // raw C0 byte — same folding path as Ctrl-W.
      expect(translate(0x67, hasCtrl: true), // 'g' + Ctrl
          equals(ControlKey(ControlCode.ctrlG)));
    });

    test('Ctrl+letter delivered as (letter, hasCtrl=true) folds to C0 byte',
        () {
      // Notcurses' extended keyboard modes deliver Ctrl+letter as
      // (id=letter, hasCtrl=true) rather than the raw 0x01–0x1a byte —
      // without folding, the printable branch would emit CharInput('w').
      expect(translate(0x77, hasCtrl: true), // 'w' + Ctrl
          equals(ControlKey(ControlCode.ctrlW)));
      expect(translate(0x57, hasCtrl: true), // 'W' + Ctrl (uppercase)
          equals(ControlKey(ControlCode.ctrlW)));
      expect(translate(0x63, hasCtrl: true), // 'c' + Ctrl
          equals(ControlKey(ControlCode.ctrlC)));
      expect(translate(0x61, hasCtrl: true), // 'a' + Ctrl
          equals(EditingKey(EditingAction.home)));
    });

    test('unmapped ctrl letter → null', () {
      // Pick one that isn't wired to anything (Ctrl-T = 0x14).
      expect(translate(0x14), isNull);
    });
  });

  group('arrow keys', () {
    test('up', () {
      expect(translate(nc.NcKey.up, isSynthesized: true),
          equals(ArrowKey(ArrowDirection.up)));
    });

    test('down', () {
      expect(translate(nc.NcKey.down, isSynthesized: true),
          equals(ArrowKey(ArrowDirection.down)));
    });

    test('left', () {
      expect(translate(nc.NcKey.left, isSynthesized: true),
          equals(ArrowKey(ArrowDirection.left)));
    });

    test('right', () {
      expect(translate(nc.NcKey.right, isSynthesized: true),
          equals(ArrowKey(ArrowDirection.right)));
    });

    test('Ctrl+Arrow propagates hasCtrl for FocusManager spatial nav', () {
      expect(
          translate(nc.NcKey.up, hasCtrl: true, isSynthesized: true),
          equals(ArrowKey(ArrowDirection.up, hasCtrl: true)));
      expect(
          translate(nc.NcKey.right, hasCtrl: true, isSynthesized: true),
          equals(ArrowKey(ArrowDirection.right, hasCtrl: true)));
    });
  });

  group('editing keys', () {
    test('Home', () {
      expect(translate(nc.NcKey.home, isSynthesized: true),
          equals(EditingKey(EditingAction.home)));
    });

    test('End', () {
      expect(translate(nc.NcKey.end, isSynthesized: true),
          equals(EditingKey(EditingAction.end)));
    });

    test('Delete', () {
      expect(translate(nc.NcKey.del, isSynthesized: true),
          equals(EditingKey(EditingAction.delete)));
    });
  });

  group('function keys', () {
    test('F1–F12 map to FunctionKeyCode', () {
      final pairs = <int, FunctionKeyCode>{
        nc.NcKey.f01: FunctionKeyCode.f1,
        nc.NcKey.f02: FunctionKeyCode.f2,
        nc.NcKey.f03: FunctionKeyCode.f3,
        nc.NcKey.f04: FunctionKeyCode.f4,
        nc.NcKey.f05: FunctionKeyCode.f5,
        nc.NcKey.f06: FunctionKeyCode.f6,
        nc.NcKey.f07: FunctionKeyCode.f7,
        nc.NcKey.f08: FunctionKeyCode.f8,
        nc.NcKey.f09: FunctionKeyCode.f9,
        nc.NcKey.f10: FunctionKeyCode.f10,
        nc.NcKey.f11: FunctionKeyCode.f11,
        nc.NcKey.f12: FunctionKeyCode.f12,
      };
      for (final entry in pairs.entries) {
        expect(translate(entry.key, isSynthesized: true),
            equals(FunctionKey(entry.value)),
            reason: 'function key ${entry.value}');
      }
    });

    test('NcKey.f00 → null (no F0 key in our enum, not tab)', () {
      // NcKey.f00 = preterunicode(20) is function key 0, not tab. Tab is
      // a separate alias for the raw 0x09 byte. F0 keys are not in
      // FunctionKeyCode, so we deliver null.
      expect(translate(nc.NcKey.f00, isSynthesized: true), isNull);
    });
  });

  group('Alt + letter', () {
    test('lowercase letter with Alt is caught in printable branch', () {
      expect(translate(0x66, hasAlt: true), equals(AltKey(0x66))); // Alt+f
    });

    test('non-printable id with hasAlt and lowercase range → AltKey', () {
      // Tests the second AltKey branch (after the function-key check). With
      // the printable branch already catching id in [0x20, 0x7F), this branch
      // is effectively dead for any normal letter — the test confirms that.
      // Trying a value that has hasAlt but lies outside the printable range:
      // there isn't really a clean way to hit that branch, so this test is
      // documentary only.
      expect(translate(0x61, hasAlt: true), equals(AltKey(0x61)));
    });
  });

  group('resize and unhandled events', () {
    test('NcKey.resize → null (SIGWINCH handled elsewhere)', () {
      expect(translate(nc.NcKey.resize, isSynthesized: true), isNull);
    });

    test('unknown id → null', () {
      // An arbitrary synthesized id we don't translate.
      expect(translate(nc.NcKey.invalid, isSynthesized: true), isNull);
    });
  });

  group('exotic NcKey ids — all unmapped → null', () {
    // Pins the boundary. If a future change starts producing events for
    // any of these, this test will catch it. The line editor isn't
    // prepared to react to mouse / modifier-only / signal events, so
    // letting them leak in would be a behavioural regression.
    test('mouse buttons → null', () {
      for (final id in [
        nc.NcKey.motion,
        nc.NcKey.button1,
        nc.NcKey.button2,
        nc.NcKey.button3,
        nc.NcKey.button4,
        nc.NcKey.button5,
        nc.NcKey.button6,
        nc.NcKey.button7,
        nc.NcKey.button8,
        nc.NcKey.button9,
        nc.NcKey.button10,
        nc.NcKey.button11,
      ]) {
        expect(translate(id, isSynthesized: true), isNull,
            reason: 'mouse id $id should not produce an InputEvent');
      }
    });

    test('modifier-only keys → null', () {
      for (final id in [
        nc.NcKey.lshift,
        nc.NcKey.lctrl,
        nc.NcKey.lalt,
        nc.NcKey.lsuper,
        nc.NcKey.lhyper,
        nc.NcKey.lmeta,
        nc.NcKey.rshift,
        nc.NcKey.rctrl,
        nc.NcKey.ralt,
        nc.NcKey.rsuper,
        nc.NcKey.rhyper,
        nc.NcKey.rmeta,
        nc.NcKey.capsLock,
        nc.NcKey.scrollLock,
        nc.NcKey.numLock,
      ]) {
        expect(translate(id, isSynthesized: true), isNull,
            reason: 'modifier id $id must not become an InputEvent');
      }
    });

    test('signal / lifecycle keys → null', () {
      for (final id in [
        nc.NcKey.signal, // SIGCONT
        nc.NcKey.eof,
        nc.NcKey.cancel,
        nc.NcKey.exit,
        nc.NcKey.close,
        nc.NcKey.pause,
      ]) {
        expect(translate(id, isSynthesized: true), isNull,
            reason: 'lifecycle id $id should not produce an InputEvent');
      }
    });

    test('pgup → ArrowKey(pageUp)', () {
      expect(
        translate(nc.NcKey.pgup, isSynthesized: true),
        ArrowKey(ArrowDirection.pageUp),
      );
    });

    test('pgdown → ArrowKey(pageDown)', () {
      expect(
        translate(nc.NcKey.pgdown, isSynthesized: true),
        ArrowKey(ArrowDirection.pageDown),
      );
    });

    test('navigation keypad extras → null (unmapped)', () {
      // dleft/dright/uleft/uright are diagonal keypad keys; we don't map
      // them. ins likewise — line editor doesn't bind it.
      for (final id in [
        nc.NcKey.ins,
        nc.NcKey.dleft,
        nc.NcKey.dright,
        nc.NcKey.uleft,
        nc.NcKey.uright,
        nc.NcKey.center,
        nc.NcKey.begin,
        nc.NcKey.cls,
      ]) {
        expect(translate(id, isSynthesized: true), isNull,
            reason: 'extra navigation id $id should not produce an InputEvent');
      }
    });

    test('media keys → null (no bindings)', () {
      for (final id in [
        nc.NcKey.mediaPlay,
        nc.NcKey.mediaPause,
        nc.NcKey.mediaStop,
        nc.NcKey.mediaNext,
        nc.NcKey.mediaPrev,
        nc.NcKey.mediaMute,
      ]) {
        expect(translate(id, isSynthesized: true), isNull,
            reason: 'media id $id should not produce an InputEvent');
      }
    });
  });
}
