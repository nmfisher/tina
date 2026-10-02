import 'dart:async';
import 'dart:convert';
import 'package:classification/judgments.dart';
import 'package:classification/utterance.dart';
import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';

class Provider extends LlmProvider implements StructuredOutputProvider {
  Provider(this.events) : super('active-model');
  final Stream<StreamEvent> events;
  bool closed = false;
  String? system;
  List<Message>? messages;
  JsonOutputSchema? output;
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) => throw StateError('must use structured generation');
  @override
  Stream<StreamEvent> sendStructured({
    required String system,
    required List<Message> messages,
    required JsonOutputSchema output,
  }) {
    this.system = system;
    this.messages = messages;
    this.output = output;
    return events;
  }

  @override
  void close() => closed = true;
}

class PlainProvider extends LlmProvider {
  PlainProvider() : super('plain-model');
  List<ToolSchema>? requestedTools;
  bool closed = false;
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    requestedTools = tools;
    return complete('{"existing_category":"projectQuestion","category":null}');
  }

  @override
  void close() => closed = true;
}

Stream<StreamEvent> complete(String text, {String stop = 'end_turn'}) =>
    Stream.value(MessageComplete(content: [TextBlock(text)], stopReason: stop));

const proposal =
    '{"existing_category":null,"category":{'
    '"id":"greeting","label":"greeting","description":"A conversational greeting.",'
    '"question":"Is the latest input a greeting?"}}';

void main() {
  test(
    'uses the active model in a fresh one-message context and closes its own client',
    () async {
      final provider = Provider(complete(proposal));
      final learner = MainAgentCategoryLearner(() => provider);
      final result = await learner.propose(
        question: initialCategoryQuestions().first,
        input: 'hello',
        cancellation: JudgmentCancellation(),
      );
      expect(result.category!.id, 'greeting');
      expect(result.category!.selections, 0);
      expect(provider.messages, hasLength(1));
      expect(provider.messages!.single.role, Role.user);
      final evidence =
          jsonDecode(
                (provider.messages!.single.content.single as TextBlock).text,
              )
              as Map;
      expect(evidence.keys, ['question', 'existing_categories', 'input']);
      expect(evidence['input'], 'hello');
      expect(provider.system, contains('Do not carry out the task'));
      expect(provider.output!.name, 'input_category_proposal');
      expect(provider.output!.schema['additionalProperties'], false);
      expect(provider.closed, true);
    },
  );

  test(
    'models without constrained generation still get no tools and are validated',
    () async {
      final provider = PlainProvider();
      final result = await MainAgentCategoryLearner(() => provider).propose(
        question: initialCategoryQuestions().first,
        input: 'what is the project?',
        cancellation: JudgmentCancellation(),
      );
      expect(result.existingId, 'projectQuestion');
      expect(provider.requestedTools, isEmpty);
      expect(provider.closed, true);
    },
  );

  for (final value in [
    'not json',
    '{}',
    '{"existing_category":null,"category":null}',
    '{"existing_category":"projectQuestion","category":{}}',
    '{"existing_category":"projectQuestion","category":null,"extra":"ignore"}',
    proposal.replaceFirst('"greeting"', '"other"'),
  ]) {
    test('invalid proposal cannot become a definition: $value', () async {
      final provider = Provider(complete(value));
      await expectLater(
        MainAgentCategoryLearner(() => provider).propose(
          question: initialCategoryQuestions().first,
          input: 'hello',
          cancellation: JudgmentCancellation(),
        ),
        throwsA(
          isA<JudgmentException>().having(
            (e) => e.failure,
            'failure',
            JudgmentFailure.invalidResponse,
          ),
        ),
      );
      expect(provider.closed, true);
    });
  }

  test(
    'truncated and tool-call responses cannot train the vocabulary',
    () async {
      for (final events in [
        complete(proposal, stop: 'max_tokens'),
        Stream<StreamEvent>.value(const ToolCallStart(id: 'x', name: 'write')),
        Stream<StreamEvent>.empty(),
      ]) {
        final provider = Provider(events);
        await expectLater(
          MainAgentCategoryLearner(() => provider).propose(
            question: initialCategoryQuestions().first,
            input: 'hello',
            cancellation: JudgmentCancellation(),
          ),
          throwsA(isA<JudgmentException>()),
        );
        expect(provider.closed, true);
      }
    },
  );

  test(
    'cancellation closes a pending fresh request and never closes the main turn client',
    () async {
      final controller = StreamController<StreamEvent>();
      final provider = Provider(controller.stream);
      final mainTurn = PlainProvider();
      final token = JudgmentCancellation();
      final result = MainAgentCategoryLearner(() => provider).propose(
        question: initialCategoryQuestions().first,
        input: 'hello',
        cancellation: token,
      );
      final check = expectLater(
        result,
        throwsA(
          isA<JudgmentException>().having(
            (e) => e.failure,
            'failure',
            JudgmentFailure.cancelled,
          ),
        ),
      );
      token.cancel();
      await check;
      expect(provider.closed, true);
      expect(mainTurn.closed, false);
      await controller.close();
    },
  );

  test('a timeout releases the separate client', () async {
    final controller = StreamController<StreamEvent>();
    final provider = Provider(controller.stream);
    await expectLater(
      MainAgentCategoryLearner(
        () => provider,
        timeout: const Duration(milliseconds: 10),
      ).propose(
        question: initialCategoryQuestions().first,
        input: 'hello',
        cancellation: JudgmentCancellation(),
      ),
      throwsA(
        isA<JudgmentException>().having(
          (e) => e.failure,
          'failure',
          JudgmentFailure.timeout,
        ),
      ),
    );
    expect(provider.closed, true);
    await controller.close();
  });
}
