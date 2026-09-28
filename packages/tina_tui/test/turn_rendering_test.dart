import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tui/tina_tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;

Future<void> waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('condition did not become true');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class ControlledProvider implements LlmProvider {
  final requests = <StreamController<StreamEvent>>[];
  @override
  String get model => 'controlled';
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    final request = StreamController<StreamEvent>();
    requests.add(request);
    return request.stream;
  }

  @override
  void close() {
    for (final request in requests) {
      unawaited(request.close());
    }
  }
}

void main() {
  test('busy input queues in order and an unfinished draft survives', () async {
    final directory = Directory.systemTemp.createTempSync('tina_queue_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final provider = ControlledProvider();
    final session = TuiSession.start(
        providerFactory: (_) => provider,
        workingDirectory: directory.path,
        configPath: '/nonexistent/config');
    final io = FakeIo();
    final screen = fakeScreen(io);
    final app = runApp(session, screen: screen);
    addTearDown(() async {
      io.closeInput();
      await app;
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    io.feedBytes('first\r'.codeUnits);
    await waitFor(() => provider.requests.length == 1);
    io.feedBytes('second\rthird\rdra'.codeUnits);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(provider.requests, hasLength(1));
    for (var i = 0; i < 3; i++) {
      await waitFor(() => provider.requests.length == i + 1);
      provider.requests[i].add(MessageComplete(
          content: [TextBlock('answer $i')], stopReason: 'end_turn'));
      await provider.requests[i].close();
    }
    await waitFor(() => session.host.session.turns.length == 3);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    io.feedBytes('ft\r'.codeUnits);
    await waitFor(() => provider.requests.length == 4);
    expect(
        session.host.session.loop.log
            .whereType<InputRecordedEntry>()
            .map((e) => e.text),
        ['first', 'second', 'third', 'draft']);
    provider.requests.last.add(
        MessageComplete(content: [TextBlock('done')], stopReason: 'end_turn'));
    await provider.requests.last.close();
    await waitFor(() => session.host.session.turns.length == 4);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    io.feedBytes('/quit\r'.codeUnits);
    expect(await app, 0);
  });

  test(
      'streaming reconciles once, resize keeps draft, cancellation permits another turn',
      () async {
    final directory = Directory.systemTemp.createTempSync('tina_render_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final provider = ControlledProvider();
    final session = TuiSession.start(
      providerFactory: (_) => provider,
      workingDirectory: directory.path,
      configPath: '/nonexistent/tina/config',
    );
    final io = FakeIo();
    final screen = fakeScreen(io);
    final sizes = StreamController<ScreenLayout>();
    final app = runApp(session, screen: screen, resizes: sizes.stream);
    addTearDown(() async {
      io.closeInput();
      await sizes.close();
      await app;
    });
    String chat() => screen.chat.snapshotLines().join('\n');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    io.feedBytes('first\r'.codeUnits);
    await waitFor(() => provider.requests.length == 1);
    final first = provider.requests[0];
    first.add(const TextDelta('partial'));
    await waitFor(() => chat().contains('tina: partial'));
    expect(session.host.session.turns, isEmpty,
        reason: 'partial text is visible before the turn completes');
    sizes.add(ScreenLayout.fromSize(100, 30, split: false));
    await waitFor(() => screen.layout.chat.width > 80);
    expect(chat(), contains('tina: partial'));
    first.add(MessageComplete(
        content: [TextBlock('partial reply')], stopReason: 'end_turn'));
    await first.close();
    await waitFor(() => session.host.session.turns.length == 1);
    expect('tina: partial reply'.allMatches(chat()), hasLength(1));

    // A draft must survive resizing while the input editor owns the keyboard.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    io.feedBytes('sec'.codeUnits);
    sizes.add(ScreenLayout.fromSize(80, 24, split: false));
    await waitFor(() => screen.layout.chat.width < 100);
    io.feedBytes('ond\r'.codeUnits);
    await waitFor(() => provider.requests.length == 2);
    expect(
        session.host.session.loop.log.whereType<InputRecordedEntry>().last.text,
        'second');
    io.feedBytes([27]);
    await waitFor(() => session.host.session.turns.length == 2);
    expect(session.host.session.turns.last.stopReason, StopReason.cancelled);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    io.feedBytes('third\r'.codeUnits);
    await waitFor(() => provider.requests.length == 3);
    provider.requests[1].add(const TextDelta('stale cancelled output'));
    provider.requests[2].add(MessageComplete(
        content: [TextBlock('final answer')], stopReason: 'end_turn'));
    await provider.requests[2].close();
    await waitFor(() => session.host.session.turns.length == 3);
    expect(chat(), isNot(contains('stale cancelled output')));
    expect('tina: final answer'.allMatches(chat()), hasLength(1),
        reason: 'completion-only providers also render without duplicates');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    io.feedBytes('/quit\r'.codeUnits);
    expect(await app, 0);
  });
}
