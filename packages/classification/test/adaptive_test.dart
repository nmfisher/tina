import 'dart:async';
import 'package:classification/judgments.dart';
import 'package:classification/utterance.dart';
import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';
import 'utterance_test.dart' show answer;

JudgmentResult choose(
  JudgmentRequest request,
  String id, {
  double confidence = .99,
}) {
  final question = request.questions.values.single as ChoiceQuestion;
  final keys = question.criteria.keys;
  return JudgmentResult.fromJson({
    'model': 'fixture',
    'usage': {},
    'answers': {
      question.id: {
        'type': 'choice',
        'choice': id,
        'confidence': confidence,
        'probabilities': {for (final key in keys) key: key == id ? 1.0 : 0.0},
      },
    },
  }, request: request);
}

class Decisions implements JudgmentService {
  Decisions(this.decisions);
  final List<Object> decisions;
  final requests = <JudgmentRequest>[];
  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) async {
    final decision = decisions[requests.length];
    requests.add(request);
    if (decision is String) return choose(request, decision);
    if (decision is Map<String, double>) return answer(request, decision);
    return (decision as JudgmentResult Function(JudgmentRequest))(request);
  }
}

class Learner implements CategoryLearner {
  Learner(this.respond);
  final FutureOr<CategoryProposal> Function(
    CategoryQuestion,
    JudgmentCancellation,
  )
  respond;
  final questions = <CategoryQuestion>[];
  final inputs = <String>[];
  @override
  Future<CategoryProposal> propose({
    required CategoryQuestion question,
    required String input,
    required JudgmentCancellation cancellation,
  }) async {
    questions.add(question);
    inputs.add(input);
    return await respond(question, cancellation);
  }
}

InputCategory category(String id, {String? label}) => InputCategory(
  id: id,
  label: label ?? id,
  description: 'Requests or mentions $id.',
  question: 'Is the input about $id?',
);

Future<UtteranceClassification> run(
  Decisions service,
  InputCategoryStore store, {
  CategoryLearner? learner,
  JudgmentCancellation? cancellation,
  String text = 'hello',
  List<Message> history = const [],
  JudgmentRequestBudget? budget,
}) => classifyAdaptiveUtterance(
  id: 'input',
  text: text,
  history: history,
  service: service,
  store: store,
  learner: learner,
  cancellation: cancellation ?? JudgmentCancellation(),
  budget: budget ?? JudgmentRequestBudget(),
);

void main() {
  test(
    'Other adds a category/question, reclassifies, and reuses it on the next input',
    () async {
      final store = MemoryInputCategoryStore();
      final learner = Learner(
        (_, _) =>
            CategoryProposal.create(category('greeting', label: 'greeting')),
      );
      final service = Decisions(['other', 'greeting', 'greeting']);
      final first = await run(service, store, learner: learner);
      expect(first.label, 'greeting');
      expect(first.intent.categoryId, 'greeting');
      expect(first.git, isNull);
      final old = service.requests[0].questions['intent'] as ChoiceQuestion;
      final expanded =
          service.requests[1].questions['intent'] as ChoiceQuestion;
      expect(old.criteria.keys, [
        'projectQuestion',
        'agentInstruction',
        'other',
      ]);
      expect(expanded.criteria.keys, [
        'projectQuestion',
        'agentInstruction',
        'greeting',
        'other',
      ]);
      expect(expanded.criteria['greeting'], {
        'label': 'greeting',
        'question': 'Is the input about greeting?',
      });
      expect((await run(service, store, learner: learner)).label, 'greeting');
      expect(learner.questions, hasLength(1));
      final root = (await store.read()).first;
      expect(root.otherSelections, 1);
      expect(root.category('greeting')!.selections, 2);
      expect(root.category('projectQuestion')!.selections, 0);
    },
  );

  test(
    'unlisted Git commands also expand and preserve multiple operations',
    () async {
      final store = MemoryInputCategoryStore();
      final learner = Learner((q, _) {
        expect(q.id, 'git');
        return CategoryProposal.create(category('blame'));
      });
      final service = Decisions([
        'agentInstruction',
        {'push': .98, 'other': .99},
        {'push': .98, 'blame': .99},
      ]);
      final result = await run(
        service,
        store,
        learner: learner,
        text: 'push then git blame',
      );
      expect(result.git!.commands, ['push', 'blame']);
      final git = (await store.read()).last;
      expect(git.otherSelections, 1);
      expect(git.category('blame')!.selections, 1);
      expect(
        git.category('push')!.selections,
        2,
        reason: 'two validated classifier decisions selected push',
      );
      expect(
        service.requests.last.questions['blame']!.instructions!.value,
        'Is the input about blame?',
      );
    },
  );

  test(
    'existing proposal reclassifies without inserting a duplicate',
    () async {
      final store = MemoryInputCategoryStore();
      final learner = Learner(
        (_, _) => const CategoryProposal.existing('projectQuestion'),
      );
      final result = await run(
        Decisions(['other', 'projectQuestion']),
        store,
        learner: learner,
      );
      expect(result.intent.type, IntentType.projectQuestion);
      expect((await store.read()).first.categories, hasLength(2));
      expect(
        (await store.read()).first.category('projectQuestion')!.selections,
        1,
      );
    },
  );

  test(
    'only one discovery per question, even if the retry remains Other',
    () async {
      final store = MemoryInputCategoryStore();
      final learner = Learner(
        (_, _) => CategoryProposal.create(category('greeting')),
      );
      final result = await run(
        Decisions(['other', 'other']),
        store,
        learner: learner,
      );
      expect(result.label, 'other');
      expect(learner.questions, hasLength(1));
      expect((await store.read()).first.otherSelections, 2);
      expect((await store.read()).first.category('greeting')!.selections, 0);
    },
  );

  test(
    'at 254 named categories Other remains available and discovery stops',
    () async {
      final store = MemoryInputCategoryStore([
        CategoryQuestion(
          id: 'intent',
          question: 'Classify the input.',
          categories: [for (var i = 0; i < 254; i++) category('c$i')],
        ),
        initialCategoryQuestions().last,
      ]);
      final learner = Learner(
        (_, _) => throw StateError('must not discover at capacity'),
      );
      final service = Decisions(['other']);
      final result = await run(
        service,
        store,
        learner: learner,
        budget: JudgmentRequestBudget(maxInputTokens: 100000),
      );
      expect(result.label, 'other');
      expect(learner.questions, isEmpty);
      expect(
        (service.requests.single.questions['intent'] as ChoiceQuestion)
            .criteria,
        hasLength(255),
      );
      expect((await store.read()).first.categories, hasLength(254));
    },
  );

  test('failed or invalid discovery preserves Other and its count', () async {
    for (final invalid in [false, true]) {
      final store = MemoryInputCategoryStore();
      final learner = Learner((_, _) {
        if (invalid) return const CategoryProposal.existing('not-in-the-list');
        throw StateError('private provider diagnostic');
      });
      final result = await run(Decisions(['other']), store, learner: learner);
      expect(result.label, 'other · learning unavailable');
      expect((await store.read()).first.otherSelections, 1);
      expect((await store.read()).first.categories, hasLength(2));
    }
  });

  test('cancelled or late discovery cannot admit a category', () async {
    final store = MemoryInputCategoryStore();
    final cancellation = JudgmentCancellation();
    final learner = Learner((_, token) {
      token.cancel();
      return CategoryProposal.create(category('greeting'));
    });
    await expectLater(
      run(
        Decisions(['other']),
        store,
        learner: learner,
        cancellation: cancellation,
      ),
      throwsA(
        isA<JudgmentException>().having(
          (e) => e.failure,
          'failure',
          JudgmentFailure.cancelled,
        ),
      ),
    );
    expect((await store.read()).first.categories, hasLength(2));
  });

  test('low confidence does not train or count an uncertain choice', () async {
    final store = MemoryInputCategoryStore();
    final learner = Learner((_, _) => throw StateError('must not train'));
    final result = await run(
      Decisions([(JudgmentRequest r) => choose(r, 'other', confidence: .4)]),
      store,
      learner: learner,
    );
    expect(result.intent.type, IntentType.unclear);
    expect(learner.questions, isEmpty);
    expect((await store.read()).first.otherSelections, 0);
  });

  test(
    'oversized requests never drop vocabulary or train on partial input',
    () async {
      final store = MemoryInputCategoryStore();
      final service = Decisions([]);
      expect(
        (await run(service, store, text: 'x' * 12001)).intent.type,
        IntentType.unclear,
      );
      await expectLater(
        run(
          service,
          store,
          text: 'hello',
          budget: JudgmentRequestBudget(maxInputTokens: 1025),
        ),
        throwsA(
          isA<JudgmentException>().having(
            (e) => e.failure,
            'failure',
            JudgmentFailure.requestTooLarge,
          ),
        ),
      );
      expect(service.requests, isEmpty);
      expect((await store.read()).first.otherSelections, 0);
    },
  );
}
