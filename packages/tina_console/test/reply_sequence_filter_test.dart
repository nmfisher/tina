import 'package:test/test.dart';
import 'package:tina_console/src/backend/reply_sequence_filter.dart';

/// Feed [keys] (notcurses key ids) through [filter] at burst rate — the
/// inter-event gap the reply spike measured inside a reply bundle (≤3 ms);
/// 100 µs models it. Returns the ids the filter let through.
List<int> feedBurst(ReplySequenceFilter filter, List<int> keys) {
  final out = <int>[];
  var t = 0;
  for (final k in keys) {
    out.addAll(filter.add(k, t));
    t += 100; // µs
  }
  return out;
}

/// ASCII/UTF-8 string → key ids, for writing replies readably.
List<int> ids(String s) => s.codeUnits;

void main() {
  group('ReplySequenceFilter (tin-v6tq prototype)', () {
    test('drops every reply shape notcurses itself queries at init', () {
      // The exact bundle tool/tmux_inject_replies.sh replays; see that script
      // for where each one comes from. All arrive as ESC + printable bytes.
      final shapes = <String, List<int>>{
        'OSC 4 palette entry': ids('\x1b]4;1;rgb:8000/0000/0000\x1b\\'),
        'OSC 4 palette entry (BEL terminator)': ids('\x1b]4;16;rgb:0000/5f5f/0000\x07'),
        'OSC 10 foreground': ids('\x1b]10;rgb:ffff/ffff/ffff\x1b\\'),
        'OSC 11 background': ids('\x1b]11;rgb:0000/0000/0000\x1b\\'),
        'DA1': ids('\x1b[?62;c'),
        'DA1 (tmux form)': ids('\x1b[?1;2;4c'),
        'CPR': ids('\x1b[1;1R'),
        'DECRPM 2026': ids('\x1b[?2026;1\$y'),
        'DECRPM 1016': ids('\x1b[?1016;1\$y'),
        'XTMODKEYS': ids('\x1b[?1;3;256S'),
        'kitty keyboard flags': ids('\x1b[?1u'),
        'kitty graphics (APC)': ids('\x1b_Gi=1;OK\x1b\\'),
        'XTGETTCAP (DCS)': ids('\x1bP1+r544e;787465726d2d323536636f6c6f72\x1b\\'),
        'XTWINOPS 18': ids('\x1b[8;40;120t'),
      };
      for (final e in shapes.entries) {
        final f = ReplySequenceFilter();
        final out = feedBurst(f, e.value);
        expect(out, isEmpty, reason: '${e.key} should be swallowed, got $out');
        expect(f.flush(), isEmpty, reason: '${e.key} left state held open');
      }
    });

    test('swallows a full 256-entry OSC 4 palette run (the 4.5 KB repro)', () {
      final filter = ReplySequenceFilter();
      final cube = [0x0000, 0x5f5f, 0x8787, 0xafaf, 0xd7d7, 0xffff];
      final burst = StringBuffer();
      for (var r = 0; r < 6; r++) {
        for (var g = 0; g < 6; g++) {
          for (var b = 0; b < 6; b++) {
            burst.write('\x1b]4;${16 + r * 36 + g * 6 + b};'
                'rgb:${cube[r].toRadixString(16).padLeft(4, '0')}/'
                '${cube[g].toRadixString(16).padLeft(4, '0')}/'
                '${cube[b].toRadixString(16).padLeft(4, '0')}\x1b\\');
          }
        }
      }
      final out = feedBurst(filter, ids(burst.toString()));
      expect(out, isEmpty);
    });

    test('passes a genuine paste through untouched (no ESC events)', () {
      // The spike measured a real 5400-byte bracketed paste as 5400 printable
      // events with zero ESC — notcurses consumes the 200~/201~ markers.
      final filter = ReplySequenceFilter();
      final paste = ids('The quick brown fox jumps over the lazy dog. ' * 20);
      final out = feedBurst(filter, paste);
      expect(out, paste);
    });

    test('passes typing through, including characters replies also use', () {
      final filter = ReplySequenceFilter();
      // 'a', 'b', 'c', '4', ';' all occur inside OSC 4 replies; typed with
      // human gaps (60 ms) they must not be filtered.
      final typed = [0x61, 0x62, 0x63, 0x34, 0x3b, 0x3a, 0x2f, 0x72, 0x67, 0x62];
      final out = <int>[];
      var t = 0;
      for (final k in typed) {
        out.addAll(filter.add(k, t));
        t += 60000; // 60 ms
      }
      expect(out, typed);
    });

    test('delivers a lone ESC (cancel) once the introducer window passes', () {
      final filter = ReplySequenceFilter();
      expect(filter.add(0x1b, 0), isEmpty, reason: 'held pending an introducer');
      // Next key arrives 200 ms later — far past introducerWindow.
      final out = filter.add(0x71, 200000);
      expect(out, [0x1b, 0x71], reason: 'ESC was a real cancel, then a typed q');
    });

    test('releases a held ESC on flush', () {
      final filter = ReplySequenceFilter();
      expect(filter.add(0x1b, 0), isEmpty);
      expect(filter.flush(), [0x1b]);
    });

    test('delivers a slowly typed ESC then ]', () {
      final filter = ReplySequenceFilter();
      expect(filter.add(0x1b, 0), isEmpty);
      final out = filter.add(0x5d, 80000); // 80 ms later — human speed
      expect(out, [0x1b, 0x5d]);
    });

    test('aborts the swallow when a real control key interrupts a reply', () {
      final filter = ReplySequenceFilter();
      // ESC ] then an Enter: not a reply shape, and Enter must never be eaten.
      final out = <int>[
        ...filter.add(0x1b, 0),
        ...filter.add(0x5d, 100),
        ...filter.add(0x0d, 200), // Enter
      ];
      expect(out, [0x0d]);
    });

    test('back-to-back replies with no gap between them', () {
      final filter = ReplySequenceFilter();
      final out = feedBurst(
        filter,
        [...ids('\x1b]10;rgb:ffff/ffff/ffff\x1b\\'), ...ids('\x1b[?62;c')],
      );
      expect(out, isEmpty);
    });

    // The two below are regressions: an early version only closed a reply on
    // BEL/ST, so the CSI replies (which end in a final byte such as the `t`
    // of ESC[8;40;120t) left the filter in its swallow state and it ate
    // everything that followed — the next paste included.

    test('a CSI-final reply closes the state machine', () {
      final filter = ReplySequenceFilter();
      final out = feedBurst(filter, ids('\x1b[8;40;120t'));
      expect(out, isEmpty);
      // The very next event must pass through, not be swallowed.
      expect(filter.add(0x71, 50000), [0x71], reason: 'filter stayed open');
    });

    test('the whole bundle, then a genuine paste, then typing all behave', () {
      final filter = ReplySequenceFilter();
      final bundle = [
        ...ids('\x1b[?62;c'),
        ...ids('\x1b[1;1R'),
        ...ids('\x1b]4;1;rgb:8000/0000/0000\x1b\\'),
        ...ids('\x1b]10;rgb:ffff/ffff/ffff\x1b\\'),
        ...ids('\x1b?2026;1\$y'.replaceFirst('?', '[?')),
        ...ids('\x1b[?1;3;256S'),
        ...ids('\x1b_Gi=1;OK\x1b\\'),
        ...ids('\x1bP1+r524742;31\x1b\\'),
        ...ids('\x1b[4;1;1;80;120t'),
        ...ids('\x1b[8;40;120t'),
      ];
      expect(feedBurst(filter, bundle), isEmpty,
          reason: 'the whole reply bundle is swallowed');

      final paste = ids('The quick brown fox jumps over the lazy dog. ' * 20);
      expect(feedBurst(filter, paste), paste,
          reason: 'a following genuine paste must pass verbatim');

      final typed = <int>[];
      var t = 1000000;
      for (final k in [0x68, 0x65, 0x6c, 0x6c, 0x6f]) {
        typed.addAll(filter.add(k, t));
        t += 60000;
      }
      expect(typed, [0x68, 0x65, 0x6c, 0x6c, 0x6f],
          reason: 'typing after the burst must pass');
    });
  });
}
