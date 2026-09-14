import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';

void main() {
  group('ProviderStreamConsumer', () {
    late ProviderStreamConsumer consumer;
    late FakeAgentSink sink;

    setUp(() {
      consumer = const ProviderStreamConsumer();
      sink = FakeAgentSink();
    });

    test('MessageComplete only → content and usage set', () async {
      final stream = _scripted([
        const MessageComplete(
          content: [TextBlock('hello')],
          stopReason: 'end_turn',
          usage: TokenUsage(inputTokens: 10, outputTokens: 5),
        ),
      ]);

      final outcome = await consumer.consume(stream, sink: sink);
      expect(outcome.content, isNotNull);
      expect(outcome.content!.single, isA<TextBlock>());
      expect((outcome.content!.single as TextBlock).text, 'hello');
      expect(outcome.usage, isNotNull);
      expect(outcome.usage!.inputTokens, 10);
      expect(outcome.stopReason, 'end_turn');
      expect(outcome.error, isNull);
      expect(outcome.cancelled, isFalse);
    });

    test('StreamNotice → sink notice (warning), not content', () async {
      final stream = _scripted([
        const StreamNotice('provider error: 503 — retry 1/3 in 0.3s'),
        const MessageComplete(
          content: [TextBlock('ok')],
          stopReason: 'end_turn',
        ),
      ]);

      final outcome = await consumer.consume(stream, sink: sink);
      expect(sink.notices, hasLength(1));
      expect(sink.notices.single.message, contains('retry 1/3'));
      expect(sink.notices.single.kind, NoticeKind.warning);
      expect(outcome.content!.single, isA<TextBlock>(),
          reason: 'the notice is not transcript content');
    });

    test('TextDelta + MessageComplete → chat received text', () async {
      final stream = _scripted([
        const TextDelta('hi '),
        const TextDelta('there'),
        const MessageComplete(
          content: [TextBlock('hi there')],
          stopReason: 'end_turn',
        ),
      ]);

      final outcome = await consumer.consume(stream, sink: sink);
      expect(outcome.content!.single, isA<TextBlock>());
      expect(sink.texts, contains('hi '));
      expect(sink.texts, contains('there'));
    });

    test('ToolCallStart does not render', () async {
      final stream = _scripted([
        const ToolCallStart(id: 'c1', name: 'read'),
        const MessageComplete(
          content: [ToolUseBlock(id: 'c1', name: 'read', input: {})],
          stopReason: 'tool_use',
        ),
      ]);

      final outcome = await consumer.consume(stream, sink: sink);
      expect(outcome.content!.single, isA<ToolUseBlock>());
      // A tool-call-only message renders no text.
      expect(sink.texts, isEmpty);
    });

    test('StreamError → error set, content null', () async {
      final stream = _scripted([
        const StreamError('server exploded'),
      ]);
      final outcome = await consumer.consume(stream, sink: sink);
      expect(outcome.error, 'server exploded');
      expect(outcome.content, isNull);
      expect(outcome.stopReason, isNull);
      expect(outcome.cancelled, isFalse);
    });

    test('empty stream → content null', () async {
      final outcome = await consumer.consume(_scripted(const []), sink: sink);
      expect(outcome.content, isNull);
      expect(outcome.error, isNull);
    });

    test('completed requests ignore later cancellation of a shared turn',
        () async {
      final cancel = Completer<void>();
      var notifications = 0;
      for (var i = 0; i < 6; i++) {
        final outcome = await consumer.consume(
          _scripted([
            const MessageComplete(
                content: [TextBlock('done')], stopReason: 'end_turn')
          ]),
          sink: sink,
          cancelSignal: cancel.future,
          onCancelled: () => notifications++,
        );
        expect(outcome.cancelled, isFalse);
      }
      final stops = sink.activityStops;
      cancel.complete();
      await pumpEventQueue();
      expect(notifications, 0);
      expect(sink.activityStops, stops,
          reason: 'finished streams must not stop a later activity');
      expect(sink.notices, isEmpty);
    });

    test('only the active request observes a shared cancellation', () async {
      final cancel = Completer<void>();
      var notifications = 0;
      for (var i = 0; i < 6; i++) {
        await consumer.consume(_scripted(const []),
            sink: sink,
            cancelSignal: cancel.future,
            onCancelled: () => notifications++);
      }
      final controller = StreamController<StreamEvent>();
      final active = consumer.consume(controller.stream,
          sink: sink,
          cancelSignal: cancel.future,
          onCancelled: () => notifications++);
      cancel.complete();
      expect((await active).cancelled, isTrue);
      expect(notifications, 1);
      expect(sink.notices, isEmpty, reason: 'the turn owns the user notice');
      await controller.close();
    });

    test('stream errors settle and release the subscription before late cancel',
        () async {
      final cancel = Completer<void>();
      var releases = 0;
      var notifications = 0;
      final controller =
          StreamController<StreamEvent>(onCancel: () => releases++);
      final active = consumer.consume(controller.stream,
          sink: sink,
          cancelSignal: cancel.future,
          onCancelled: () => notifications++);
      controller.addError(StateError('broken stream'));
      expect((await active).error, isA<StateError>());
      expect(releases, 1);
      final stops = sink.activityStops;
      controller.add(const TextDelta('late text'));
      cancel.complete();
      await pumpEventQueue();
      expect(notifications, 0);
      expect(sink.activityStops, stops);
      expect(sink.texts, isEmpty);
      await controller.close();
    });

    test('cancellation notifies before asynchronous subscription cleanup',
        () async {
      final cancel = Completer<void>();
      final cleanup = Completer<void>();
      final notified = Completer<void>();
      final controller =
          StreamController<StreamEvent>(onCancel: () => cleanup.future);
      var returned = false;
      final active = consumer
          .consume(controller.stream,
              sink: sink,
              cancelSignal: cancel.future,
              onCancelled: notified.complete)
          .then((outcome) {
        returned = true;
        return outcome;
      });
      cancel.complete();
      await notified.future;
      expect(returned, isFalse);
      cleanup.complete();
      expect((await active).cancelled, isTrue);
      await controller.close();
    });

    test('cancelSignal mid-stream → cancelled true', () async {
      final controller = StreamController<StreamEvent>();
      final cancel = Completer<void>();
      controller.add(const TextDelta('before'));
      final consumeFuture = consumer.consume(
        controller.stream,
        sink: sink,
        cancelSignal: cancel.future,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      cancel.complete();
      await controller.close();
      final outcome = await consumeFuture;
      expect(outcome.cancelled, isTrue);
      expect(sink.texts, contains('before'));
    });

    test('stream onError → error set', () async {
      final controller = StreamController<StreamEvent>();
      Future.microtask(() {
        controller.addError(Exception('connection reset'));
        controller.close();
      });
      final outcome = await consumer.consume(controller.stream, sink: sink);
      expect(outcome.error, isA<Exception>());
      expect(outcome.content, isNull);
    });

    test('TextDelta then ToolCallStart inserts a newline', () async {
      final stream = _scripted([
        const TextDelta('thinking...'),
        const ToolCallStart(id: 'c1', name: 'bash'),
        const MessageComplete(
          content: [ToolUseBlock(id: 'c1', name: 'bash', input: {})],
          stopReason: 'tool_use',
        ),
      ]);
      await consumer.consume(stream, sink: sink);
      expect(sink.texts.join(), contains('thinking...'));
      expect(sink.newlines, greaterThanOrEqualTo(1));
    });
  });
}

Stream<StreamEvent> _scripted(List<StreamEvent> events) {
  final controller = StreamController<StreamEvent>();
  for (final e in events) {
    controller.add(e);
  }
  controller.close();
  return controller.stream;
}
