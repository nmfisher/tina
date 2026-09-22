import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('PermissionClassifier', () {
    test('parses ALLOW / DENY answers', () async {
      final allow = PermissionClassifier(_ScriptedProvider('ALLOW'));
      expect(await allow.allow('write', const {'filePath': '/x'}), isTrue);
      final deny = PermissionClassifier(_ScriptedProvider('DENY'));
      expect(await deny.allow('bash', const {'command': 'rm -rf /'}), isFalse);
    });

    for (final answer in ['The call is safe. ALLOW', 'NOT ALLOW', 'ALLOW or DENY']) {
      test('ambiguous or non-verdict output falls back: $answer', () async {
        final c = PermissionClassifier(_ScriptedProvider(answer));
        expect(await c.allow('edit', const {}), isNull);
      });
    }

    test('stream error -> null', () async {
      final c = PermissionClassifier(_ScriptedProvider('', error: StateError('boom')));
      expect(await c.allow('write', const {}), isNull);
    });

    test('garbage output -> null', () async {
      final c = PermissionClassifier(_ScriptedProvider('maybe?'));
      expect(await c.allow('write', const {}), isNull);
    });

    test('a stream that never completes times out -> null', () async {
      final c = PermissionClassifier(
        _NeverCompletingProvider(),
        timeout: const Duration(milliseconds: 20),
      );
      expect(await c.allow('write', const {}), isNull);
    });

    test('classify reports the timeout as the failure reason', () async {
      final c = PermissionClassifier(
        _NeverCompletingProvider(),
        timeout: const Duration(milliseconds: 20),
      );
      final outcome = await c.classify(PermissionPrompt('write', const {}));
      expect(outcome.allow, isNull);
      expect(outcome.failure, ClassifierFailure.timeout);
      expect(outcome.decided, isFalse);
      expect(
        outcome.failure!.phrase(timeout: c.timeout),
        'timed out after 20ms',
        reason: 'sub-second test-scale timeouts print as milliseconds; the '
            '30s default is pinned by the test below',
      );
    });

    test('classify reports a stream error as the failure reason', () async {
      final c =
          PermissionClassifier(_ScriptedProvider('', error: StateError('boom')));
      final outcome = await c.classify(PermissionPrompt('write', const {}));
      expect(outcome.allow, isNull);
      expect(outcome.failure, ClassifierFailure.streamError);
    });

    test('classify reports an unreadable answer as the failure reason',
        () async {
      final c = PermissionClassifier(_ScriptedProvider('maybe?'));
      final outcome = await c.classify(PermissionPrompt('write', const {}));
      expect(outcome.allow, isNull);
      expect(outcome.failure, ClassifierFailure.unreadable);
    });

    test('send() throwing is swallowed -> null', () async {
      final c = PermissionClassifier(_ThrowingProvider());
      expect(await c.allow('write', const {}), isNull);
    });

    test('default timeout is 30s', () {
      expect(PermissionClassifier(_ScriptedProvider('ALLOW')).timeout,
          const Duration(seconds: 30));
    });
  });
}

class _ScriptedProvider extends LlmProvider {
  final String _answer;
  final Object? error;
  _ScriptedProvider(this._answer, {this.error}) : super('scripted');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    if (error != null) {
      yield StreamError(error!);
      return;
    }
    yield TextDelta(_answer);
  }
}

class _NeverCompletingProvider extends LlmProvider {
  _NeverCompletingProvider() : super('never');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) =>
      StreamController<StreamEvent>().stream;
}

class _ThrowingProvider extends LlmProvider {
  _ThrowingProvider() : super('throwing');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) => throw StateError('no client');
}
