import 'package:test/test.dart';

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/ansi_backend.dart';
import 'package:tina_console/src/backend/notcurses_backend.dart';

import 'stdio_fake.dart';

void main() {
  group('BackendSurface.scrollRows contract', () {
    // scrollRows is the Phase 3 capability gate: a surface that supports
    // native scrolling returns true and the caller skips the O(H) redraw;
    // a surface that doesn't returns false and the caller falls back. The
    // notcurses implementation needs the native library (verified by live
    // smoke + the chat_native_scroll_test fake-surface test), but the
    // ANSI fallback is reachable in CI and must return false so the region
    // always redraws on non-notcurses backends.
    test('AnsiBackendSurface.scrollRows returns false (redraw fallback)', () {
      final io = FakeStdio()..columns = 80;
      final backend = createAnsiBackend(io: io, ansi: AnsiCapable.yes);
      final surface = AnsiBackendSurface(
        backend as AnsiBackend,
        Rect(row: 0, col: 0, width: 40, height: 10),
      );
      expect(surface.scrollRows(1), isFalse,
          reason: 'ANSI surfaces have no native scroll; must fall back');
      expect(surface.scrollRows(0), isFalse);
    });
  });

  group('NotcursesBackend', () {
    // These tests verify the NotcursesBackend class structure and API
    // without requiring the native library. The create() call would throw
    // if notcurses is not installed, which is the expected behavior.

    test('NotcursesBackend.create throws when notcurses is not available', () {
      final io = FakeStdio()..columns = 80;
      // This test is safe in CI — if notcurses is not installed, the
      // constructor throws. If it IS installed, the test verifies that
      // the backend can be created successfully.
      try {
        final backend = NotcursesBackend.create(io: io);
        // If we get here, notcurses is installed. Verify the interface.
        expect(backend, isA<TerminalBackend>());
        expect(backend, isA<NotcursesBackend>());
        // Clean up — leave alt screen which calls stop().
        backend.leaveAltScreen();
      } catch (e) {
        // Expected when notcurses is not installed: either ArgumentError
        // from FFI library loading, or StateError from init failure.
        expect(
          e is ArgumentError || e is StateError,
          isTrue,
          reason: 'Expected ArgumentError or StateError, got ${e.runtimeType}',
        );
      }
    });

  });

  group('Screen with NotcursesBackend (when available)', () {
    test('isNotcursesAvailable returns a bool without throwing', () {
      // Just verify the probe doesn't crash.
      final result = isNotcursesAvailable();
      expect(result, isA<bool>());
    });

    test('Screen.withBackend works with AnsiBackend as a stand-in', () {
      // Verify that the Screen.withBackend constructor works correctly
      // by passing an AnsiBackend in place of a NotcursesBackend.
      // This validates the integration path without needing native libs.
      final io = FakeStdio()..columns = 100;
      final layout = ScreenLayout.fromSize(100, 30, hasMenuBar: true);
      final backend = createAnsiBackend(io: io, ansi: AnsiCapable.yes);

      final screen = Screen.withBackend(
        backend: backend,
        io: io,
        layout: layout,
      );

      // Verify Screen delegates to backend.
      expect(screen.backend, same(backend));

      // Verify frame rendering through backend works.
      screen.redrawFrame();
      final output = io.written.toString();
      // Should contain border characters from the frame.
      expect(output, contains('┌'));
      expect(output, contains('┐'));
      expect(output, contains('└'));
      expect(output, contains('┘'));
    });

    test('colorize delegates to backend', () {
      final io = FakeStdio()..columns = 100;
      final layout = ScreenLayout.fromSize(100, 30);
      final backend = createAnsiBackend(io: io, ansi: AnsiCapable.yes);
      final screen = Screen.withBackend(
        backend: backend,
        io: io,
        layout: layout,
      );

      final colored = screen.colorize('31', 'hello');
      expect(colored, equals('\x1b[31mhello\x1b[0m'));

      final uncolored = screen.colorize('31', 'hello');
      // With color enabled, text is wrapped.
      expect(uncolored, contains('hello'));
    });

    test('colorize with color disabled passes through', () {
      final io = FakeStdio()..columns = 100;
      final layout = ScreenLayout.fromSize(100, 30);
      final backend = createAnsiBackend(io: io, ansi: AnsiCapable.no);
      final screen = Screen.withBackend(
        backend: backend,
        io: io,
        layout: layout,
      );

      final result = screen.colorize('31', 'hello');
      expect(result, equals('hello'));
    });
  });
}

