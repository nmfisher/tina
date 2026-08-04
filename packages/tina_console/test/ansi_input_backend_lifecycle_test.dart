import 'dart:async';

import 'package:test/test.dart';

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/backend/ansi_input_backend.dart';

import 'stdio_fake.dart';

/// Tests for AnsiInputBackend's lifecycle: lazy stdin attachment, inject
/// semantics, and dispose safety. These are the bits that changed during
/// T-02 and that nothing else exercises directly.
void main() {
  group('AnsiInputBackend.inject', () {
    test('delivers event to subscribers', () async {
      final io = FakeStdio();
      final backend = AnsiInputBackend(io: io);
      final events = <InputEvent>[];
      backend.events.listen(events.add);
      backend.inject(ControlKey(ControlCode.ctrlC));
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events.single, isA<ControlKey>());
      expect((events.single as ControlKey).code, ControlCode.ctrlC);
      backend.dispose();
    });

    test('inject after dispose is a no-op (does not throw or deliver)',
        () async {
      final io = FakeStdio();
      final backend = AnsiInputBackend(io: io);
      final events = <InputEvent>[];
      final sub = backend.events.listen(events.add);
      backend.dispose();
      // Must not throw, must not deliver.
      backend.inject(ControlKey(ControlCode.ctrlC));
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      await sub.cancel();
    });

    test('injected events interleave with parsed bytes', () async {
      final io = FakeStdio();
      final backend = AnsiInputBackend(io: io);
      final events = <InputEvent>[];
      backend.events.listen(events.add);
      io.feedBytes([0x61]); // 'a'
      backend.inject(ArrowKey(ArrowDirection.up));
      io.feedBytes([0x62]); // 'b'
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(3));
      expect(events[0], equals(CharInput('a')));
      expect(events[1], equals(ArrowKey(ArrowDirection.up)));
      expect(events[2], equals(CharInput('b')));
      backend.dispose();
    });
  });

  group('AnsiInputBackend lazy stdin subscription', () {
    test('constructor does not consume stdin', () {
      final io = FakeStdio();
      // ignore: unused_local_variable
      final backend = AnsiInputBackend(io: io);
      // Direct listen on io.stdin should work since the backend hasn't
      // attached yet.
      final sub = io.stdin.listen((_) {});
      expect(sub, isNotNull);
      sub.cancel();
      backend.dispose();
    });

    test('first listener attaches stdin; events flow', () async {
      final io = FakeStdio();
      final backend = AnsiInputBackend(io: io);
      final events = <InputEvent>[];
      backend.events.listen(events.add);
      io.feedBytes([0x41]); // 'A'
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect((events.single as CharInput).text, 'A');
      backend.dispose();
    });

    test('two backends sharing stdin coexist as long as only one listens',
        () async {
      // Regression test for the menu_bar / optEditor case. With eager
      // subscription, just constructing the second backend blew up. Now
      // both can be built; only the listener actually consumes stdin.
      final io = FakeStdio();
      final backend1 = AnsiInputBackend(io: io);
      final backend2 = AnsiInputBackend(io: io);

      final received = <InputEvent>[];
      backend1.events.listen(received.add);
      io.feedBytes([0x41]);
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect((received.single as CharInput).text, 'A');

      backend1.dispose();
      backend2.dispose();
    });

    test('dispose closes stream and cancels subscription idempotently',
        () async {
      final io = FakeStdio();
      final backend = AnsiInputBackend(io: io);
      final done = Completer<void>();
      backend.events.listen(
        (_) {},
        onDone: done.complete,
      );
      backend.dispose();
      // Second dispose must not throw.
      backend.dispose();
      await done.future;
    });
  });
}
