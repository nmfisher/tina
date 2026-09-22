import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_host_interface.dart';

class _PendingHost extends FakeHostInterface {
  final answer = Completer<PermissionResponse>();

  @override
  Future<PermissionResponse> askPermission(PermissionPrompt prompt) =>
      answer.future;
}

void main() {
  test('asynchronous permission cancellation becomes a denial', () async {
    final calls = Invocations();
    final host = _PendingHost();
    addTearDown(calls.dispose);
    addTearDown(host.dispose);
    final call = calls.create(
        component: const ComponentInfo('agent', 'Agent'),
        conversationId: 'conversation');
    final wrapped = InvocationHost(host, call);
    final response = wrapped.askPermission(const PermissionPrompt('bash', {}));
    final checked =
        expectLater(response, completion(PermissionResponse.denyOnce));

    host.answer.completeError(const InvocationCancelled('Prompt cancelled'));

    await checked;
  });
}
