import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

void main() {
  const prompt = PermissionPrompt('bash', {'command': 'git status --porcelain'});

  test('accepts a valid draft that matches the target', () async {
    final provider = _ScriptedProvider('git (status --porcelain|diff)');
    final outcome = await RegexSuggester(provider).suggest(prompt);
    expect(outcome.isSuccess, isTrue);
    expect(outcome.rule!.pattern, 'git (status --porcelain|diff)');
    expect(outcome.rule!.isRegex, isTrue);
    // The constructed rule really matches the approval target.
    expect(outcome.rule!.matches(prompt.target), isTrue);
  });

  test('rejects a valid pattern that only partially covers the target', () async {
    // `git status` is a prefix of the target but does not consume it; the
    // engine's end-of-input assertion must reject it.
    final outcome = await RegexSuggester(
      _ScriptedProvider('git (status|diff)'),
    ).suggest(prompt);
    expect(outcome.isSuccess, isFalse);
    expect(outcome.failure, RegexSuggestionFailure.invalid);
  });

  test('rejects a draft that does not match the approval target', () async {
    final outcome = await RegexSuggester(
      _ScriptedProvider('git push --force'),
    ).suggest(prompt);
    expect(outcome.isSuccess, isFalse);
    expect(outcome.failure, RegexSuggestionFailure.invalid);
  });

  test('rejects prose around the pattern instead of passing it through', () async {
    final outcome = await RegexSuggester(
      _ScriptedProvider('Sure! Here is your regex: git (status|diff)'),
    ).suggest(prompt);
    expect(outcome.isSuccess, isFalse);
    expect(outcome.failure, RegexSuggestionFailure.invalid);
  });

  test('rejects an empty answer', () async {
    final outcome = await RegexSuggester(_ScriptedProvider('')).suggest(prompt);
    expect(outcome.failure, RegexSuggestionFailure.invalid);
  });

  test('rejects a pattern containing raw control characters', () async {
    final outcome = await RegexSuggester(
      _ScriptedProvider('git status\x1b[31m'),
    ).suggest(prompt);
    expect(outcome.failure, RegexSuggestionFailure.invalid);
  });

  test('stream errors become streamError, never a throw', () async {
    final outcome = await RegexSuggester(_ThrowingProvider()).suggest(prompt);
    expect(outcome.isSuccess, isFalse);
    expect(outcome.failure, RegexSuggestionFailure.streamError);
  });

  test('a hung provider times out', () async {
    final outcome = await RegexSuggester(
      _NeverCompletingProvider(),
      timeout: const Duration(milliseconds: 40),
    ).suggest(prompt);
    expect(outcome.failure, RegexSuggestionFailure.timeout);
  });

  test('cancelSignal beats a pending draft', () async {
    final cancelled = Completer<void>();
    final pending = RegexSuggester(_NeverCompletingProvider()).suggest(
        PermissionPrompt(prompt.toolName, prompt.input,
            cancelSignal: cancelled.future));
    // The suggester subscribes to the signal before its first await, so
    // completing now is deterministic — no reliance on the 30s default.
    cancelled.complete();
    final outcome = await pending;
    expect(outcome.failure, RegexSuggestionFailure.cancelled);
  });

  test('the request carries the tool and target, no tools attached', () async {
    final calls = <Map<String, dynamic>>[];
    await RegexSuggester(_ScriptedProvider('git status', calls: calls))
        .suggest(prompt);
    expect(calls, hasLength(1));
    expect(calls.single['tools'], isEmpty);
    final system = calls.single['system'] as String;
    expect(system, contains('ONLY'));
    final user = (calls.single['messages'] as List).single['content'].toString();
    expect(user, contains('bash'));
    expect(user, contains('git status --porcelain'));
  });
}

class _ScriptedProvider extends LlmProvider {
  final String _answer;
  final void Function()? onRequest;
  final List<Map<String, dynamic>> calls;

  _ScriptedProvider(this._answer, {this.onRequest, List<Map<String, dynamic>>? calls})
      : calls = calls ?? [],
        super('scripted');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    calls.add({
      'system': system,
      'messages': messages.map((m) => m.toJson()).toList(),
      'tools': tools,
    });
    onRequest?.call();
    yield TextDelta(_answer);
  }
}

class _ThrowingProvider extends LlmProvider {
  _ThrowingProvider() : super('throwing');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    throw Exception('provider exploded');
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
