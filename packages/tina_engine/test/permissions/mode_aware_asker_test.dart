import 'dart:async';
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

    test('auto mode always sends directory grants to the human asker',
        () async {
      final provider = _ScriptedProvider('ALLOW');
      final request = PermissionPrompt('bash', const {'command': 'dart test'},
          sandboxAccess:
              SandboxAccessRequest(['/sdk/cache'], 'launcher metadata'));
      var fallbackCalls = 0;
      final asker = modeAwareAsker(
        policy: PermissionPolicy(mode: PermissionMode.auto),
        classifier: PermissionClassifier(provider),
        fallback: (p) async {
          expect(p, same(request));
          fallbackCalls++;
          return PermissionResponse.denyOnce;
        },
      );
      expect((await asker(request)).decision, PermissionDecision.deny);
      expect(fallbackCalls, 1);
      expect(provider.calls, isEmpty);
    });

    for (final answer in ['ALLOW', 'DENY', 'unclear']) {
      test('auto mode classifies outside-sandbox retry: $answer', () async {
        final provider = _ScriptedProvider(answer);
        final request = PermissionPrompt('bash', const {'command': 'dart test'},
            outsideSandbox: true, sandboxNetworkIsolated: true,
            retryExplanation: 'SDK cache is read-only',
            execution: ExecutionRequest(executable: '/bin/sh', arguments: ['-c', 'dart test'],
              workingDirectory: '/project', environment: {'SECRET': 'ambient-secret'},
              environmentOverrides: {}, writablePaths: [], timeoutSeconds: 60, shell: true));
        var fallbackCalls = 0;
        final notices = <String>[];
        final asker = modeAwareAsker(
          policy: PermissionPolicy(mode: PermissionMode.auto),
          classifier: PermissionClassifier(provider),
          fallback: (p) async {
            expect(p, same(request));
            fallbackCalls++;
            return PermissionResponse.denyOnce;
          }, notice: notices.add,
        );
        final response = await asker(request);
        expect(response.decision, answer == 'ALLOW' ? PermissionDecision.allow : PermissionDecision.deny);
        expect(fallbackCalls, answer == 'unclear' ? 1 : 0);
        expect(response.remember, answer != 'unclear');
        if (answer != 'unclear') {
          expect(response.decidedBy, 'classifier');
          expect(notices.single, contains('outside sandbox'));
        }
        final sent = provider.calls.single['messages'].toString();
        expect(sent, contains('"outsideSandbox":true'));
        expect(sent, contains('"removesNetworkIsolation":true'));
        expect(sent, contains('SDK cache is read-only'));
        expect(sent, contains('/project'));
        expect(sent, isNot(contains('ambient-secret')));
      });
    }

    test('cancelling a classifier request cannot open a late approval dialog', () async {
      final cancel = Completer<void>();
      final provider = _ScriptedProvider('ALLOW', onRequest: cancel.complete);
      final asker = modeAwareAsker(policy: PermissionPolicy(mode: PermissionMode.auto),
        classifier: PermissionClassifier(provider),
        fallback: (_) async => fail('cancelled request must not open a dialog'));
      final response = await asker(PermissionPrompt('bash', const {'command': 'dart test'},
        outsideSandbox: true, cancelSignal: cancel.future));
      expect(response.decision, PermissionDecision.deny);
      expect(response.remember, isFalse);
    });

    test('leaving auto mode during classification requires the human answer', () async {
      final policy = PermissionPolicy(mode: PermissionMode.auto);
      final provider = _ScriptedProvider('ALLOW', onRequest: () => policy.mode = PermissionMode.ask);
      var asked = false;
      final asker = modeAwareAsker(policy: policy, classifier: PermissionClassifier(provider),
        fallback: (_) async { asked = true; return PermissionResponse.denyOnce; });
      final response = await asker(PermissionPrompt('bash', const {'command': 'dart test'}, outsideSandbox: true));
      expect(asked, isTrue);
      expect(response.decision, PermissionDecision.deny);
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
      expect(resp.remember, isTrue,
          reason: 'a verdict is remembered like a manual a/d');
      expect(resp.decidedBy, 'classifier',
          reason: 'the approval audit line must show this grant came from the '
              'classifier, not from the user');
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
      expect(resp.remember, isTrue,
          reason: 'a deny verdict is remembered like a manual d');
      expect(resp.decidedBy, 'classifier');
      expect(notices.single, contains('denied by classifier'));
    });

    test('auto + undecidable classifier falls back to the interactive ask',
        () async {
      final policy = PermissionPolicy(mode: PermissionMode.auto);
      final classifier = PermissionClassifier(_ScriptedProvider('garbage'));
      var fallbackCalls = 0;
      final notices = <String>[];
      final asker = modeAwareAsker(
        policy: policy,
        classifier: classifier,
        fallback: (_) async {
          fallbackCalls++;
          return PermissionResponse.allowOnce;
        },
        notice: notices.add,
      );

      expect((await asker(prompt)).decision, PermissionDecision.allow);
      expect(fallbackCalls, 1);
      expect(notices.single, contains('returned an unreadable answer'),
          reason: 'the fallback is announced, not silent');
      expect(notices.single, contains('bash classifier'));
    });

    test('a classifier timeout is announced before the fallback ask',
        () async {
      final policy = PermissionPolicy(mode: PermissionMode.auto);
      final classifier = PermissionClassifier(
        _NeverCompletingProvider(),
        timeout: const Duration(milliseconds: 20),
      );
      final notices = <String>[];
      final asker = modeAwareAsker(
        policy: policy,
        classifier: classifier,
        fallback: (_) async => PermissionResponse.allowOnce,
        notice: notices.add,
      );

      expect((await asker(prompt)).decision, PermissionDecision.allow);
      expect(notices.single, contains('timed out after 20ms'),
          reason: 'the notice names the configured timeout');
      expect(notices.single, contains('bash classifier'));
      expect(notices.single, contains(prompt.key));
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

  group('modeAwareAsker — read-all (the fail-closed twin of auto)', () {
    final prompt = PermissionPrompt('bash', const {'command': 'npm test'});

    test('wrapping sets the policy flag the route depends on', () {
      final policy = PermissionPolicy(mode: PermissionMode.readAll);
      expect(policy.classifierGatesShell, isFalse);
      modeAwareAsker(
        policy: policy,
        classifier: PermissionClassifier(_ScriptedProvider('DENY')),
        fallback: (_) async => PermissionResponse.denyOnce,
      );
      expect(policy.classifierGatesShell, isTrue,
          reason: 'the wrapper IS the gate executionBlock routes bash to');
    });

    test('allow verdict runs the command and is remembered like a manual a',
        () async {
      final notices = <String>[];
      final asker = modeAwareAsker(
        policy: PermissionPolicy(mode: PermissionMode.readAll),
        classifier: PermissionClassifier(_ScriptedProvider('ALLOW')),
        fallback: (_) async =>
            fail('read-all must never fall back to the prompt'),
        notice: notices.add,
      );

      final resp = await asker(prompt);
      expect(resp.decision, PermissionDecision.allow);
      expect(resp.remember, isTrue,
          reason: 'so an identical repeat short-circuits the rule cascade');
      expect(resp.decidedBy, 'classifier');
      expect(notices.single, contains('allowed by classifier'));
    });

    test('deny verdict denies, remembered like a manual d', () async {
      final notices = <String>[];
      final asker = modeAwareAsker(
        policy: PermissionPolicy(mode: PermissionMode.readAll),
        classifier: PermissionClassifier(_ScriptedProvider('DENY')),
        fallback: (_) async => fail('must not prompt'),
        notice: notices.add,
      );

      final resp = await asker(prompt);
      expect(resp.decision, PermissionDecision.deny);
      expect(resp.remember, isTrue);
      expect(resp.decidedBy, 'classifier');
      expect(notices.single, contains('denied by classifier'));
    });

    test('an undecidable classifier DENIES without prompting — auto would '
        'have asked instead', () async {
      var fallbackCalls = 0;
      final notices = <String>[];
      final asker = modeAwareAsker(
        policy: PermissionPolicy(mode: PermissionMode.readAll),
        classifier: PermissionClassifier(_ScriptedProvider('unclear')),
        fallback: (_) async {
          fallbackCalls++;
          return PermissionResponse.allowOnce;
        },
        notice: notices.add,
      );

      final resp = await asker(prompt);
      expect(resp.decision, PermissionDecision.deny);
      expect(resp.remember, isFalse);
      expect(fallbackCalls, 0,
          reason: 'a prompt in read-all is the bug this branch exists to '
              'prevent');
      expect(notices.single, contains('returned an unreadable answer'));
      expect(notices.single, contains('read-only stays closed'));
      expect(notices.single, contains(prompt.key));
    });

    test('a classifier timeout denies without prompting', () async {
      var fallbackCalls = 0;
      final notices = <String>[];
      final asker = modeAwareAsker(
        policy: PermissionPolicy(mode: PermissionMode.readAll),
        classifier: PermissionClassifier(_NeverCompletingProvider(),
            timeout: const Duration(milliseconds: 20)),
        fallback: (_) async {
          fallbackCalls++;
          return PermissionResponse.allowOnce;
        },
        notice: notices.add,
      );

      final resp = await asker(prompt);
      expect(resp.decision, PermissionDecision.deny);
      expect(fallbackCalls, 0);
      expect(notices.single, contains('timed out after 20ms'));
      expect(notices.single, contains('read-only stays closed'));
    });

    test('the judge is told the session is read-only', () async {
      final provider = _ScriptedProvider('DENY');
      final asker = modeAwareAsker(
        policy: PermissionPolicy(mode: PermissionMode.readAll),
        classifier: PermissionClassifier(provider),
        fallback: (_) async => fail('must not prompt'),
      );
      await asker(prompt);
      expect(provider.calls.single['system'], contains('READ-ONLY mode'));
      expect(provider.calls.single['system'], contains('When uncertain, DENY'));
    });

    test('auto mode keeps the base prompt with no read-only directive',
        () async {
      final provider = _ScriptedProvider('DENY');
      final asker = modeAwareAsker(
        policy: PermissionPolicy(mode: PermissionMode.auto),
        classifier: PermissionClassifier(provider),
        fallback: (_) async => fail('verdict expected'),
      );
      await asker(prompt);
      expect(provider.calls.single['system'],
          isNot(contains('READ-ONLY mode')));
    });

    test('outside-sandbox access cannot be granted in read-all', () async {
      final provider = _ScriptedProvider('ALLOW');
      var fallbackCalls = 0;
      final notices = <String>[];
      final asker = modeAwareAsker(
        policy: PermissionPolicy(mode: PermissionMode.readAll),
        classifier: PermissionClassifier(provider),
        fallback: (_) async {
          fallbackCalls++;
          return PermissionResponse.allowOnce;
        },
        notice: notices.add,
      );

      final resp = await asker(PermissionPrompt(
          'bash', const {'command': 'dart test'},
          sandboxAccess:
              SandboxAccessRequest(['/sdk/cache'], 'launcher metadata')));
      expect(resp.decision, PermissionDecision.deny);
      expect(fallbackCalls, 0);
      expect(provider.calls, isEmpty,
          reason: 'the mode denies outright; the judge is not consulted');
      expect(notices.single, contains('read-only mode'));
    });

    test('leaving read-all mid-classification hands back to the human',
        () async {
      final policy = PermissionPolicy(mode: PermissionMode.readAll);
      final provider = _ScriptedProvider('ALLOW',
          onRequest: () => policy.mode = PermissionMode.ask);
      var asked = false;
      final asker = modeAwareAsker(
        policy: policy,
        classifier: PermissionClassifier(provider),
        fallback: (_) async {
          asked = true;
          return PermissionResponse.denyOnce;
        },
      );
      final resp = await asker(prompt);
      expect(asked, isTrue,
          reason: 'the user just re-enabled asking; honor it');
      expect(resp.decision, PermissionDecision.deny);
    });
  });

}

class _ScriptedProvider extends LlmProvider {
  final String _answer;
  final void Function()? onRequest;
  final List<Map<String, dynamic>> calls;

  /// [calls] defaults to a fresh growable list so the double still records
  /// when the test doesn't need to read it.
  _ScriptedProvider(this._answer, {List<Map<String, dynamic>>? calls, this.onRequest})
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
    onRequest?.call();
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
