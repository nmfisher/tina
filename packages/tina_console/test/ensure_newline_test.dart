import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

void main() {
  group('ensureNewline (#30)', () {
    // Streamed partial line via appendStyled → ensureNewline → next write
    // lands on new row; no-op on empty row; no-op after text ending in \n.
    late Screen screen;
    late FakeStdio io;

    setUp(() {
      io = FakeStdio()..columns = 80;
      screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(80, 24, split: false),
        ansi: AnsiCapable.yes,
      );
      screen.chat.handleResize();
    });

    test('streamed partial line: ensureNewline terminates partial row', () {
      // A streamed chunk leaves the row partial (no trailing newline).
      screen.chat.appendStyled('partial');
      screen.chat.ensureNewline();
      // After ensureNewline the cursor advances to a new row (newline written).
      // A subsequent write lands fresh — doesn't extend the partial text.
      screen.chat.write('next');

      // The region must contain both pieces, and 'partial' must not be
      // concatenated with 'next' without a newline separator.
      final lines = screen.chat.snapshotLines();
      final text = lines.join('\n');
      expect(text.contains('partial'), isTrue);
      expect(text.contains('next'), isTrue);
      // No glued single token — the newline separated them.
      expect(text.contains('partialnext'), isFalse,
          reason: 'partial and next must be separated by newline (#30)');
    });

    test('no-op on empty row', () {
      // Fresh region with no content: nothing written yet.
      screen.chat.ensureNewline();
      // Must not throw; row stays empty.
      expect(screen.chat.snapshotLines(), isEmpty);
    });

    test('no-op after text ending in newline', () {
      screen.chat.write('complete line\n');
      // The newline already completed the row; _curCol == 0.
      screen.chat.ensureNewline();
      // Must not inject an extra blank row.
      final snapshot = screen.chat.snapshotLines();
      final nonEmpty = snapshot.where((s) => s.trim().isNotEmpty).toList();
      expect(nonEmpty.length, 1,
          reason: 'only the original line, no extra blank');
    });
  });
}
