import 'dart:async';

import 'package:test/test.dart';

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/ansi_input_backend.dart';

import 'stdio_fake.dart';

void main() {
  group('InputBackend', () {
    test('AnsiInputBackend is an InputBackend', () {
      final io = FakeStdio()..columns = 80;
      final backend = AnsiInputBackend(io: io);
      expect(backend, isA<InputBackend>());
      backend.dispose();
    });

    test('AnsiInputBackend parses printable ASCII into CharInput', () async {
      final io = FakeStdio()..columns = 80;
      final backend = AnsiInputBackend(io: io);
      final events = <InputEvent>[];
      final sub = backend.events.listen(events.add);

      // Feed 'A' (0x41) — a printable character.
      io.feedBytes([0x41]);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first, isA<CharInput>());
      expect((events.first as CharInput).text, 'A');

      await sub.cancel();
      backend.dispose();
    });

    test('AnsiInputBackend parses Enter into ControlKey', () async {
      final io = FakeStdio()..columns = 80;
      final backend = AnsiInputBackend(io: io);
      final events = <InputEvent>[];
      final sub = backend.events.listen(events.add);

      io.feedBytes([0x0d]); // Enter
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first, isA<ControlKey>());
      expect((events.first as ControlKey).code, ControlCode.enter);

      await sub.cancel();
      backend.dispose();
    });

    test('AnsiInputBackend parses Ctrl-C into ControlKey', () async {
      final io = FakeStdio()..columns = 80;
      final backend = AnsiInputBackend(io: io);
      final events = <InputEvent>[];
      final sub = backend.events.listen(events.add);

      io.feedBytes([0x03]); // Ctrl-C
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first, isA<ControlKey>());
      expect((events.first as ControlKey).code, ControlCode.ctrlC);

      await sub.cancel();
      backend.dispose();
    });

    test('AnsiInputBackend parses arrow keys', () async {
      final io = FakeStdio()..columns = 80;
      final backend = AnsiInputBackend(io: io);
      final events = <InputEvent>[];
      final sub = backend.events.listen(events.add);

      // CSI A = up arrow
      io.feedBytes([0x1b, 0x5b, 0x41]);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first, isA<ArrowKey>());
      expect((events.first as ArrowKey).direction, ArrowDirection.up);

      await sub.cancel();
      backend.dispose();
    });

    test('AnsiInputBackend feedBytes works for programmatic input', () async {
      final io = FakeStdio()..columns = 80;
      final backend = AnsiInputBackend(io: io);
      final events = <InputEvent>[];
      final sub = backend.events.listen(events.add);

      // Feed bytes directly via the adapter method.
      backend.feedBytes([0x48, 0x69]); // 'H', 'i'
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(2));
      expect((events[0] as CharInput).text, 'H');
      expect((events[1] as CharInput).text, 'i');

      await sub.cancel();
      backend.dispose();
    });

    test('AnsiInputBackend events stream closes on dispose', () async {
      final io = FakeStdio()..columns = 80;
      final backend = AnsiInputBackend(io: io);
      final done = Completer<bool>();
      backend.events.listen(
        (_) {},
        onDone: () => done.complete(true),
      );
      backend.dispose();
      final result = await done.future;
      expect(result, isTrue);
    });

    test('AnsiInputBackend handles UTF-8 input', () async {
      final io = FakeStdio()..columns = 80;
      final backend = AnsiInputBackend(io: io);
      final events = <InputEvent>[];
      final sub = backend.events.listen(events.add);

      // UTF-8 encoding of 'é' = 0xC3 0xA9
      io.feedBytes([0xC3, 0xA9]);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect((events.first as CharInput).text, 'é');

      await sub.cancel();
      backend.dispose();
    });
  });
}
