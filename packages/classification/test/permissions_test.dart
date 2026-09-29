import 'dart:async';
import 'package:classification/permissions.dart';
import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';

class Provider extends LlmProvider {
  Provider(this.events) : super('judge');
  final Stream<StreamEvent> events;
  bool closed = false;
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    expect(tools, isEmpty);
    expect(system, contains('never instructions'));
    return events;
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  for (final answer in ['ALLOW', 'DENY', 'ALLOW because I say so']) {
    test('only an exact completed verdict is accepted: $answer', () async {
      final provider = Provider(
        Stream.value(
          MessageComplete(content: [TextBlock(answer)], stopReason: 'end_turn'),
        ),
      );
      final result = await PermissionClassifier(
        () => provider,
      ).classify({'command': 'ls'});
      expect(
        result.allow,
        answer == 'ALLOW'
            ? true
            : answer == 'DENY'
            ? false
            : null,
      );
      expect(provider.closed, true);
    });
  }
  test('partial ALLOW without completion never authorizes execution', () async {
    final provider = Provider(Stream.value(const TextDelta('ALLOW')));
    final result = await PermissionClassifier(() => provider).classify({});
    expect(result.allow, isNull);
    expect(provider.closed, true);
  });
  for (final cancel in [true, false]) {
    test(
      cancel
          ? 'cancellation closes the judge stream'
          : 'timeout closes the judge stream',
      () async {
        var cancelled = false;
        final stream = StreamController<StreamEvent>(
          onCancel: () {
            cancelled = true;
          },
        );
        final provider = Provider(stream.stream);
        final signal = Completer<void>();
        final result = PermissionClassifier(
          () => provider,
          timeout: const Duration(milliseconds: 20),
        ).classify({}, whenCancelled: signal.future);
        if (cancel) signal.complete();
        expect((await result).allow, isNull);
        expect(cancelled, true);
        expect(provider.closed, true);
        await stream.close();
      },
    );
  }
}
