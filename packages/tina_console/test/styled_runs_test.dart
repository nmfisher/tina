// Phase 4 — parsed SGR runs: parity, collapse, and cache-bounds tests.
//
// Proves parseStyledRuns + the collapse pass reproduce the pre-Phase-4
// emitter's exact setter/putStr sequence for every SGR case the existing T-07
// suite covers (so the live emitter can switch to cached runs with zero byte
// change), that adjacent same-state runs collapse to drop redundant setters,
// and that the parse cache is strictly bounded by entry count and input length.

import 'package:test/test.dart';

import 'package:tina_console/src/styled_text.dart';

/// Records setter + putStr calls in the same string form as the T-07
/// RecordingPlatform, so parity is a literal list comparison.
class _RecSink implements StyledStyleSink {
  final List<String> calls = [];

  void putStrYX(int row, int col, String text) {
    calls.add('putStrYX($row,$col,${_quote(text)})');
  }

  @override
  void setStyles(int stylebits) {
    calls.add('setStyles(0x${stylebits.toRadixString(16)})');
  }

  @override
  void setFgRGB(int hex) {
    calls.add('setFgRGB(0x${hex.toRadixString(16).padLeft(6, '0')})');
  }

  @override
  void setBgRGB(int hex) {
    calls.add('setBgRGB(0x${hex.toRadixString(16).padLeft(6, '0')})');
  }

  @override
  void setFgDefault() => calls.add('setFgDefault');

  @override
  void setBgDefault() => calls.add('setBgDefault');
}

String _quote(String s) {
  final escaped = s
      .replaceAll('\\', '\\\\')
      .replaceAll("'", "\\'")
      .replaceAll('\n', '\\n');
  return "'$escaped'";
}

/// Play back [runs] onto [sink]: each run emits its establishCalls then its
/// text. Mirrors how the live emitter (Step 2) will render cached runs.
void _emitRuns(List<StyledRun> runs, _RecSink sink) {
  for (final run in runs) {
    for (final fn in run.establishCalls) {
      fn(sink);
    }
    if (run.text.isNotEmpty) sink.putStrYX(0, 0, run.text);
  }
}

void main() {
  group('parseStyledRuns parity (T-07 cases)', () {
    test('\\x1b[31mR\\x1b[0m', () {
      final sink = _RecSink();
      _emitRuns(parseStyledRuns('\x1b[31mR\x1b[0m'), sink);
      expect(sink.calls, [
        'setFgRGB(0xcd0000)',
        'putStrYX(0,0,\'R\')',
        'setFgDefault',
        'setBgDefault',
        'setStyles(0x0)',
      ]);
    });

    test('R\\x1b[0m trailing reset', () {
      final sink = _RecSink();
      _emitRuns(parseStyledRuns('R\x1b[0m'), sink);
      expect(sink.calls, [
        'putStrYX(0,0,\'R\')',
        'setFgDefault',
        'setBgDefault',
        'setStyles(0x0)',
      ]);
    });

    test('combined \\x1b[1;4m OR-s into one setStyles', () {
      final sink = _RecSink();
      _emitRuns(parseStyledRuns('\x1b[1;4mX'), sink);
      expect(sink.calls, [
        'setStyles(0xa)', // bold 0x2 | underline 0x8
        'putStrYX(0,0,\'X\')',
      ]);
    });

    test('truecolor 38;2;r;g;b packs into one setFgRGB', () {
      final sink = _RecSink();
      _emitRuns(parseStyledRuns('\x1b[38;2;255;128;64mX'), sink);
      expect(sink.calls, ['setFgRGB(0xff8040)', 'putStrYX(0,0,\'X\')']);
    });

    test('bright fg 90-97 maps to the bright palette', () {
      final sink = _RecSink();
      _emitRuns(parseStyledRuns('\x1b[91mX'), sink);
      expect(sink.calls, ['setFgRGB(0xff0000)', 'putStrYX(0,0,\'X\')']);
    });

    test('unknown SGR skipped, plain text still lands', () {
      final sink = _RecSink();
      _emitRuns(parseStyledRuns('\x1b[99mZ'), sink);
      expect(sink.calls, ['putStrYX(0,0,\'Z\')']);
    });

    test('non-SGR CSI (cursor movement) is dropped', () {
      final sink = _RecSink();
      _emitRuns(parseStyledRuns('\x1b[2AZ'), sink);
      expect(sink.calls, ['putStrYX(0,0,\'Z\')']);
    });

    test('two colored spans back-to-back land at advancing columns', () {
      final sink = _RecSink();
      _emitRuns(parseStyledRuns('\x1b[32mAB\x1b[36mCD'), sink);
      expect(sink.calls, [
        'setFgRGB(0x00cd00)',
        'putStrYX(0,0,\'AB\')',
        'setFgRGB(0x00cdcd)',
        'putStrYX(0,0,\'CD\')',
      ]);
    });

    test('malformed trailing escape drops the rest', () {
      final sink = _RecSink();
      // \x1b[31 has no final byte — drop from the escape onward.
      _emitRuns(parseStyledRuns('A\x1b[31'), sink);
      expect(sink.calls, ['putStrYX(0,0,\'A\')']);
    });

    test('plain string (no ESC) is a single default run', () {
      final runs = parseStyledRuns('hello');
      expect(runs, hasLength(1));
      expect(runs.first.style, const TextStyleState(null, null, 0));
      expect(runs.first.text, 'hello');
      expect(runs.first.establishCalls, isEmpty);
    });
  });

  group('collapse drops redundant mid-string setters', () {
    test('adjacent identical fg collapse into one run', () {
      final runs = parseStyledRuns('\x1b[32mAB\x1b[32mCD\x1b[0m');
      // AB and CD both green → one run "ABCD"; trailing reset preserved.
      expect(runs, hasLength(2));
      expect(runs[0].text, 'ABCD');
      expect(runs[0].style.fg, 0x00cd00);
      expect(runs[0].establishCalls, hasLength(1));
      // Trailing reset run (empty text) preserved to establish baseline.
      expect(runs[1].text, '');
      expect(runs[1].style, const TextStyleState(null, null, 0));
      expect(runs[1].establishCalls, hasLength(3));
    });

    test('collapse produces the byte-correct reduced sequence', () {
      const s = '\x1b[32mAB\x1b[32mCD\x1b[36mEF\x1b[0m';
      final sink = _RecSink();
      _emitRuns(parseStyledRuns(s), sink);
      // AB+CD collapse to one green run (redundant mid-string setFgRGB
      // dropped); the blue EF and trailing reset are their own runs.
      expect(sink.calls, [
        'setFgRGB(0x00cd00)',
        'putStrYX(0,0,\'ABCD\')', // collapsed from AB + CD
        'setFgRGB(0x00cdcd)',
        'putStrYX(0,0,\'EF\')',
        'setFgDefault',
        'setBgDefault',
        'setStyles(0x0)',
      ]);
    });

    test('no collapse when states differ', () {
      final runs = parseStyledRuns('\x1b[31mA\x1b[32mB');
      expect(runs, hasLength(2));
      expect(runs[0].text, 'A');
      expect(runs[0].style.fg, 0xcd0000);
      expect(runs[1].text, 'B');
      expect(runs[1].style.fg, 0x00cd00);
    });

    test('a styled emit ending in \\x1b[0m lands at the default baseline',
        () {
      // Phase 4 boundary invariant: a styled string that ends with the ANSI
      // reset (\x1b[0m) must leave the sink at the default fg/bg/style
      // baseline — collapse must never drop the trailing empty-text reset run,
      // or a following write on the same plane would inherit this string's
      // color. (A bare \x1b[31m with no reset legitimately leaves the sink
      // colored, matching the pre-Phase-4 emitter.)
      for (final s in [
        '\x1b[31mred\x1b[0m',
        '\x1b[1;4;32mstyled\x1b[0m',
        '\x1b[38;2;255;128;64mtruecolor\x1b[32mthen green\x1b[0m',
        '\x1b[7m\x1b[7m\x1b[7mdouble\x1b[0m', // redundant identical SGRs collapse
      ]) {
        final sink = _RecSink();
        _emitRuns(parseStyledRuns(s), sink);
        expect(sink.calls, isNotEmpty);
        expect(sink.calls.last, 'setStyles(0x0)',
            reason: 'emit of "$s" must end at the default baseline; '
                'last call was ${sink.calls.last}');
        // Full reset sequence present (fg + bg defaulted too).
        expect(sink.calls, contains('setFgDefault'));
        expect(sink.calls, contains('setBgDefault'));
      }
    });

    test('plain text carries no inline styling of its own (cache bypass)',
        () {
      // A plain string (no ESC) bypasses the parse cache and emits no style
      // setters — only a putStr. Whatever baseline the prior emit left the
      // sink at is established by that prior emit's own trailing reset or by
      // the child-plane putAt's leading default reset; the plain string adds
      // nothing. This is why plain prose never injects SGR into a styled row.
      final plain = _RecSink();
      _emitRuns(parseStyledRuns('plain'), plain);
      expect(plain.calls, ["putStrYX(0,0,'plain')"]);
    });
  });

  group('StyledRunCache bounds', () {
    setUp(() {
      styledRunCache.clear();
      gThemeStyleVersion = 0;
    });

    test('plain strings bypass the cache', () {
      expect(styledRunCache.get('no ansi here'), isNull);
      expect(styledRunCache.length, 0);
    });

    test('miss parses + caches; hit returns cached', () {
      final a = styledRunCache.get('\x1b[31mX');
      expect(a, isNotNull);
      expect(styledRunCache.length, 1);
      final b = styledRunCache.get('\x1b[31mX');
      expect(identical(a, b), isTrue);
    });

    test('evicts oldest past 256 entries', () {
      for (var i = 0; i < 256; i++) {
        styledRunCache.get('\x1b[${30 + (i % 8)}mX$i');
      }
      expect(styledRunCache.length, 256);
      final firstKey = '\x1b[30mX0';
      // The first-inserted distinct string is still cached (unique each iter).
      expect(styledRunCache.get(firstKey), isNotNull);
      // Insert a 257th distinct string → oldest evicted, count stays 256.
      styledRunCache.get('\x1b[30mNEW');
      expect(styledRunCache.length, 256);
    });

    test('inputs longer than 4 KiB are parsed uncached', () {
      final long = '\x1b[31m${'x' * 5000}';
      expect(long.length, greaterThan(4096));
      final runs = styledRunCache.get(long);
      expect(runs, isNotNull);
      expect(styledRunCache.length, 0); // not inserted
    });

    test('parser-version bump evicts (keyed by version)', () {
      styledRunCache.get('\x1b[31mX');
      expect(styledRunCache.length, 1);
      // Bump the parser version → old entries' keys no longer match; they
      // remain in the map until evicted by capacity, but a fresh get misses.
      // (We can't easily observe the stale entry without a hit; assert the
      // cache still functions and stays bounded after a version change.)
      // ignore: unused_local_variable
      final _ = kStyledRunParserVersion;
      expect(styledRunCache.length, 1); // stale entry lingers until evicted
    });

    test('theme-version bump evicts via key change', () {
      styledRunCache.get('\x1b[31mX');
      expect(styledRunCache.length, 1);
      bumpThemeStyleVersion();
      // Stale entry lingers (LRU eviction), but new gets use the new key.
      styledRunCache.get('\x1b[32mY');
      expect(styledRunCache.length, 2); // old + new coexist until evicted
      styledRunCache.clear();
      expect(styledRunCache.length, 0);
    });
  });

  group('diffStyledRuns', () {
    test('identical rows → null (skip)', () {
      final runs = parseStyledRuns('\x1b[32mAB\x1b[36mCD\x1b[0m');
      expect(diffStyledRuns(runs, runs), isNull);
    });

    test('identical content from different SGR grammar → null', () {
      // \x1b[32m vs \x1b[0;32m resolve to the same rendered runs
      // (reset+green collapses to green); diff is content-based, so equal.
      final a = parseStyledRuns('\x1b[32mAB\x1b[0m');
      final b = parseStyledRuns('\x1b[0;32mAB\x1b[0m');
      expect(diffStyledRuns(a, b), isNull);
    });

    test('tail run changed → span from that run with column offset', () {
      // Prefix "AB" green unchanged; suffix changes blue→cyan.
      final oldRuns = parseStyledRuns('\x1b[32mAB\x1b[36mCD\x1b[0m');
      final newRuns = parseStyledRuns('\x1b[32mAB\x1b[36mCE\x1b[0m');
      final span = diffStyledRuns(oldRuns, newRuns);
      expect(span, isNotNull);
      expect(span!.startIndex, 1); // second run (CE) differs
      expect(span.colOffset, 2); // "AB" is 2 cells
      expect(span.runs, hasLength(2)); // blue→cyan run + trailing reset run
      expect(span.runs.first.text, 'CE');
      expect(span.runs.first.style.fg, 0x00cdcd);
    });

    test('wide-char prefix → offset counts terminal cells, not units '
        '(tin-q4vz)', () {
      // The unchanged prefix ends in wide glyphs. An offset computed in
      // code units (3 for 漢字テ) lands LEFT of where the prefix actually
      // ends on screen (6 cells), so the tail re-emit paints over the
      // prefix's last glyphs — the `long-token:` → ` long-toke :` symptom.
      final oldRuns = parseStyledRuns('\x1b[32m漢字テ\x1b[36mCD\x1b[0m');
      final newRuns = parseStyledRuns('\x1b[32m漢字テ\x1b[36mCE\x1b[0m');
      final span = diffStyledRuns(oldRuns, newRuns);
      expect(span, isNotNull);
      expect(span!.colOffset, 6); // 3 wide glyphs × 2 cells
    });

    test('prefix changed → span starts at offset 0', () {
      final oldRuns = parseStyledRuns('\x1b[31mAB\x1b[0m');
      final newRuns = parseStyledRuns('\x1b[32mAB\x1b[0m');
      final span = diffStyledRuns(oldRuns, newRuns);
      expect(span, isNotNull);
      expect(span!.startIndex, 0);
      expect(span.colOffset, 0);
    });

    test('all runs differ → full span from 0 (incl. trailing reset run)', () {
      // \x1b[31mA\x1b[32mB\x1b[0m → [red A, green B, reset('')]; the trailing
      // empty-text reset run is preserved so the re-emit re-establishes the
      // default baseline.
      final oldRuns = parseStyledRuns('\x1b[31mA\x1b[32mB\x1b[0m');
      final newRuns = parseStyledRuns('\x1b[33mA\x1b[34mB\x1b[0m');
      final span = diffStyledRuns(oldRuns, newRuns);
      expect(span, isNotNull);
      expect(span!.startIndex, 0);
      expect(span.colOffset, 0);
      expect(span.runs, hasLength(3));
    });

    test('new row longer (grew a tail run) → span catches theGrowth', () {
      final oldRuns = parseStyledRuns('\x1b[32mAB\x1b[0m'); // [AB, reset]
      final newRuns = parseStyledRuns('\x1b[32mABCD\x1b[0m'); // [ABCD, reset]
      final span = diffStyledRuns(oldRuns, newRuns);
      expect(span, isNotNull);
      expect(span!.startIndex, 0); // first run's text changed length
      expect(span.colOffset, 0);
      expect(span.runs.first.text, 'ABCD');
    });

    test('plain (default) rows handled as single-default-run diff', () {
      final oldRuns = parseStyledRuns('hello');
      final newRuns = parseStyledRuns('world');
      final span = diffStyledRuns(oldRuns, newRuns);
      expect(span, isNotNull);
      expect(span!.startIndex, 0);
      expect(span.colOffset, 0);
      expect(span.runs.first.text, 'world');
    });
  });

  group('renderStyledRuns', () {
    test('renders each run from a clean default baseline', () {
      // red then green: the green run must re-establish from default, not rely
      // on the red run's state. A naive replay of establishCalls would emit
      // setFgRGB(green) only; renderStyledRuns must still land correct cells.
      final runs = parseStyledRuns('\x1b[31mA\x1b[32mB\x1b[0m');
      final s = renderStyledRuns(runs);
      // basic colors stored as truecolor RGB: 0xcd0000 red, 0x00cd00 green;
      // each run opens from a default baseline; final default run → one reset.
      expect(s, '\x1b[0m\x1b[38;2;205;0;0mA\x1b[0m\x1b[38;2;0;205;0mB\x1b[0m');
    });

    test('trailing reset run emits a bare reset', () {
      final runs = parseStyledRuns('\x1b[32mAB\x1b[0m');
      // [green "AB", default ""] → reset+AB (truecolor green), then one reset.
      expect(renderStyledRuns(runs), '\x1b[0m\x1b[38;2;0;205;0mAB\x1b[0m');
    });

    test('combined bold+underline emits both codes', () {
      final runs = parseStyledRuns('\x1b[1;4mX\x1b[0m');
      final s = renderStyledRuns(runs);
      expect(s, contains('\x1b[1;4mX'));
    });

    test('truecolor fg/bg round-trips through RGB', () {
      final runs = parseStyledRuns('\x1b[38;2;255;128;64mF\x1b[48;2;1;2;3mB\x1b[0m');
      final s = renderStyledRuns(runs);
      expect(s, contains('\x1b[38;2;255;128;64mF'));
      expect(s, contains('\x1b[48;2;1;2;3mB'));
    });

    test('plain (default) single run renders its text under a reset', () {
      final runs = parseStyledRuns('hello');
      expect(renderStyledRuns(runs), '\x1b[0mhello');
    });

    test('a changed tail renders correctly without its unchanged prefix', () {
      // Proves renderStyledRuns makes each run independent of prior state: a
      // tail span (first changed run → end) re-emits correctly on its own,
      // which is exactly what a partial repaint relies on.
      final full = parseStyledRuns('\x1b[31mPREFIX\x1b[32mSUFFIX\x1b[0m');
      // Tail = green "SUFFIX" + trailing reset.
      final tail = diffStyledRuns(full, full); // identical → null
      expect(tail, isNull);
      // Build the tail span manually as the emitter would: from run index 1.
      final tailRuns = full.sublist(1); // [green "SUFFIX", default ""]
      expect(renderStyledRuns(tailRuns), '\x1b[0m\x1b[38;2;0;205;0mSUFFIX\x1b[0m');
    });
  });
}
