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
      expect(outcome.error, isNull);
      expect(outcome.cancelled, isFalse);
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
      expect(outcome.cancelled, isFalse);
    });

    test('empty stream → content null', () async {
      final outcome = await consumer.consume(_scripted(const []), sink: sink);
      expect(outcome.content, isNull);
      expect(outcome.error, isNull);
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
