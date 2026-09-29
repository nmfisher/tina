import 'package:classification/judgments.dart';
import 'package:classification/utterance.dart';
import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';

JudgmentResult answer(JudgmentRequest request, Map<String, double> scores) =>
    JudgmentResult.fromJson({
      'model': 'jev-latest',
      'usage': <String, Object?>{},
      'answers': {
        for (final id in request.questions.keys)
          id: {'type': 'noul', 'noul': scores[id] ?? 0.0},
      },
    }, request: request);

class Service implements JudgmentService {
  Service(this.scores);
  final List<Map<String, double>> scores;
  final requests = <JudgmentRequest>[];
  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) async {
    requests.add(request);
    return answer(request, scores[requests.length - 1]);
  }
}

void main() {
  for (final sample in [
    (
      intent: {'projectQuestion': .97},
      git: <String, double>{},
      type: IntentType.projectQuestion,
      commands: <String>[],
    ),
    (
      intent: {'agentInstruction': .98},
      git: {'push': .97, 'branch': .96, 'checkout': .95},
      type: IntentType.agentInstruction,
      commands: ['push', 'branch', 'checkout'],
    ),
    (
      intent: {'agentInstruction': .98},
      git: {'none': .99},
      type: IntentType.agentInstruction,
      commands: <String>[],
    ),
    (
      intent: {'neither': .99},
      git: <String, double>{},
      type: null,
      commands: <String>[],
    ),
    (
      intent: {'projectQuestion': .5, 'agentInstruction': .5},
      git: <String, double>{},
      type: IntentType.unclear,
      commands: <String>[],
    ),
  ]) {
    test('dependent stages: ${sample.type} / ${sample.commands}', () async {
      final service = Service([sample.intent, sample.git]);
      final result = await classifyUtterance(
        id: 'input',
        text: 'fixture input',
        history: [],
        service: service,
        budget: JudgmentRequestBudget(),
        cancellation: JudgmentCancellation(),
      );
      expect(result.intent.type, sample.type);
      expect(
        service.requests,
        hasLength(sample.type == IntentType.agentInstruction ? 2 : 1),
      );
      expect(result.git?.commands ?? [], sample.commands);
      if (sample.type != IntentType.agentInstruction)
        expect(result.git, isNull);
      if (result.git != null) expect(result.git!.unknown, false);
    });
  }

  test('ambiguous and contradictory Git scores stay unknown', () async {
    for (final scores in [
      {'push': .5},
      {'push': .99, 'none': .7},
      {'unknown': .7},
    ]) {
      final result = await classifyUtterance(
        id: 'input',
        text: 'do that',
        history: [],
        service: Service([
          {'agentInstruction': .99},
          scores,
        ]),
        budget: JudgmentRequestBudget(),
        cancellation: JudgmentCancellation(),
      );
      expect(result.git!.unknown, true);
      expect(result.git!.commands, isEmpty);
    }
  });

  test(
    'recent context is text-only; quotes and negation are identified as evidence',
    () async {
      final service = Service([
        {'projectQuestion': .99},
      ]);
      await classifyUtterance(
        id: 'input',
        text: 'What does git push do? Do not run it.',
        history: [
          Message(
            role: Role.assistant,
            content: [
              TextBlock('We discussed git push.'),
              ToolUseBlock(
                id: 'tool',
                name: 'bash',
                input: {'command': 'private-payload'},
              ),
            ],
          ),
        ],
        service: service,
        budget: JudgmentRequestBudget(),
        cancellation: JudgmentCancellation(),
      );
      final evidence = service.requests.single.state.value.toString();
      expect(evidence, contains('We discussed git push.'));
      expect(evidence, contains('Do not run it.'));
      expect(evidence, contains('negated requests'));
      expect(evidence, isNot(contains('private-payload')));
    },
  );

  test(
    'oversized input stays unclear without sending a partial request',
    () async {
      final service = Service([]);
      final result = await classifyUtterance(
        id: 'input',
        text: 'x' * 12001,
        history: [],
        service: service,
        budget: JudgmentRequestBudget(),
        cancellation: JudgmentCancellation(),
      );
      expect(result.intent.type, IntentType.unclear);
      expect(service.requests, isEmpty);
    },
  );
}
