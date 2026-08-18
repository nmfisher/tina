import 'dart:async';

import 'package:test/test.dart';

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/notcurses_backend.dart';
import 'package:dart_notcurses/dart_notcurses.dart' as nc;

import 'stdio_fake.dart';

/// Records every call to its [NotcursesPlatform] surface. The fake
/// substitutes for libnotcurses so we can exercise [NotcursesBackend]'s
/// state machine — stop-guard correctness, cursor advancement, palette
/// gating — without needing a live notcurses runtime.
class RecordingPlatform implements NotcursesPlatform {
  final List<String> calls = [];
  int columns;
  int palette;
  bool stopThrows = false;
  bool stopped = false;
  InputBackend? lastInputBackend;

  RecordingPlatform({this.columns = 80, this.palette = 256});

  @override
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
  void setFgDefault() {
    calls.add('setFgDefault');
  }

  @override
  void setBgDefault() {
    calls.add('setBgDefault');
  }

  @override
  bool render() {
    calls.add('render');
    return true;
  }

  @override
  bool refresh() {
    calls.add('refresh');
    return true;
  }

  @override
  void cursorEnable(int y, int x) {
    calls.add('cursorEnable($y,$x)');
  }

  @override
  void cursorDisable() {
    calls.add('cursorDisable');
  }

  @override
  void stop() {
    if (stopThrows) throw StateError('stop boom');
    calls.add('stop');
    stopped = true;
  }

  @override
  int? defaultBackground() {
    calls.add('defaultBackground');
    return null;
  }

  @override
  int paletteSize() {
    calls.add('paletteSize');
    return palette;
  }

  @override
  int planeColumns() {
    calls.add('planeColumns');
    return columns;
  }

  /// Raw byte sequences written to the controlling tty (bracketed-paste
  /// toggles, etc.), in order.
  final List<String> rawTtyWrites = [];

  @override
  void writeRawToTty(String s) {
    calls.add('writeRawToTty(${_quote(s)})');
    rawTtyWrites.add(s);
  }

  @override
  InputBackend createInputBackend() {
    calls.add('createInputBackend');
    final ib = _StubInputBackend(calls);
    lastInputBackend = ib;
    return ib;
  }

  @override
  BackendSurface? createSurface(Rect bounds) {
    calls.add('createSurface');
    return null;
  }

  @override
  nc.Plane? get plane => null; // recording fake has no live libnotcurses
  @override
  nc.NotCurses? get notc => null;

  String _quote(String s) {
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      buf.write(c == 0x1b
          ? r'\x1b'
          : c == 0x20
              ? '·'
              : String.fromCharCode(c));
    }
    return buf.toString();
  }
}

class _StubInputBackend implements InputBackend {
  /// Ordered call log shared with the owning [RecordingPlatform], so a
  /// dispose can be asserted to precede (or follow) platform-level calls.
  final List<String>? recorder;

  _StubInputBackend([this.recorder]);

  @override
  Future<void> get ready => Future<void>.value();

  final _controller = StreamController<InputEvent>.broadcast(sync: true);
  bool disposed = false;

  /// Arm before a dispose that should throw — exercises the choke point's
  /// "a failing join must not block terminal restoration" contract.
  bool throwOnDispose = false;

  @override
  Stream<InputEvent> get events => _controller.stream;
  @override
  void inject(InputEvent event) => _controller.add(event);
  @override
  void dispose() {
    if (disposed) return; // mirrors the real backend's idempotent dispose
    disposed = true;
    recorder?.add('inputDispose');
    _controller.close();
    if (throwOnDispose) throw StateError('dispose boom');
  }
}

void main() {
  late RecordingPlatform plat;
  late NotcursesBackend backend;
  late FakeStdio io;

  setUp(() {
    io = FakeStdio()..columns = 80;
    plat = RecordingPlatform();
    backend = NotcursesBackend.forTesting(io: io, platform: plat);
  });

  group('NotcursesBackend cursor + writes', () {
    test('moveCursor only updates state; no platform call', () {
      backend.moveCursor(5, 7);
      expect(plat.calls, isEmpty,
          reason: 'moveCursor batches; flush emits the cursorEnable');
    });

    test('eraseCells writes spaces at (row, col) and updates cursor', () {
      backend.eraseCells(2, 3, 4);
      expect(plat.calls, ['putStrYX(2,3,····)']);
      backend.writeText('x');
      expect(plat.calls.last, 'putStrYX(2,3,x)',
          reason: 'cursor was set to (2,3) by eraseCells');
    });

    test('writeText advances cursor by visible columns, not text.length', () {
      backend.moveCursor(0, 0);
      backend.writeText('\x1b[31mhello\x1b[0m');
      // SGR is stripped and applied via plane-styling calls; only the
      // visible "hello" reaches putStrYX at column 0. A follow-up write
      // must land at column 5, not at column 13 (full string length).
      backend.writeText('!');
      expect(
        plat.calls,
        contains('putStrYX(0,0,hello)'),
        reason: 'embedded SGR is parsed out; putStr gets clean text',
      );
      expect(
        plat.calls,
        contains('putStrYX(0,5,!)'),
        reason: 'cursor advanced by visible-column count = 5',
      );
    });

    test('save/restoreCursor round-trips the logical position', () {
      backend.moveCursor(3, 4);
      backend.saveCursor();
      backend.moveCursor(7, 8);
      backend.writeText('x');
      backend.restoreCursor();
      backend.writeText('y');
      expect(plat.calls, contains('putStrYX(7,8,x)'));
      expect(plat.calls, contains('putStrYX(3,4,y)'));
    });

    test('restoreCursor without prior save is a no-op', () {
      backend.moveCursor(2, 2);
      backend.restoreCursor();
      backend.writeText('z');
      expect(plat.calls, ['putStrYX(2,2,z)']);
    });
  });

  group('NotcursesBackend.flush', () {
    test('renders then positions the hardware cursor', () {
      backend.moveCursor(4, 0);
      backend.writeText('changed');
      backend.parkCursor(4, 9);
      backend.flush();
      expect(plat.calls, [
        'putStrYX(4,0,changed)',
        'cursorDisable',
        'render',
        'cursorEnable(4,9)',
      ]);
    });

    test('flush uses the explicit park cursor each time', () {
      backend.parkCursor(0, 0);
      backend.flush();
      backend.parkCursor(2, 3);
      backend.flush();
      // Each flush lands on a new row, so each re-emits the full frame.
      expect(
        plat.calls,
        [
          'cursorDisable',
          'cursorEnable(0,0)',
          'cursorDisable',
          'cursorEnable(2,3)',
        ],
      );
    });

    test('does not re-emit when the cursor stays on the same row', () {
      // Typing within one input row moves only the column; the row is stable,
      // so the damage-recovery re-emit must not fire on every keystroke.
      backend.parkCursor(4, 0);
      backend.flush();
      plat.calls.clear();
      backend.parkCursor(4, 5); // same row, advanced column
      backend.flush();
      expect(plat.calls, ['cursorEnable(4,5)']);
    });

    test('background drawing does not move or refresh the park cursor', () {
      backend.parkCursor(8, 4);
      backend.flush();
      plat.calls.clear();

      backend.moveCursor(2, 0);
      backend.writeText('background');
      backend.flush();

      expect(plat.calls, [
        'putStrYX(2,0,background)',
        'render',
        'cursorEnable(8,4)',
      ]);
    });

    test('logical frame coalesces leaf flushes into one render', () {
      backend.parkCursor(6, 2);
      backend.beginFrame();
      for (var row = 0; row < 5; row++) {
        backend.moveCursor(row, 0);
        backend.writeText('row$row');
        backend.flush();
      }
      expect(plat.calls.where((c) => c == 'render'), isEmpty);

      backend.endFrame();

      expect(plat.calls.where((c) => c == 'render'), hasLength(1));
      expect(plat.calls.where((c) => c == 'refresh'), isEmpty);
      expect(plat.calls.where((c) => c == 'cursorDisable'), hasLength(1));
      expect(plat.calls.last, 'cursorEnable(6,2)');
    });
  });

  group('retained screen scheduling', () {
    // Phase 5: leading/trailing chat presentation. The FIRST idle write
    // presents immediately (no perceptible delay); sustained writes within the
    // 8 ms window coalesce onto ONE trailing render at the window boundary.
    test('leading edge presents the first idle write immediately', () async {
      final screen = Screen.withBackend(
        backend: backend,
        io: io,
        layout: ScreenLayout.fromSize(80, 24),
      );
      plat.calls.clear();

      screen.chat.write('first');
      expect(plat.calls.where((c) => c == 'render'), hasLength(1),
          reason: 'leading edge renders the first idle mutation without delay');
    });

    test('sustained writes coalesce: 20 writes yield one leading + one trailing render',
        () async {
      final screen = Screen.withBackend(
        backend: backend,
        io: io,
        layout: ScreenLayout.fromSize(80, 24),
      );
      plat.calls.clear();

      // 20 rapid writes: the first is idle and renders immediately (leading
      // edge); the other 19 accumulate inside the window and coalesce into a
      // single trailing render — not one render per write.
      for (var i = 0; i < 20; i++) {
        screen.chat.write('chunk-$i ');
      }
      expect(plat.calls.where((c) => c == 'render'), hasLength(1),
          reason: 'only the leading-edge first write renders during the window');

      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(plat.calls.where((c) => c == 'render'), hasLength(2),
          reason: 'one trailing render presents the 19 accumulated writes once');
    });

    test('cursor-only input movement skips grid rendering', () {
      final screen = Screen.withBackend(
        backend: backend,
        io: io,
        layout: ScreenLayout.fromSize(80, 24),
      );
      screen.input.render(prompt: '> ', buffer: 'abcd', cursor: 4);
      plat.calls.clear();

      screen.input.render(prompt: '> ', buffer: 'abcd', cursor: 2);

      expect(plat.calls.where((c) => c.startsWith('putStrYX')), isEmpty);
      expect(plat.calls.where((c) => c == 'render'), isEmpty);
      expect(plat.calls.last, startsWith('cursorEnable('));
    });

    test('input edits repaint only the changed suffix', () {
      final screen = Screen.withBackend(
        backend: backend,
        io: io,
        layout: ScreenLayout.fromSize(80, 24),
      );
      screen.input.render(prompt: '> ', buffer: 'abcd', cursor: 4);
      plat.calls.clear();

      screen.input.render(prompt: '> ', buffer: 'abcde', cursor: 5);

      final writes = plat.calls.where((c) => c.startsWith('putStrYX')).toList();
      expect(writes, hasLength(1));
      expect(writes.single, endsWith(',e)'));
      expect(plat.calls, containsAllInOrder(['setFgDefault', 'setBgDefault']));
      expect(plat.calls.where((c) => c == 'render'), hasLength(1));
    });
  });

  group('NotcursesBackend.supportsColor', () {
    test('paletteSize > 1 reports color', () {
      plat.palette = 256;
      expect(backend.supportsColor, isTrue);
      expect(plat.calls, ['paletteSize']);
    });

    test('paletteSize == 1 reports no color', () {
      plat.palette = 1;
      expect(backend.supportsColor, isFalse);
    });

    test('paletteSize == 8 (ANSI minimum) still counts as color', () {
      plat.palette = 8;
      expect(backend.supportsColor, isTrue);
    });

    test('after stop, supportsColor is false (no platform call)', () {
      backend.enterAltScreen();
      backend.leaveAltScreen();
      plat.calls.clear();
      expect(backend.supportsColor, isFalse);
      expect(plat.calls, isEmpty,
          reason: 'must not touch the destroyed platform');
    });
  });

  group('NotcursesBackend.colorize', () {
    test('wraps text when color enabled', () {
      plat.palette = 256;
      expect(backend.colorize('31', 'red'), equals('\x1b[31mred\x1b[0m'));
    });

    test('passes through when no color', () {
      plat.palette = 1;
      expect(backend.colorize('31', 'red'), equals('red'));
    });
  });

  group('NotcursesBackend lifecycle / stop guard', () {
    test('enterAltScreen + leaveAltScreen calls stop exactly once', () {
      backend.enterAltScreen();
      backend.leaveAltScreen();
      expect(plat.calls, ['stop']);
    });

    test('leaveAltScreen without enter is a no-op', () {
      backend.leaveAltScreen();
      expect(plat.calls, isEmpty);
    });

    test('double leaveAltScreen calls stop only once', () {
      backend.enterAltScreen();
      backend.leaveAltScreen();
      backend.leaveAltScreen();
      expect(plat.calls.where((c) => c == 'stop'), hasLength(1));
    });

    test('flush after leaveAltScreen is a no-op (T-01 safety)', () {
      backend.enterAltScreen();
      backend.flush();
      plat.calls.clear();
      backend.leaveAltScreen();
      backend.flush();
      // Only stop should appear; no render or cursorEnable after.
      expect(plat.calls, ['stop']);
    });

    test('every terminal-touching method is guarded after stop', () {
      backend.enterAltScreen();
      backend.leaveAltScreen();
      plat.calls.clear();
      // Now poke every public method that should be guarded.
      backend.moveCursor(0, 0);
      backend.eraseCells(0, 0, 5);
      backend.writeText('hello');
      backend.flush();
      backend.enterAltScreen();
      backend.leaveAltScreen();
      expect(plat.calls, isEmpty,
          reason: 'no platform call should reach the stopped platform');
    });

    test('cursor state does not advance after stop', () {
      backend.moveCursor(3, 5);
      backend.enterAltScreen();
      backend.leaveAltScreen();
      backend.writeText('hello'); // ignored
      // Force a (no-op) flush to confirm cursor stayed at (3,5) — but the
      // flush itself is gated, so we can't see cursorEnable. Verify via
      // putStrYX absence.
      expect(plat.calls.where((c) => c.startsWith('putStrYX')), isEmpty);
    });
  });

  group('NotcursesBackend.createInputBackend', () {
    test('returns an InputBackend from the platform', () {
      final ib = backend.createInputBackend();
      expect(ib, isNotNull);
      expect(plat.calls, contains('createInputBackend'));
      expect(plat.lastInputBackend, same(ib));
    });

    test('throws StateError after leaveAltScreen', () {
      backend.enterAltScreen();
      backend.leaveAltScreen();
      expect(() => backend.createInputBackend(), throwsStateError);
    });
  });

  // tin-j3mk: the native input pump thread polls the notcurses context
  // (notcurses_get_nblock) until its dispose joins it. Any stop path that
  // freed the context first left that thread racing the free — the teardown
  // SIGSEGV in notcurses_stdplane. leaveAltScreen is the choke point every
  // stop path funnels through (normal teardown, the emergency restore taken
  // on SIGTERM/SIGHUP or an escaping error, the init-failure unwind), so the
  // join is asserted there, not in the caller.
  group('NotcursesBackend teardown ordering (tin-j3mk)', () {
    test('leaveAltScreen disposes input backends before platform stop', () {
      backend.enterAltScreen();
      backend.createInputBackend();
      backend.leaveAltScreen();
      expect(
        plat.calls.indexOf('inputDispose') < plat.calls.indexOf('stop'),
        isTrue,
        reason: 'the pump thread must be joined before notcurses_stop frees '
            'the context it polls',
      );
    });

    test('a stop path that skipped disposeInput still joins the pump', () {
      // The emergency-restore shape: leaveAltScreen with no earlier dispose.
      backend.enterAltScreen();
      final ib = backend.createInputBackend() as _StubInputBackend;
      expect(ib.disposed, isFalse);
      backend.leaveAltScreen();
      expect(ib.disposed, isTrue);
      expect(plat.stopped, isTrue);
    });

    test('normal path: earlier dispose is not double-disposed', () {
      backend.enterAltScreen();
      final ib = backend.createInputBackend();
      ib.dispose(); // what LineEditor.disposeInput does during teardown
      backend.leaveAltScreen();
      expect(
        plat.calls.where((c) => c == 'inputDispose').length,
        1,
        reason: 'dispose is idempotent; the choke-point join is a no-op when '
            'the normal path already disposed the backend',
      );
      expect(plat.calls.indexOf('inputDispose') < plat.calls.indexOf('stop'),
          isTrue);
    });

    test('every handed-out backend is disposed before stop', () {
      backend.enterAltScreen();
      final first = backend.createInputBackend() as _StubInputBackend;
      final second = backend.createInputBackend() as _StubInputBackend;
      backend.leaveAltScreen();
      expect(first.disposed, isTrue);
      expect(second.disposed, isTrue);
      expect(plat.calls.indexOf('inputDispose') < plat.calls.indexOf('stop'),
          isTrue);
    });

    test('a throwing dispose does not block the platform stop', () {
      backend.enterAltScreen();
      final ib = backend.createInputBackend() as _StubInputBackend;
      ib.throwOnDispose = true;
      backend.leaveAltScreen();
      expect(plat.stopped, isTrue,
          reason: 'the terminal must be restored even if a dispose throws');
    });
  });

  group('NotcursesBackend column reporting', () {
    test('terminalColumns delegates to plane width', () {
      plat.columns = 132;
      expect(backend.terminalColumns, 132);
      expect(plat.calls.contains('planeColumns'), isTrue);
    });
  });

  group('NotcursesBackend bracketed paste', () {
    test('enableBracketedPaste writes \\e[?2004h to the tty', () {
      backend.enableBracketedPaste();
      expect(plat.rawTtyWrites, ['\x1b[?2004h']);
    });

    test('disableBracketedPaste writes \\e[?2004l to the tty', () {
      backend.enableBracketedPaste();
      backend.disableBracketedPaste();
      expect(plat.rawTtyWrites, ['\x1b[?2004h', '\x1b[?2004l']);
    });

    test('enable is idempotent (no duplicate escape)', () {
      backend.enableBracketedPaste();
      backend.enableBracketedPaste();
      expect(plat.rawTtyWrites, ['\x1b[?2004h']);
    });

    test('disable without enable is a no-op', () {
      backend.disableBracketedPaste();
      expect(plat.rawTtyWrites, isEmpty);
    });

    test('after stop, enable/disable are no-ops', () {
      backend.enterAltScreen();
      backend.leaveAltScreen();
      plat.calls.clear();
      backend.enableBracketedPaste();
      backend.disableBracketedPaste();
      expect(plat.calls, isEmpty,
          reason: 'must not write to the tty after the platform is stopped');
    });
  });

  group('NotcursesBackend SGR parsing (T-07)', () {
    // Regression: notcurses' putStr silently drops writes containing
    // embedded SGR (\x1b[…m) — both the escape bytes AND the surrounding
    // printable text vanish. The backend must parse SGR out and use
    // plane-styling APIs directly. See dart_notcurses/test/sgr_test.dart
    // for the runtime confirmation of the underlying notcurses behavior.

    test('\\x1b[31m R \\x1b[0m becomes setFgRGB → putStr → reset', () {
      backend.moveCursor(0, 0);
      backend.writeText('\x1b[31mR\x1b[0m');
      expect(plat.calls, [
        'setFgRGB(0xcd0000)',
        'putStrYX(0,0,R)',
        'setFgDefault',
        'setBgDefault',
        'setStyles(0x0)',
      ]);
    });

    test('trailing reset does not emit an empty putStr', () {
      backend.moveCursor(0, 0);
      backend.writeText('R\x1b[0m');
      expect(plat.calls, [
        'putStrYX(0,0,R)',
        'setFgDefault',
        'setBgDefault',
        'setStyles(0x0)',
      ]);
    });

    test('combined \\x1b[1;4m OR-s bold+underline into one setStyles', () {
      backend.moveCursor(0, 0);
      backend.writeText('\x1b[1;4mX');
      // Styles.bold = 0x2, Styles.underline = 0x8 → 0xa.
      expect(plat.calls, [
        'setStyles(0xa)',
        'putStrYX(0,0,X)',
      ]);
    });

    test('truecolor 38;2;r;g;b packs into a single setFgRGB', () {
      backend.moveCursor(0, 0);
      backend.writeText('\x1b[38;2;255;128;64mX');
      expect(plat.calls, ['setFgRGB(0xff8040)', 'putStrYX(0,0,X)']);
    });

    test('bright fg 90-97 maps to the bright palette', () {
      backend.moveCursor(0, 0);
      backend.writeText('\x1b[91mX'); // bright red
      expect(plat.calls, ['setFgRGB(0xff0000)', 'putStrYX(0,0,X)']);
    });

    test('unknown SGR is skipped, plain text still lands', () {
      backend.moveCursor(0, 0);
      backend.writeText('\x1b[99mZ');
      expect(plat.calls, ['putStrYX(0,0,Z)']);
    });

    test('non-SGR CSI (e.g. cursor movement) is dropped', () {
      backend.moveCursor(0, 0);
      backend.writeText('\x1b[2AZ'); // CSI 2 A = move cursor up 2
      expect(plat.calls, ['putStrYX(0,0,Z)']);
    });

    test('two colored spans back-to-back land at advancing columns', () {
      backend.moveCursor(0, 0);
      backend.writeText('\x1b[32mAB\x1b[36mCD');
      expect(plat.calls, [
        'setFgRGB(0x00cd00)',
        'putStrYX(0,0,AB)',
        'setFgRGB(0x00cdcd)',
        'putStrYX(0,2,CD)',
      ]);
    });

    test('wide-glyph runs advance by terminal cells (tin-q4vz)', () {
      backend.moveCursor(0, 0);
      // 漢字 = 4 cells (not 2 code units); the second span must start at
      // column 4. An advance short of that paints the tail over the wide
      // glyphs' second cells.
      backend.writeText('\x1b[32m漢字\x1b[36mCD');
      expect(plat.calls, [
        'setFgRGB(0x00cd00)',
        'putStrYX(0,0,漢字)',
        'setFgRGB(0x00cdcd)',
        'putStrYX(0,4,CD)',
      ]);
    });

    test('adjacent identical styles collapse into one setter + one putStr',
        () {
      backend.moveCursor(0, 0);
      // \x1b[32m ... \x1b[32m is a redundant mid-string re-set of the same
      // green. parseStyledRuns collapses those two runs, so the emitter
      // writes "ABCD" under a single setFgRGB instead of two.
      backend.writeText('\x1b[32mAB\x1b[32mCD\x1b[0m');
      expect(plat.calls, [
        'setFgRGB(0x00cd00)',
        'putStrYX(0,0,ABCD)',
        'setFgDefault',
        'setBgDefault',
        'setStyles(0x0)',
      ]);
    });
  });
}
