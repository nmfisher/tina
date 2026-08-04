import 'dart:typed_data';

import 'package:tina_console/tina_console.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

// Phase 5 acceptance: the screen-global presentation scheduler replaces every
// region's per-region _paintTimer with one trailing timer + one idle clock for
// the whole screen. Verified deterministically with fake_async + an injected
// clock so the leading/trailing idle check advances with async.elapse.
//
// Drives the real ScrollingTextRegion through a COUNTING backend. It reproduces
// the real retained-grid contract faithfully:
//
//   - chat surface writes set a dirty flag via a markDirty callback;
//   - beginFrame/endFrame/flush coalesce any number of writes inside one
//     logical frame into ONE render at outermost frame close (matching the real
//     backend's retained-grid behaviour);
//   - because the counting backend reports [coalescesPaints] = true, the chat
//     region routes all writes through the presentation scheduler, so we can
//     observe the leading-vs-trailing vs cancelled-on-timeout contract precisely.

/// Counting retained-mode backend. Surface mutations mark the grid dirty; the
/// frame machinery flushes at most one render per coalesced frame.
class CountingBackend implements TerminalBackend {
  int renders = 0;
  final List<String> writes = [];

  int _frameDepth = 0;
  bool _flushPending = false;
  bool _dirty = false;

  /// Chat surfaces call this on every mutation so the grid is marked dirty.
  /// Mirrors NotcursesBackendSurface._present: it marks dirty AND flushes, and
  /// flush() (inside a frame) sets the coalescing pending flag.
  void surfaceMutated() {
    _dirty = true;
    flush();
  }

  // Retained-mode backend: coalescing into timer-bounded presents.
  @override
  bool get coalescesPaints => true;

  @override
  bool get supportsColor => true;

  @override
  String colorize(String code, String text) => text;

  @override
  Stream<List<int>> get stdin => const Stream.empty();

  @override
  int get terminalColumns => 80;

  @override
  void beginFrame() => _frameDepth++;

  @override
  void endFrame() {
    if (_frameDepth == 0) return;
    _frameDepth--;
    if (_frameDepth == 0 && _flushPending) {
      _flushPending = false;
      _flushNow();
    }
  }

  @override
  void flush() {
    if (_frameDepth > 0) {
      _flushPending = true;
      return;
    }
    _flushNow();
  }

  void _flushNow() {
    if (_dirty) {
      renders++;
      _dirty = false;
    }
  }

  @override
  void moveCursor(int row, int col) {}

  @override
  void parkCursor(int row, int col) {}

  @override
  void eraseCells(int row, int col, int n) => _dirty = true;

  @override
  void writeText(String text) {
    writes.add(text);
    _dirty = true;
  }

  @override
  void saveCursor() {}

  @override
  void restoreCursor() {}

  @override
  void enterAltScreen() {}

  @override
  void leaveAltScreen() {}

  @override
  void enableBracketedPaste() {}

  @override
  void disableBracketedPaste() {}

  @override
  BackendSurface createSurface(Rect bounds) => _Surface(this);

  @override
  void renderImageAbsolute({
    required int row,
    required int col,
    required Uint32List rgba,
    required int width,
    required int height,
    required int maxCols,
    BackendSurface? targetSurface,
  }) {}
}

/// Child-plane surface: every mutation marks the backend's grid dirty.
class _Surface implements BackendSurface {
  final CountingBackend _backend;
  _Surface(this._backend);

  @override
  Rect get bounds => const Rect(row: 1, col: 1, width: 78, height: 22);

  void _touch() => _backend.surfaceMutated();

  @override
  void putAt({
    required int relRow,
    required int relCol,
    required String text,
    required int maxCols,
    required bool moveCursor,
  }) =>
      _touch();

  @override
  void eraseAt({
    required int relRow,
    required int relCol,
    required int n,
    required bool moveCursor,
  }) =>
      _touch();

  @override
  void moveTo(int row, int col) {}

  @override
  void resize(int width, int height) {}

  @override
  bool scrollRows(int count) {
    if (count > 0) _touch();
    return true;
  }

  @override
  void raiseToTop() {}

  @override
  void lowerToBottom() {}

  @override
  void destroy() {}
}

CountingBackend? _backend;

/// Build a counting-backend screen with the fake-async clock injected, so the
/// scheduler's idle check advances with [async].elapse.
Screen _makeScreen(FakeAsync async) {
  final io = FakeStdio()..columns = 80;
  final backend = CountingBackend();
  _backend = backend;
  return Screen.withBackend(
    backend: backend,
    io: io,
    layout: ScreenLayout.fromSize(80, 24, split: false),
    // Nanoseconds-tied fake clock: leading/trailing decisions move with elapse.
    clock: () => async.elapsed.inMicroseconds * 1000,
  );
}

void main() {
  group('presentation scheduler (leading / trailing edge)', () {
    test('leading edge: first idle write presents immediately', () {
      fakeAsync((async) {
        final s = _makeScreen(async);
        final chat = s.chat;
        final be = _backend!;

        chat.write('hello');
        expect(be.renders, 1,
            reason: 'leading edge presents the first idle mutation now');

        // A second rapid write is inside the window → no extra render yet.
        chat.write(' world');
        expect(be.renders, 1,
            reason: 'write inside the open window does not render again');
      });
    });

    test('trailing edge: writes within the window coalesce into one render',
        () {
      fakeAsync((async) {
        final s = _makeScreen(async);
        final chat = s.chat;
        final be = _backend!;

        chat.write('a'); // leading edge → render now
        expect(be.renders, 1);

        chat.write('b'); // within window → coalesce
        chat.write('c');
        expect(be.renders, 1,
            reason: 'no render fires inside the open window');
        // Cross the boundary: the single trailing timer fires once.
        async.elapse(const Duration(milliseconds: 10));
        expect(be.renders, 2,
            reason: 'trailing render presents b + c once, not per write');
      });
    });

    test('multiple windows each render at most twice (leading + trailing)',
        () {
      fakeAsync((async) {
        final s = _makeScreen(async);
        final chat = s.chat;
        final be = _backend!;

        // Window 1: first write presents immediately (leading); a second write
        // within the window coalesces and arms ONE trailing timer.
        chat.write('w1');
        expect(be.renders, 1, reason: 'window 1 leading');
        chat.write('w1b');
        async.elapse(const Duration(milliseconds: 10)); // trailing fires once
        expect(be.renders, 2, reason: 'window 1 trailing');

        // A full window must elapse before the next mutation is idle again.
        async.elapse(const Duration(milliseconds: 10));
        // Window 2: back to idle → same leading + trailing pattern.
        chat.write('w2');
        expect(be.renders, 3, reason: 'window 2 leading');
        chat.write('w2b');
        async.elapse(const Duration(milliseconds: 10));
        expect(be.renders, 4, reason: 'window 2 trailing');
      });
    });

    test('cancel: a trailing render scheduled inside the window fires once',
        () {
      fakeAsync((async) {
        final s = _makeScreen(async);
        final chat = s.chat;
        final be = _backend!;

        chat.write('x'); // leading → render
        chat.write('y'); // coalesce, arms trailing timer
        expect(be.renders, 1);
        async.elapse(const Duration(milliseconds: 20));
        expect(be.renders, 2);
        // No further timer: a second elapse adds nothing.
        async.elapse(const Duration(milliseconds: 20));
        expect(be.renders, 2, reason: 'no trailing timer lingers');
      });
    });

    test('teardown: dispose cancels the trailing timer, no stray render', () {
      fakeAsync((async) {
        final s = _makeScreen(async);
        final chat = s.chat;
        final be = _backend!;

        chat.write('leading'); // leading render
        chat.write('pending'); // arms trailing timer
        expect(be.renders, 1);
        s.dispose();
        async.elapse(const Duration(milliseconds: 20));
        expect(be.renders, 1,
            reason: 'dispose cancels the trailing timer, nothing fires later');
      });
    });

    test('detach clears pending chat state', () {
      fakeAsync((async) {
        final s = _makeScreen(async);
        final chat = s.chat;
        final be = _backend!;

        chat.write('leading');
        chat.write('pending');
        chat.detach();
        async.elapse(const Duration(milliseconds: 20));
        expect(be.renders, 1, reason: 'detach drops the pending trailing paint');
      });
    });
  });

  group('preemption (input / animation absorb pending chat)', () {
    test('input frame absorbs a pending trailing chat render and cancels timer',
        () {
      fakeAsync((async) {
        final s = _makeScreen(async);
        final chat = s.chat;
        final be = _backend!;

        chat.write('leading'); // leading render
        chat.write('pending'); // arms trailing timer
        expect(be.renders, 1);

        // Input keystroke: its frame absorbs the pending chat now and cancels
        // the trailing timer, so the chat mutation paints with the input and no
        // second render fires on the later elapse.
        s.input.render(prompt: '> ', buffer: 'ab', cursor: 2);
        expect(be.renders, 2,
            reason: 'input frame absorbed the pending chat into its own render');

        async.elapse(const Duration(milliseconds: 20));
        expect(be.renders, 2,
            reason: 'trailing timer cancelled: no redundant second render');
      });
    });

    test('animation tick absorbs a pending trailing chat render', () {
      fakeAsync((async) {
        final s = _makeScreen(async);
        final chat = s.chat;
        final be = _backend!;

        chat.write('leading');
        chat.write('pending');
        expect(be.renders, 1);

        var ticked = 0;
        s.registerAnimation(() => ticked++,
            interval: const Duration(milliseconds: 40));
        // Advance past the animation period; the tick absorbs pending chat.
        async.elapse(const Duration(milliseconds: 50));
        expect(ticked, greaterThanOrEqualTo(1), reason: 'animation tick fired');
        expect(be.renders, 2,
            reason: 'animation frame absorbed the pending chat into its render');
      });
    });

    test('reentrancy: presenting chat does not re-enter the scheduler', () {
      fakeAsync((async) {
        final s = _makeScreen(async);
        final chat = s.chat;
        final be = _backend!;

        // Leading-edge present runs synchronously inside chat.write(); it must
        // not re-arm a trailing timer or double-present.
        chat.write('one');
        chat.write('two');
        expect(be.renders, 1,
            reason: 'leading-edge present is reentrant-safe, no double render');
        async.elapse(const Duration(milliseconds: 10));
        expect(be.renders, 2, reason: 'single trailing render for two');
      });
    });
  });
}
