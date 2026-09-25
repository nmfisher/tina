import 'package:tina/session_commands/startup_session_picker_overlay.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';
import '../helpers/overlay_fixtures.dart';
import 'startup_picker_fixture.dart';

void main() {
  final now = DateTime(2026, 09, 23, 12);

  SessionMeta meta(
    String id,
    String title, {
    String? description,
    DateTime? updated,
  }) => SessionMeta(
    id: id,
    title: title,
    createdAt: now,
    updatedAt: updated ?? now,
    messageCount: 2,
    conversationCount: 1,
    description: description,
  );

  /// Runs the picker over a [FakeStdio]-backed screen, feeding canned events.
  /// Because the picker hides (erases) its overlay on exit, paint assertions
  /// cannot read [FakeStdio.written] afterwards: each snapshot is taken just
  /// before an event is handed over, i.e. while the overlay is still live.
  /// All snapshots are replayed into one [VirtualTerminal] in order, so the
  /// VT ends in the last pre-exit painted state. Returns (picked, vt, io).
  Future<(SessionChoice?, VirtualTerminal, FakeStdio)> runPicker(
    List<SessionChoice> choices,
    List<InputEvent> events,
  ) async {
    final io = FakeStdio()..hasTerminalValue = false;
    final screen = Screen(io: io, layout: ScreenLayout.fromSize(80, 24));
    final canned = CannedEvents()..events = events;
    final frames = <String>[];
    final picked = await pickStartupSessionOverlay(
      choices: choices,
      readEvent: () async {
        frames.add(io.written.toString());
        return canned.readEvent();
      },
      screen: screen,
      geometry: const FixedGeometry(80, 24),
    );
    final vt = VirtualTerminal(width: 80, height: 24);
    for (final frame in frames) {
      vt.feed(frame);
    }
    return (picked, vt, io);
  }

  /// Every row of the last painted frame, newline-joined.
  String paintedRows(VirtualTerminal vt) =>
      List.generate(24, vt.rowText).join('\n');

  group('pickStartupSessionOverlay', () {
    test('empty list cancels immediately without reading input', () async {
      var reads = 0;
      final picked = await pickStartupSessionOverlay(
        choices: const [],
        readEvent: () async {
          reads++;
          throw StateError('must not read');
        },
        screen: fakeScreen(),
        geometry: const FixedGeometry(80, 24),
      );
      expect(picked, isNull);
      expect(reads, 0);
    });

    test('enter picks the newest session by default', () async {
      final (picked, _, _) = await runPicker(
        [
          choice('a', 'Alpha', updated: now),
          choice('b', 'Beta', updated: now.add(const Duration(minutes: 1))),
        ],
        [ControlKey(ControlCode.enter)],
      );
      expect(picked, isNotNull);
      expect(picked!.meta.id, 'b');
    });

    test('arrow navigation moves focus', () async {
      final (picked, _, _) = await runPicker(
        [
          choice('a', 'Alpha', updated: now),
          choice('b', 'Beta', updated: now.add(const Duration(minutes: 1))),
        ],
        [
          ArrowKey(ArrowDirection.down), // Beta (newest) down to Alpha
          ControlKey(ControlCode.enter),
        ],
      );
      expect(picked!.meta.id, 'a');
    });

    test('esc cancels', () async {
      final (picked, _, _) = await runPicker(
        [choice('a', 'Alpha')],
        [EscapeKey()],
      );
      expect(picked, isNull);
    });

    test('ctrl-c cancels before later events can select', () async {
      final (picked, _, _) = await runPicker(
        [choice('a', 'Alpha')],
        [ControlKey(ControlCode.ctrlC), ControlKey(ControlCode.enter)],
      );
      expect(picked, isNull);
    });

    test('typing filters by title and enter picks the match', () async {
      final (picked, vt, _) = await runPicker(
        [choice('a', 'Alpha session'), choice('b', 'Beta thing')],
        [CharInput('bet'), ControlKey(ControlCode.enter)],
      );
      expect(picked!.meta.id, 'b');
      expect(paintedRows(vt), contains('filter: bet'));
    });

    test('filter is case-insensitive', () async {
      final (picked, _, _) = await runPicker(
        [choice('a', 'Alpha session'), choice('b', 'Beta thing')],
        [CharInput('BETA'), ControlKey(ControlCode.enter)],
      );
      expect(picked!.meta.id, 'b');
    });

    test('filter matches description and id too', () async {
      final byDescription = await runPicker(
        [
          choice('a', 'Alpha', description: 'refactor the parser'),
          choice('b', 'Beta', description: 'unrelated'),
        ],
        [CharInput('pars'), ControlKey(ControlCode.enter)],
      );
      expect(byDescription.$1!.meta.id, 'a');

      final byId = await runPicker(
        [choice('sess-alpha', 'Alpha'), choice('sess-beta', 'Beta')],
        [CharInput('-beta'), ControlKey(ControlCode.enter)],
      );
      expect(byId.$1!.meta.id, 'sess-beta');
    });

    test('tab clears the filter', () async {
      final (picked, vt, _) = await runPicker(
        [
          choice(
            'a',
            'Alpha',
            updated: now.subtract(const Duration(minutes: 1)),
          ),
          choice('b', 'Beta'),
        ],
        [
          CharInput('zzz'),
          ControlKey(ControlCode.tab),
          ControlKey(ControlCode.enter),
        ],
      );
      expect(picked!.meta.id, 'b'); // cleared → newest again
      expect(paintedRows(vt), contains('type to filter'));
    });

    test('backspace edits the filter character by character', () async {
      final (picked, _, _) = await runPicker(
        [choice('a', 'Alpha'), choice('b', 'Beta')],
        [
          CharInput('alx'), // matches nothing
          EditingKey(EditingAction.killToStart), // (ignored key) keep filter
          ControlKey(ControlCode.backspace), // -> "al"
          ControlKey(ControlCode.backspace), // -> "a" → Alpha
          ControlKey(ControlCode.enter),
        ],
      );
      expect(picked!.meta.id, 'a');
    });

    test(
      'a filter with no matches paints the empty state, enter is a no-op',
      () async {
        final state = await runPicker(
          [choice('a', 'Alpha')],
          [
            CharInput('zzz'),
            ControlKey(ControlCode.enter), // no match → must not return
            ControlKey(ControlCode.tab), // clear
            ControlKey(ControlCode.enter),
          ],
        );
        expect(state.$1!.meta.id, 'a');
      },
    );

    test('pageDown/pageUp jump by a page', () async {
      final choices = [
        for (var i = 0; i < 30; i++)
          choice(
            's${i.toString().padLeft(2, '0')}',
            'Session $i',
            updated: now.add(Duration(minutes: i)),
          ),
      ];
      final (pgdn, _, _) = await runPicker(choices, [
        ArrowKey(ArrowDirection.pageDown),
        ControlKey(ControlCode.enter),
      ]);
      // Box height at 24 rows: (30 + 5).clamp(8, 20) → 20 → 15 entry rows.
      expect(pgdn!.meta.id, 's14');

      final (pgup, _, _) = await runPicker(choices, [
        ArrowKey(ArrowDirection.pageDown),
        ArrowKey(ArrowDirection.pageUp),
        ControlKey(ControlCode.enter),
      ]);
      // Back to focus 0 = the newest session (s14 would mean PgUp was a
      // no-op or moved only one row).
      expect(pgup!.meta.id, 's29');
    });

    test('paints title, description and time for the focused row', () async {
      final (_, vt, _) = await runPicker(
        [
          choice(
            'a',
            'Alpha',
            description: 'first session',
            when: '2026-09-23 12:00',
            updated: now.add(const Duration(minutes: 1)),
          ),
          choice('b', 'Beta', description: 'second session'),
        ],
        [EscapeKey()],
      );
      final text = paintedRows(vt);
      expect(text, contains('Beta — second session'));
      expect(text, contains('first session'));
      expect(text, contains('2026-09-23 12:00'));
      expect(text, contains('Resume session'));
    });

    test('saved metadata cannot inject terminal escapes', () async {
      final (_, vt, _) = await runPicker(
        [choice('a', 'bad\x1b[2Jtitle')],
        [EscapeKey()],
      );
      final text = paintedRows(vt);
      expect(text, isNot(contains('\x1b')));
      expect(text, contains('bad [2Jtitle'));
    });

    test(
      'SessionChoice.fromMeta strips controls and formats the time',
      () async {
        final c = SessionChoice.fromMeta(
          meta('x', 't\x1b[31mitle', description: 'd\tesc'),
        );
        expect(c.title, 't [31mitle');
        expect(c.description, 'd esc');
        expect(c.when, '2026-09-23 12:00');
      },
    );
  });
}
