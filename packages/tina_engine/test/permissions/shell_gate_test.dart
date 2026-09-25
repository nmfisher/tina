import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('read-all bash routing (classifier gate)', () {
    final safe = <String, dynamic>{'command': 'grep -rn TODO lib | head -20'};
    final rm = <String, dynamic>{'command': 'rm -rf /'};
    final npmTest = <String, dynamic>{'command': 'npm test'};

    PermissionPolicy routed({bool yolo = false}) => PermissionPolicy(
          mode: PermissionMode.readAll,
          classifierGatesShell: true,
          allowAllByDefault: yolo,
        );

    test('flag off: the original hard block applies to every bash', () {
      final p = PermissionPolicy(mode: PermissionMode.readAll);
      expect(p.classifierGatesShell, isFalse);
      expect(p.executionBlock('bash', safe), isNotNull);
      expect(p.check('bash', safe), PermissionDecision.deny);
      expect(p.check('bash', rm), PermissionDecision.deny);
    });

    test('flag on: executionBlock routes bash and nothing else', () {
      final p = routed();
      expect(p.executionBlock('bash', safe), isNull);
      expect(p.executionBlock('bash', rm), isNull,
          reason: 'the route, not a block — the gate downstream decides');
      expect(p.executionBlock('exec', {'executable': 'rm', 'arguments': []}),
          isNotNull,
          reason: 'exec has no route; argv-shaped execution stays blocked');
      expect(
          p.executionBlock('write', {'path': 'x', 'content': ''}), isNotNull);
      expect(
          p.executionBlock('delegate', const {
            'delegations': [
              {'task': 'x', 'tools': 'full'}
            ],
          }),
          isNotNull);
    });

    test('a statically read-only command allows with no classifier round-trip',
        () {
      final p = routed();
      expect(p.check('bash', {'command': 'cat notes.md'}),
          PermissionDecision.allow);
      expect(p.check('bash', safe), PermissionDecision.allow);
      expect(p.check('bash', {'command': 'find . -name "*.dart"'}),
          PermissionDecision.allow);
    });

    test(
        'anything not provable surfaces ask — the gate decides, not the policy',
        () {
      final p = routed();
      expect(p.check('bash', rm), PermissionDecision.ask);
      expect(p.check('bash', npmTest), PermissionDecision.ask);
      expect(p.check('bash', {'command': 'sed -i s/a/b/ f'}),
          PermissionDecision.ask);
      expect(p.check('bash', {'command': 'cat a > b'}), PermissionDecision.ask);
    });

    test('--yolo cannot widen routed bash past the gate', () {
      final p = routed(yolo: true);
      expect(p.check('bash', rm), PermissionDecision.ask,
          reason: 'plain d would be allow here; the route must not inherit it');
      expect(p.check('bash', {'command': 'cat x'}), PermissionDecision.allow);
      // Flag off keeps today's yolo+read-all posture: still blocked.
      final q = PermissionPolicy(
          mode: PermissionMode.readAll, allowAllByDefault: true);
      expect(q.check('bash', {'command': 'cat x'}), PermissionDecision.deny);
    });

    test('an explicit deny still beats a statically safe command', () {
      final p = PermissionPolicy(
        mode: PermissionMode.readAll,
        classifierGatesShell: true,
        rules: [
          PermissionRule(
              toolName: 'bash',
              pattern: '*',
              decision: PermissionDecision.deny),
        ],
      );
      expect(p.check('bash', {'command': 'cat x'}), PermissionDecision.deny);
    });

    test('a remembered verdict short-circuits before the gate — free repeats',
        () {
      final p = routed();
      p.remember('bash', 'npm test', PermissionDecision.allow);
      expect(p.check('bash', npmTest), PermissionDecision.allow);
      p.remember('bash', 'rm -rf /', PermissionDecision.deny);
      expect(p.check('bash', rm), PermissionDecision.deny);
    });

    test('a custom environment never takes the static path', () {
      final p = routed();
      expect(
          p.check('bash', const {
            'command': 'cat x',
            'environment': {'PATH': '/tmp/evil'},
          }),
          PermissionDecision.ask);
    });

    test('the flag is inert outside read-all', () {
      final p = PermissionPolicy(
          mode: PermissionMode.ask, classifierGatesShell: true);
      expect(p.executionBlock('bash', rm), isNull); // mode gate comes first
      expect(p.check('bash', rm), PermissionDecision.ask); // plain ask, as ever
    });

    test('a copied policy spreads the flag with modeSource, like yolo', () {
      final parent = routed();
      final child = PermissionPolicy(
        modeSource: parent,
        allowAllByDefault: parent.allowAllByDefault,
        classifierGatesShell: parent.classifierGatesShell,
      );
      expect(child.mode, PermissionMode.readAll);
      expect(
          child.check('bash', {'command': 'cat x'}), PermissionDecision.allow);
      expect(child.check('bash', rm), PermissionDecision.ask);
    });
  });

  group('read-all + gate, end to end through the asker', () {
    test('check→ask→classifier failure denies without ever prompting',
        () async {
      // Composition order: the wrapper is built first (arming the policy's
      // route), then calls are checked.
      final policy = PermissionPolicy(mode: PermissionMode.readAll);
      var fallbackCalls = 0;
      final asker = modeAwareAsker(
        policy: policy,
        classifier: PermissionClassifier(_UnclearProvider()),
        fallback: (_) async {
          fallbackCalls++;
          return PermissionResponse.allowOnce;
        },
      );
      expect(policy.classifierGatesShell, isTrue,
          reason: 'wrapping is what arms the route');

      expect(policy.check('bash', const {'command': 'rm -rf /'}),
          PermissionDecision.ask);
      final resp =
          await asker(PermissionPrompt('bash', const {'command': 'rm -rf /'}));
      expect(resp.decision, PermissionDecision.deny);
      expect(fallbackCalls, 0,
          reason: 'read-all promised no prompts; the failure stays closed');
    });

    test('a statically allowed reader never reaches the asker at all', () {
      final policy = PermissionPolicy(mode: PermissionMode.readAll);
      final asker = modeAwareAsker(
        policy: policy,
        classifier: PermissionClassifier(_UnclearProvider()),
        fallback: (_) async =>
            fail('the static fast path owes the judge nothing'),
      );
      expect(policy.check('bash', const {'command': 'cat notes.md'}),
          PermissionDecision.allow,
          reason: 'no ask is produced, so the asker cannot be reached');
      expect(asker, isNotNull);
    });
  });
}

/// Answers garbage so the judge has no verdict — the fail-closed path.
class _UnclearProvider extends LlmProvider {
  _UnclearProvider() : super('unclear');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    yield TextDelta('unclear');
  }
}
