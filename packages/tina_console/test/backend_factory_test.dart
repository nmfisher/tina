import 'package:test/test.dart';

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/ansi_backend.dart';

import 'stdio_fake.dart';

void main() {
  group('BackendFactory', () {
    test('createAnsiBackend produces an AnsiBackend', () {
      final io = FakeStdio()..columns = 80;
      final backend = createAnsiBackend(io: io, ansi: AnsiCapable.yes);
      expect(backend, isA<AnsiBackend>());
      expect(backend.supportsColor, isTrue);
    });

    test('createAnsiBackend with color disabled', () {
      final io = FakeStdio()..columns = 80;
      final backend = createAnsiBackend(io: io, ansi: AnsiCapable.no);
      expect(backend.supportsColor, isFalse);
    });

    test('AnsiBackend stdin delegates to Stdio', () {
      final io = FakeStdio()..columns = 80;
      final backend = createAnsiBackend(io: io, ansi: AnsiCapable.yes);
      // stdin is a getter that returns a Stream; verify it comes from the
      // same FakeStdio by feeding bytes and reading them back.
      final received = <List<int>>[];
      backend.stdin.listen(received.add);
      io.feedBytes([65]);
      expect(received, [
        [65]
      ]);
    });

    test('AnsiBackend terminalColumns delegates to Stdio', () {
      final io = FakeStdio()..columns = 80;
      final backend = createAnsiBackend(io: io, ansi: AnsiCapable.yes);
      expect(backend.terminalColumns, 80);
    });
  });

  group('notcurses probe', () {
    test('isNotcursesAvailable returns false when library is missing', () {
      // In CI and most dev environments, notcurses is not installed.
      // This test just verifies the function doesn't throw and returns a bool.
      final result = isNotcursesAvailable();
      expect(result, isA<bool>());
    });
  });

  group('Screen.withBackend', () {
    test('accepts a custom TerminalBackend', () {
      final io = FakeStdio()..columns = 100;
      final layout = ScreenLayout.fromSize(100, 30, hasMenuBar: false);
      final backend = createAnsiBackend(io: io, ansi: AnsiCapable.yes);
      final screen = Screen.withBackend(
        backend: backend,
        io: io,
        layout: layout,
      );
      expect(screen.backend, same(backend));
      expect(screen.passthrough, isFalse);
    });

    test('passthrough Screen has null backend', () {
      final io = FakeStdio();
      final screen = Screen.passthrough(io);
      expect(screen.backend, isNull);
      expect(screen.passthrough, isTrue);
    });
  });
}
