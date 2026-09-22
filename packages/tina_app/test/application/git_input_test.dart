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
  group('Git classifier', () {
    for (final sample in [
      (
        scores: <String, double>{'commit': .96, 'push': .94},
        commands: ['commit', 'push'],
        unknown: false,
      ),
      (
        scores: <String, double>{'none': .99},
        commands: <String>[],
        unknown: false,
      ),
      (
        // Confident `none` with a mid-scoring command is still a clear
        // "no git request": the quiet-command ceiling is 0.1, so 0.05 passes.
        scores: <String, double>{'none': .95, 'commit': .05},
        commands: <String>[],
        unknown: false,
      ),
      (
        scores: <String, double>{'commit': .6},
        commands: <String>[],
        unknown: true,
      ),
      (
        scores: <String, double>{'other': .94},
        commands: ['other'],
        unknown: false,
      ),
      (
        // Contradictory evidence: a strong command AND a confident `none`.
        // Unsure wins over either reading (conservative, as before).
        scores: <String, double>{'commit': .96, 'none': .9},
        commands: <String>[],
        unknown: true,
      ),
      (
        // A half-confident `none` plus a selected command is also
        // contradictory — the 0.5 threshold must not upgrade to detected.
        scores: <String, double>{'commit': .96, 'none': .7},
        commands: <String>[],
        unknown: true,
      ),
    ]) {
      test('decodes independent scores ${sample.scores}', () async {
        final service = Service(sample.scores);
        final result = await classifyGitInput(
          source: InputTextSource('1', 'latest input', []),
          service: service,
          budget: JudgmentRequestBudget(),
          cancellation: JudgmentCancellation(),
        );
        expect(result.commands, sample.commands);
        expect(result.unknown, sample.unknown);
        expect(service.requests, hasLength(1));
        expect(
          service.requests.single.questions.keys,
          containsAll(['commit', 'push', 'none', 'unknown', 'other']),
        );
      });
    }

    test(
      'oversized or over-budget input is unknown without a model request',
      () async {
        final service = Service({});
        for (final pair in [
          (text: 'x' * 12001, budget: JudgmentRequestBudget()),
          (text: 'commit', budget: JudgmentRequestBudget(maxInputTokens: 1025)),
        ]) {
          final result = await classifyGitInput(
            source: InputTextSource('1', pair.text, []),
            service: service,
            budget: pair.budget,
            cancellation: JudgmentCancellation(),
          );
          expect(result.unknown, isTrue);
        }
        expect(service.requests, isEmpty);
      },
    );

    test(
      'source includes recent text context but excludes tool payloads',
      () async {
        final service = Service({'commit': .95});
        final history = [
          const Message(
            role: Role.assistant,
            content: [
              TextBlock('I can commit it.'),
              ToolUseBlock(
                id: '1',
                name: 'bash',
                input: {'command': 'private tool payload'},
              ),
            ],
          ),
        ];
        await classifyGitInput(
          source: InputTextSource('2', 'yes do that', history),
          service: service,
          budget: JudgmentRequestBudget(),
          cancellation: JudgmentCancellation(),
        );
        final state = service.requests.single.state.value.toString();
        expect(state, contains('I can commit it.'));
        expect(state, contains('yes do that'));
        expect(state, isNot(contains('private tool payload')));
      },
    );
  });

  group('Git plugin', () {
    late PluginScope scope;
    late InputRoutes routes;
    setUp(() {
      scope = PluginScope('test');
      routes = InputRoutes(scope);
    });
    tearDown(() => scope.dispose());
    void register(GitInput plugin) => scope.registerContribution(
      pluginId: 'git',
      id: 'git',
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
          final result = Completer<GitIntent?>();
          late engine.Invocation invocation;
          final plugin = GitInput((input, _) {
            invocation = input.invocation!;
            return result.future;
          });
          register(plugin);
          await submit('commit');
          final hold = invocation.hold();
          result.complete(GitIntent(commands: ['commit']));
          await pumpEventQueue();
          expect(plugin.read('a')!.phase, GitPhase.checking);
          if (cancel) invocation.cancel();
          await hold.dispose();
          await invocation.done;
          await pumpEventQueue();
          expect(
            plugin.read('a')!.phase,
            cancel ? GitPhase.cancelled : GitPhase.ready,
          );
          if (!cancel) expect(plugin.read('a')!.intent!.commands, ['commit']);
        },
      );
    }

    test(
      'background mode passes immediately; newest result wins per conversation',
      () async {
        final results = <String, Completer<GitIntent?>>{};
        final tokens = <String, JudgmentCancellation>{};
        final plugin = GitInput((input, token) {
          tokens[input.text] = token;
          return (results[input.text] = Completer<GitIntent?>()).future;
        });
        register(plugin);
        final first = await submit('first');
        expect(first.outcome, InputOutcome.pass);
        expect(plugin.read('a')!.phase, GitPhase.checking);
        final second = await submit('second');
        await submit('other panel', conversation: 'b');
        expect(tokens['first']!.isCancelled, isTrue);
        results['second']!.complete(GitIntent(commands: ['push']));
        results['other panel']!.complete(GitIntent());
        await Future<void>.delayed(Duration.zero);
        results['first']!.complete(GitIntent(commands: ['reset']));
        await Future<void>.delayed(Duration.zero);
        expect(plugin.read('a')!.inputId, second.context.id);
        expect(plugin.read('a')!.intent!.commands, ['push']);
        expect(plugin.read('b')!.intent!.commands, isEmpty);
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
        final plugin = GitInput((input, token) async {
          calls.add(input.text);
          return GitIntent(commands: ['push']);
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
        final plugin = GitInput((input, cancel) {
          token = cancel;
          return Completer<GitIntent?>().future;
        });
        register(plugin);
        await submit('commit');
        expect(routes.cancelBackground('a'), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(token.isCancelled, isTrue);
        expect(plugin.read('a')!.phase, GitPhase.cancelled);
        expect(routes.cancelBackground('a'), isFalse);
      },
    );

    test('awaited mode adds metadata before forwarding', () async {
      final result = Completer<GitIntent?>();
      final started = Completer<void>();
      final plugin = GitInput((input, token) {
        started.complete();
        return result.future;
      }, background: false);
      register(plugin);
      final pending = submit('commit');
      await started.future;
      expect(plugin.read('a')!.phase, GitPhase.checking);
      result.complete(GitIntent(commands: ['commit']));
      final prepared = await pending;
      expect(prepared.context.data['git'], {
        'commands': ['commit'],
        'unknown': false,
      });
      expect(prepared.text, 'commit');
    });

    test(
      'cancellation and disposal stop requests without publishing late results',
      () async {
        final tokens = <JudgmentCancellation>[];
        final results = <Completer<GitIntent?>>[];
        final plugin = GitInput((input, token) {
          tokens.add(token);
          final result = Completer<GitIntent?>();
          results.add(result);
          return result.future;
        });
        register(plugin);
        final cancel = Completer<void>();
        await submit('cancel', cancel: cancel.future);
        cancel.complete();
        await Future<void>.delayed(Duration.zero);
        expect(tokens.first.isCancelled, isTrue);
        expect(plugin.read('a')!.phase, GitPhase.cancelled);
        await submit('dispose');
        await scope.dispose();
        expect(tokens.last.isCancelled, isTrue);
        for (final result in results) {
          result.complete(GitIntent(commands: ['push']));
        }
        await Future<void>.delayed(Duration.zero);
        expect(plugin.read('a'), isNull);
      },
    );

    test(
      'unavailable service passes input and timeout stops pending requests',
      () async {
        late JudgmentCancellation token;
        final plugin = GitInput(
          (input, cancel) {
            token = cancel;
            return Completer<GitIntent?>().future;
          },
          background: false,
          timeout: const Duration(milliseconds: 20),
        );
        register(plugin);
        final prepared = await submit('commit');
        expect(prepared.outcome, InputOutcome.pass);
        expect(token.isCancelled, isTrue);
        expect(plugin.read('a')!.phase, GitPhase.unavailable);
      },
    );
  });
}
