import 'dart:async';
import 'dart:convert';
import 'package:classification/plugin.dart';
import 'package:classification/judgments.dart';
import 'package:classification/typesafe_classifier.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:tina_core/tina_core.dart';
import 'plugin_test.dart' show Pending, Output, input, pump;
import 'category_learner_test.dart' show Provider, proposal;
import 'typesafe_service_test.dart' show TestClient;

void main() {
  test(
    'bounded history/payloads and cancelled exchanges reject late data',
    () async {
      final trace = ClassificationTrace(capacity: 2, payloadLimit: 10);
      final first = trace.begin(inputId: 'one', title: 'one', request: 'first');
      first.append('12345678');
      first.append('abcdef');
      expect(first.response, '12345678ab\n[display truncated]');
      first.append('more');
      expect(first.response, '12345678ab\n[display truncated]');
      trace.cancelPending('one');
      first.receive('late');
      first.complete();
      expect(first.phase, ClassificationExchangePhase.cancelled);
      expect(first.response, contains('truncated'));
      trace.begin(inputId: 'two', title: 'two', request: 'second');
      trace.begin(inputId: 'three', title: 'three', request: 'third');
      expect(trace.exchanges.map((e) => e.inputId), ['two', 'three']);
      trace.close();
      trace.exchanges.last.complete('after close');
      expect(trace.exchanges.last.response, isEmpty);
    },
  );

  test(
    'live request is visible before the reply; stages and cancellation correlate',
    () async {
      final service = Pending();
      final plugin = ClassificationPlugin(
        terminal: Output(),
        open: () => ClassificationLease(
          service: service,
          budget: JudgmentRequestBudget(),
          close: () {},
        ),
      );
      addTearDown(plugin.closeSession);
      plugin.onInput(input('push the branch'));
      await pump();
      final intent = plugin.trace.exchanges.single;
      expect(intent.phase, ClassificationExchangePhase.pending);
      expect(
        jsonDecode(intent.request),
        service.requests.single.toJson(model: 'jev-latest'),
      );
      service.complete(0, {'agentInstruction': .99});
      await pump();
      expect(intent.phase, ClassificationExchangePhase.complete);
      final git = plugin.trace.exchanges.last;
      expect(git.parentId, intent.id);
      expect(git.title, 'Git operations');
      expect(intent.classifierId, 'intent');
      expect(intent.classifierName, 'Request type');
      expect(intent.trigger, isNull);
      expect(git.classifierId, 'git');
      expect(git.classifierName, 'Git actions');
      expect(git.trigger, 'Request type → Request to do work');
      expect(intent.outcome!.label, 'Request to do work');
      expect(git.outcome, isNull);
      plugin.onInput(input('new input'));
      await pump();
      expect(git.phase, ClassificationExchangePhase.cancelled);
      service.complete(1, {'push': .99});
      await pump();
      expect(git.response, isEmpty);
      expect(plugin.trace.exchanges.last.inputId, 'new input');
    },
  );

  test(
    'decoded outcomes stay with their run and cancelled runs reject late outcomes',
    () {
      final trace = ClassificationTrace();
      addTearDown(trace.close);
      final e = trace.begin(
        inputId: 'input',
        title: 'wire stage',
        request: {},
        classifierId: 'acme/arbitrary',
        classifierName: 'Project topic',
      );
      final revision = trace.revision;
      e.recordOutcome(const ClassificationOutcome('premature'));
      expect(e.outcome, isNull);
      expect(trace.revision, revision);
      e.complete();
      e.recordOutcome(const ClassificationOutcome('Unclear', unclear: true));
      expect(e.outcome!.label, 'Unclear');
      expect(e.outcome!.unclear, true);
      final cancelled = trace.begin(
        inputId: 'input',
        title: 'cancelled',
        request: {},
      );
      trace.cancelPending('input');
      cancelled.recordOutcome(const ClassificationOutcome('late'));
      expect(cancelled.outcome, isNull);
      trace.close();
      e.recordOutcome(const ClassificationOutcome('after close'));
      expect(e.outcome!.label, 'Unclear');
    },
  );

  test(
    'unrelated independent runs do not become Git dependencies; decoded outcomes survive new input',
    () async {
      final service = Pending();
      final plugin = ClassificationPlugin(
        terminal: Output(),
        open: () => ClassificationLease(
          service: service,
          budget: JudgmentRequestBudget(),
          close: () {},
        ),
      );
      addTearDown(plugin.closeSession);
      plugin.onInput(input('push the branch'));
      await pump();
      final intent = plugin.trace.exchanges.single;
      plugin.trace
          .begin(
            inputId: intent.inputId,
            title: 'Topic',
            request: {},
            classifierId: 'acme/topic',
            classifierName: 'Project topic',
          )
          .complete();
      service.complete(0, {'agentInstruction': .99});
      await pump();
      final git = plugin.trace.exchanges.last;
      expect(git.parentId, intent.id);
      service.complete(1, {'push': .99});
      await pump();
      expect(intent.outcome!.label, 'Request to do work');
      expect(git.outcome!.label, 'git push');
      plugin.onInput(input('new input'));
      await pump();
      expect(intent.outcome!.label, 'Request to do work');
      expect(git.outcome!.label, 'git push');
    },
  );

  test(
    'records actual HTTP response, including malformed JSON, without auth headers',
    () async {
      for (final body in [
        'not valid JSON',
        '{"model":"jev-fixture","answers":"malformed","usage":{}}',
      ]) {
        late Map sent;
        final service = TypeSafeJudgmentService(
          config: TypeSafeConfig(
            apiKey: 'private-fixture-key',
            model: 'jev-fixture',
          ),
          clientFactory: () => TestClient((request) async {
            sent = jsonDecode((request as http.Request).body) as Map;
            return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
          }),
        );
        final plugin = ClassificationPlugin(
          terminal: Output(),
          open: () => ClassificationLease(
            service: service,
            budget: service.config.requestBudget,
            close: service.close,
          ),
        );
        plugin.onInput(input('hello'));
        await pump();
        final exchange = plugin.trace.exchanges.single;
        expect(jsonDecode(exchange.request), sent);
        expect(exchange.response, body);
        expect(exchange.phase, ClassificationExchangePhase.failed);
        expect(exchange.error, contains('invalidResponse'));
        expect(
          '${exchange.request}${exchange.response}${exchange.error}',
          isNot(contains('private-fixture-key')),
        );
        plugin.closeSession();
      }
    },
  );

  test(
    'category discovery displays fresh request and streamed response immediately',
    () async {
      final stream = StreamController<StreamEvent>();
      final provider = Provider(stream.stream);
      final trace = ClassificationTrace();
      final learner = MainAgentCategoryLearner(() => provider);
      final work = learner.propose(
        question: initialCategoryQuestions().first,
        input: 'hello',
        cancellation: JudgmentCancellation(),
        trace: trace,
        inputId: 'hello-id',
        parentId: 42,
      );
      final exchange = trace.exchanges.single;
      expect(exchange.parentId, 42);
      final request = jsonDecode(exchange.request) as Map;
      expect(request['model'], 'active-model');
      expect(request['system'], provider.system);
      expect(request['output_schema'], provider.output!.schema);
      expect(
        (request['messages'] as List).single['content'],
        (provider.messages!.single.content.single as TextBlock).text,
      );
      stream.add(const TextDelta('{"existing_category":'));
      await pumpEventQueue();
      expect(exchange.response, '{"existing_category":');
      expect(exchange.phase, ClassificationExchangePhase.pending);
      stream.add(
        MessageComplete(content: [TextBlock(proposal)], stopReason: 'end_turn'),
      );
      expect((await work).category!.id, 'greeting');
      expect(exchange.response, proposal);
      expect(exchange.phase, ClassificationExchangePhase.complete);
      expect(provider.closed, true);
      await stream.close();
      trace.close();
    },
  );
}
