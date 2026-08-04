import 'package:test/test.dart';

import 'package:tina_console/src/backend/notcurses_backend.dart';

/// Unit tests for [visibleColumns] — the helper used by
/// [NotcursesBackend.writeText] to advance the logical cursor past embedded
/// ANSI escapes so the cursor doesn't drift right by the length of the
/// escape codes themselves.
void main() {
  group('visibleColumns', () {
    test('plain ASCII counts every character', () {
      expect(visibleColumns('hello'), 5);
      expect(visibleColumns(''), 0);
    });

    test('ANSI SGR opening and closing are skipped', () {
      // \x1b[31mhello\x1b[0m → 5 visible columns
      expect(visibleColumns('\x1b[31mhello\x1b[0m'), 5);
    });

    test('multiple SGR sequences in one string', () {
      // \x1b[1m\x1b[31mok\x1b[0m → 2 visible columns
      expect(visibleColumns('\x1b[1m\x1b[31mok\x1b[0m'), 2);
    });

    test('SGR with multiple params', () {
      // \x1b[38;5;120m → 0 visible; "x" → 1; \x1b[0m → 0
      expect(visibleColumns('\x1b[38;5;120mx\x1b[0m'), 1);
    });

    test('text without escapes is just length', () {
      expect(visibleColumns('the quick brown fox'), 19);
    });

    test('orphan ESC with no [ is consumed plus one trailing byte', () {
      // We don't crash; behaviour matches Screen._clipToVisibleCols's
      // tolerance for stray escapes.
      expect(visibleColumns('\x1b\x07hello'), 5);
    });

    test('unterminated CSI still consumes until end', () {
      // No final byte; just consume the rest. visible should be 0.
      expect(visibleColumns('\x1b[31'), 0);
    });
  });
}
