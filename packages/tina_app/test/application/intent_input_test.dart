import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_engine/invocation.dart' as engine show Invocation;
import 'input_processors_test.dart' show Processor;

class Service implements JudgmentService {
  final Map<String, double> scores;
  final requests = <JudgmentRequest>[];
  Service(this.scores);
  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) async {
    requests.add(request);
    return JudgmentResult.fromJson({
      'model': 'jev-latest',
      'answers': {
        for (final id in request.questions.keys)
          id: {'type': 'noul', 'noul': scores[id] ?? 0.0},
      },
      'usage': {'input_tokens': 100, 'output_tokens': 50},
    }, request: request);
  }
}

void main() {
  group('Intent classifier', () {
    for (final sample in [
      (
        scores: <String, double>{'projectQuestion': .96, 'agentInstruction': .3},
        type: IntentType.projectQuestion,
        confidence: .96,
      ),
      (
        scores: <String, double>{'projectQuestion': .2, 'agentInstruction': .94},
        type: IntentType.agentInstruction,
        confidence: .94,
      ),
      // Both below threshold → unclear, regardless of which is higher.
      (
        scores: <String, double>{'projectQuestion': .7, 'agentInstruction': .5},
        type: IntentType.unclear,
        confidence: 0.0,
      ),
      (
        scores: <String, double>{'projectQuestion': .5, 'agentInstruction': .7},
        type: IntentType.unclear,
        confidence: 0.0,
      ),
      // Confident `neither` with both categories quiet → clearly neither,
      // not unclear (chit-chat, greetings, quotes).
      (
        scores: <String, double>{
          'projectQuestion': .05,
          'agentInstruction': .1,
          'neither': .97,
        },
        type: null,
        confidence: 0.0,
      ),
      // A confident category AND a confident `neither` is contradictory
      // evidence: unsure wins over either reading.
      (
        scores: <String, double>{
          'projectQuestion': .9,
          'agentInstruction': .1,
          'neither': .95,
        },
        type: IntentType.unclear,
        confidence: 0.0,
      ),
      // Tie at or above threshold → instruction wins.
      (
        scores: <String, double>{'projectQuestion': .86, 'agentInstruction': .86},
        type: IntentType.agentInstruction,
        confidence: .86,
      ),
    ]) {
      test('decodes independent scores ${sample.scores}', () async {
        final service = Service(sample.scores);
        final result = await classifyIntent(
          source: InputTextSource('1', 'latest input', []),
          service: service,
          budget: JudgmentRequestBudget(),
          cancellation: JudgmentCancellation(),
        );
        expect(result.type, sample.type);
        expect(result.confidence, sample.confidence);
        expect(service.requests, hasLength(1));
        expect(
          service.requests.single.questions.keys,
          containsAll(['projectQuestion', 'agentInstruction']),
        );
      });
    }

    test(
      'oversized or over-budget input is unclear without a model request',
      () async {
        final service = Service({});
        for (final pair in [
          (text: 'x' * 12001, budget: JudgmentRequestBudget()),
          (text: 'fix it', budget: JudgmentRequestBudget(maxInputTokens: 1025)),
        ]) {
          final result = await classifyIntent(
            source: InputTextSource('1', pair.text, []),
            service: service,
            budget: pair.budget,
            cancellation: JudgmentCancellation(),
          );
          expect(result.type, IntentType.unclear);
          expect(result.confidence, 0.0);
        }
        expect(service.requests, isEmpty);
      },
    );

    test(
      'source includes recent text context but excludes tool payloads',
      () async {
        final service = Service({'projectQuestion': .95});
        final history = [
          const Message(
            role: Role.assistant,
            content: [
              TextBlock('I can explain how X works.'),
              ToolUseBlock(
                id: '1',
                name: 'bash',
                input: {'command': 'private tool payload'},
              ),
            ],
          ),
        ];
        await classifyIntent(
          source: InputTextSource('2', 'how does X work?', history),
          service: service,
          budget: JudgmentRequestBudget(),
          cancellation: JudgmentCancellation(),
        );
        final state = service.requests.single.state.value.toString();
        expect(state, contains('I can explain how X works.'));
        expect(state, contains('how does X work?'));
        expect(state, isNot(contains('private tool payload')));
      },
    );
  });

  group('Intent plugin', () {
    late PluginScope scope;
    late InputRoutes routes;
    setUp(() {
      scope = PluginScope('test');
      routes = InputRoutes(scope);
    });
    tearDown(() => scope.dispose());
    void register(IntentInput plugin) => scope.registerContribution(
      pluginId: 'intent',
      id: 'intent',
      contribution: plugin,
      dispose: plugin.dispose,
    );
    Future<PreparedInput> submit(
      String text, {
      String conversation = 'a',
      Future<void>? cancel,
    }) => routes.prepare(
      text: text,
      conversationId: conversation,
      history: [],
      cancelSignal: cancel ?? Completer<void>().future,
    );

    for (final cancel in [false, true]) {
      test(
        'classifier status respects its own hold (cancel: $cancel)',
        () async {
          final calls = Invocations();
          scope.provide(invocationsServiceKey, calls);
          addTearDown(calls.dispose);
          final result = Completer<IntentResult?>();
          late engine.Invocation invocation;
          final plugin = IntentInput((input, _) {
            invocation = input.invocation!;
            return result.future;
          });
          register(plugin);
          await submit('how does this work?');
          final hold = invocation.hold();
          result.complete(
            const IntentResult(
              type: IntentType.projectQuestion,
              confidence: 0.95,
            ),
          );
          await pumpEventQueue();
          expect(plugin.read('a')!.phase, IntentPhase.checking);
          if (cancel) invocation.cancel();
          await hold.dispose();
          await invocation.done;
          await pumpEventQueue();
          expect(
            plugin.read('a')!.phase,
            cancel ? IntentPhase.cancelled : IntentPhase.ready,
          );
          if (!cancel) {
            expect(
              plugin.read('a')!.result!.type,
              IntentType.projectQuestion,
            );
          }
        },
      );
    }

    test(
      'background mode passes immediately; newest result wins per conversation',
      () async {
        final results = <String, Completer<IntentResult?>>{};
        final tokens = <String, JudgmentCancellation>{};
        final plugin = IntentInput((input, token) {
          tokens[input.text] = token;
          return (results[input.text] = Completer<IntentResult?>()).future;
        });
        register(plugin);
        final first = await submit('first');
        expect(first.outcome, InputOutcome.pass);
        expect(plugin.read('a')!.phase, IntentPhase.checking);
        final second = await submit('second');
        await submit('other panel', conversation: 'b');
        expect(tokens['first']!.isCancelled, isTrue);
        results['second']!.complete(
          const IntentResult(
            type: IntentType.agentInstruction,
            confidence: 0.9,
          ),
        );
        results['other panel']!.complete(
          const IntentResult(type: null, confidence: 0.0),
        );
        await Future<void>.delayed(Duration.zero);
        results['first']!.complete(
          const IntentResult(
            type: IntentType.projectQuestion,
            confidence: 0.85,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(plugin.read('a')!.inputId, second.context.id);
        expect(plugin.read('a')!.result!.type, IntentType.agentInstruction);
        expect(plugin.read('b')!.result!.type, isNull);
      },
    );

    test(
      'an older submission delayed upstream cannot replace newer status',
      () async {
        final entered = Completer<void>();
        final release = Completer<InputDecision>();
        scope.registerContribution(
          pluginId: 'test',
          id: 'delay',
          contribution: Processor((input) {
            if (input.text != 'first') return const InputDecision.pass();
            entered.complete();
            return release.future;
          }),
        );
        final calls = <String>[];
        final plugin = IntentInput((input, token) async {
          calls.add(input.text);
          return const IntentResult(
            type: IntentType.agentInstruction,
            confidence: 0.9,
          );
        });
        register(plugin);
        final first = submit('first');
        await entered.future;
        final second = await submit('second');
        release.complete(const InputDecision.pass());
        await first;
        await Future<void>.delayed(Duration.zero);
        expect(plugin.read('a')!.inputId, second.context.id);
        expect(calls, ['second']);
      },
    );

    test(
      'emergency cancellation reaches background work after forwarding',
      () async {
        late JudgmentCancellation token;
        final plugin = IntentInput((input, cancel) {
          token = cancel;
          return Completer<IntentResult?>().future;
        });
        register(plugin);
        await submit('what does this do?');
        expect(routes.cancelBackground('a'), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(token.isCancelled, isTrue);
        expect(plugin.read('a')!.phase, IntentPhase.cancelled);
        expect(routes.cancelBackground('a'), isFalse);
      },
    );

    test('awaited mode adds metadata before forwarding', () async {
      final result = Completer<IntentResult?>();
      final started = Completer<void>();
      final plugin = IntentInput((input, token) {
        started.complete();
        return result.future;
      }, background: false);
      register(plugin);
      final pending = submit('fix the bug');
      await started.future;
      expect(plugin.read('a')!.phase, IntentPhase.checking);
      result.complete(
        const IntentResult(type: IntentType.agentInstruction, confidence: 0.93),
      );
      final prepared = await pending;
      expect(prepared.context.data['intent'], {
        'type': 'agentInstruction',
        'confidence': 0.93,
      });
      expect(prepared.text, 'fix the bug');
    });

    test('clearly-neither result publishes ready with a null type', () async {
      final plugin = IntentInput(
        (input, token) async => const IntentResult(type: null, confidence: 0.0),
      );
      register(plugin);
      await submit('hello there');
      await Future<void>.delayed(Duration.zero);
      expect(plugin.read('a')!.phase, IntentPhase.ready);
      expect(plugin.read('a')!.result!.type, isNull);
    });

    test(
      'cancellation and disposal stop requests without publishing late results',
      () async {
        final tokens = <JudgmentCancellation>[];
        final results = <Completer<IntentResult?>>[];
        final plugin = IntentInput((input, token) {
          tokens.add(token);
          final result = Completer<IntentResult?>();
          results.add(result);
          return result.future;
        });
        register(plugin);
        final cancel = Completer<void>();
        await submit('cancel', cancel: cancel.future);
        cancel.complete();
        await Future<void>.delayed(Duration.zero);
        expect(tokens.first.isCancelled, isTrue);
        expect(plugin.read('a')!.phase, IntentPhase.cancelled);
        await submit('dispose');
        await scope.dispose();
        expect(tokens.last.isCancelled, isTrue);
        for (final result in results) {
          result.complete(
            const IntentResult(
              type: IntentType.agentInstruction,
              confidence: 0.9,
            ),
          );
        }
        await Future<void>.delayed(Duration.zero);
        expect(plugin.read('a'), isNull);
      },
    );

    test(
      'unavailable service passes input and timeout stops pending requests',
      () async {
        late JudgmentCancellation token;
        final plugin = IntentInput(
          (input, cancel) {
            token = cancel;
            return Completer<IntentResult?>().future;
          },
          background: false,
          timeout: const Duration(milliseconds: 20),
        );
        register(plugin);
        final prepared = await submit('anything');
        expect(prepared.outcome, InputOutcome.pass);
        expect(token.isCancelled, isTrue);
        expect(plugin.read('a')!.phase, IntentPhase.unavailable);
      },
    );
  });
}
