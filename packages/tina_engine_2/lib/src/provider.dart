/// The provider interface and the scripted provider used by the tests.
library;

import 'dart:collection';

import 'model.dart';

/// The model boundary. Tiny on purpose: one method. The loop takes whatever
/// implements it; real HTTP providers live outside this package.
abstract class Provider {
  Future<ProviderResponse> call(Request request);
}

/// One provider reply: the reply text plus the tool calls it asks for.
final class ProviderResponse {
  const ProviderResponse({this.text = '', this.toolCalls = const []});

  final String text;
  final List<ToolCall> toolCalls;
}

/// Plays back a queue of scripted responses and records every request it
/// saw. No network. Tests assert on the recorded requests, which is how
/// pairing, pinning, ordering, and isolation get pinned.
final class ScriptedProvider implements Provider {
  ScriptedProvider(List<ProviderResponse> script)
      : _script = Queue.of(script);

  final Queue<ProviderResponse> _script;
  final List<Request> requests = [];

  /// How many requests the provider received.
  int get callCount => requests.length;

  @override
  Future<ProviderResponse> call(Request request) async {
    requests.add(request.snapshot());
    if (_script.isEmpty) {
      // A test that scripted too few turns still gets a well-formed reply
      // so the loop can end cleanly instead of throwing.
      return const ProviderResponse(text: '(script exhausted)');
    }
    return _script.removeFirst();
  }
}
