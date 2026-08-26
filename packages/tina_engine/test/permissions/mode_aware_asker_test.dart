import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('modeAwareAsker', () {
    final prompt = PermissionPrompt('bash', const {'command': 'ls'});

    test('non-auto mode passes straight through to the fallback', () async {
      final policy = PermissionPolicy(mode: PermissionMode.ask);
      final classifier =
          PermissionClassifier(_ScriptedProvider('ALLOW', calls: []));
      var fallbackCalls = 0;
      final asker = modeAwareAsker(
        policy: policy,
        classifier: classifier,
        fallback: (_) async {
          fallbackCalls++;
          return PermissionResponse.denyOnce;
        },
      );

      expect((await asker(prompt)).decision, PermissionDecision.deny);
      expect(fallbackCalls, 1);
      expect((classifier.provider as _ScriptedProvider).calls, isEmpty,
          reason: 'no LLM call outside auto mode');
    });

    test('auto + classifier allow returns allowAlways and notices', () async {
      final policy = PermissionPolicy(mode: PermissionMode.auto);
      final classifier = PermissionClassifier(_ScriptedProvider('ALLOW'));
      final notices = <String>[];
      final asker = modeAwareAsker(
        policy: policy,
        classifier: classifier,
        fallback: (_) async {
          fail('fallback must not run when the classifier decides');
        },
        notice: notices.add,
      );

      final resp = await asker(prompt);
      expect(resp.decision, PermissionDecision.allow);
      expect(resp, PermissionResponse.allowAlways,
          reason: 'a verdict is remembered like a manual a/d');
      expect(notices.single, contains('allowed by classifier'));
    });

    test('auto + classifier deny returns denyAlways and notices', () async {
      final policy = PermissionPolicy(mode: PermissionMode.auto);
      final classifier = PermissionClassifier(_ScriptedProvider('DENY'));
      final notices = <String>[];
      final asker = modeAwareAsker(
        policy: policy,
        classifier: classifier,
        fallback: (_) async => fail('fallback must not run'),
        notice: notices.add,
      );

      final resp = await asker(prompt);
      expect(resp.decision, PermissionDecision.deny);
      expect(resp, PermissionResponse.denyAlways,
          reason: 'a deny verdict is remembered like a manual d');
      expect(notices.single, contains('denied by classifier'));
    });

    test('auto + undecidable classifier falls back to the interactive ask',
        () async {
      final policy = PermissionPolicy(mode: PermissionMode.auto);
      final classifier = PermissionClassifier(_ScriptedProvider('garbage'));
      var fallbackCalls = 0;
      final asker = modeAwareAsker(
        policy: policy,
        classifier: classifier,
        fallback: (_) async {
          fallbackCalls++;
          return PermissionResponse.allowOnce;
        },
      );

      expect((await asker(prompt)).decision, PermissionDecision.allow);
      expect(fallbackCalls, 1);
    });

    test('switching the policy mode at runtime changes the path', () async {
      final policy = PermissionPolicy(mode: PermissionMode.ask);
      final classifier = PermissionClassifier(_ScriptedProvider('ALLOW'));
      var fallbackCalls = 0;
      final asker = modeAwareAsker(
        policy: policy,
        classifier: classifier,
        fallback: (_) async {
          fallbackCalls++;
          return PermissionResponse.denyOnce;
        },
      );

      await asker(prompt);
      policy.mode = PermissionMode.auto;
      final resp = await asker(prompt);
      expect(resp.decision, PermissionDecision.allow);
      expect(fallbackCalls, 1);
    });
  });
}

class _ScriptedProvider extends LlmProvider {
  final String _answer;
  final List<Map<String, dynamic>> calls;

  /// [calls] defaults to a fresh growable list so the double still records
  /// when the test doesn't need to read it.
  _ScriptedProvider(this._answer, {List<Map<String, dynamic>>? calls})
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
    });
    yield TextDelta(_answer);
  }
}
