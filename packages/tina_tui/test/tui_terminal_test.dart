// The TUI's Terminal: writes land in the conversation, asks resolve from
// a queued answer — headless, no terminal anywhere.
//
// Run: dart test
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_tui/tina_tui.dart';

void main() {
  group('TuiTerminal: the text sink', () {
    test('writeln appends a conversation line the host can read', () {
      final tui = TuiTerminal();
      tui.writeln('mode: read-only');
      tui.writeln();
      expect(tui.lines, [
        const ConversationLine('mode: read-only'),
        const ConversationLine(''),
      ]);
    });

    test('a user-typed line can be recorded beside written lines', () {
      final tui = TuiTerminal();
      tui.writeln('hello');
      tui.lines; // the host reads it; nothing changes
      expect(tui.lines.single.fromUser, isFalse);
    });
  });

  group('TuiTerminal: the ask seam', () {
    test('a queued answer is returned to the ask, trimmed path intact',
        () async {
      final tui = TuiTerminal()..answers.add('read-only');
      final got = await tui.ask('mode?');
      expect(got, 'read-only');
      // The prompt itself is part of the conversation.
      expect(tui.lines.single.text, 'mode?');
    });

    test('an ask with no queued answer waits for submitAnswer', () async {
      final tui = TuiTerminal();
      final waiting = tui.ask('continue?');
      var resolved = false;
      unawaited(waiting.then((_) => resolved = true));
      await Future<void>.delayed(Duration.zero);
      expect(resolved, isFalse, reason: 'nothing is invented while empty');
      tui.submitAnswer('yes');
      expect(await waiting, 'yes');
    });

    test('asks resolve in order, oldest first', () async {
      final tui = TuiTerminal();
      final first = tui.ask('first?');
      final second = tui.ask('second?');
      tui.submitAnswer('one');
      tui.submitAnswer('two');
      expect(await first, 'one');
      expect(await second, 'two');
    });

    test('closeInput resolves every pending ask with the empty answer',
        () async {
      final tui = TuiTerminal();
      final first = tui.ask('first?');
      final second = tui.ask('second?');
      tui.closeInput();
      expect(await first, '');
      expect(await second, '');
    });
  });
}
