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

    test('answer embedded in prose still parses', () async {
      final c = PermissionClassifier(_ScriptedProvider('The call is safe. ALLOW'));
      expect(await c.allow('edit', const {}), isTrue);
    });

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

    test('send() throwing is swallowed -> null', () async {
      final c = PermissionClassifier(_ThrowingProvider());
      expect(await c.allow('write', const {}), isNull);
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
      const Stream.empty();
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
