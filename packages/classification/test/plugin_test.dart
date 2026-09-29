import 'dart:async';
import 'package:classification/plugin.dart';
import 'package:classification/judgments.dart';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'utterance_test.dart' show answer;

class Output implements Terminal {
  final lines = <String?>[];
  @override
  void writeln([String? line]) => lines.add(line);
  @override
  Future<String> ask(String prompt) async => throw UnimplementedError();
}

class Pending implements JudgmentService {
  final requests = <JudgmentRequest>[];
  final tokens = <JudgmentCancellation?>[];
  final results = <Completer<JudgmentResult>>[];
  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest request, {
    JudgmentCancellation? cancellation,
  }) {
    requests.add(request);
    tokens.add(cancellation);
    final done = Completer<JudgmentResult>();
    results.add(done);
    return done.future;
  }

  void complete(int index, Map<String, double> scores) =>
      results[index].complete(answer(requests[index], scores));
}

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 10));
TurnContext input(String text, [CancelToken? token]) => TurnContext(
  token ?? CancelToken(),
  input: Input(text, id: text),
  messages: [],
  promptSections: [],
  pinnedTools: [],
);

void main() {
  test(
    'classification is background-only; newest input wins and leases close',
    () async {
      final service = Pending();
      final output = Output();
      var closed = 0;
      final plugin = ClassificationPlugin(
        terminal: output,
        open: () => ClassificationLease(
          service: service,
          budget: JudgmentRequestBudget(),
          close: () => closed++,
        ),
      );
      final first = input('first');
      plugin.onInput(first);
      await pump();
      expect(first.input.text, 'first');
      expect(first.promptSections, isEmpty);
      final second = input('second');
      plugin.onInput(second);
      await pump();
      expect(service.tokens.first!.isCancelled, true);
      expect(closed, 1);
      service.complete(1, {'agentInstruction': .99});
      await pump();
      service.complete(2, {'push': .99});
      await pump();
      expect(plugin.status.label, 'instruction · git: push');
      expect(closed, 2);
      service.complete(0, {'projectQuestion': .99});
      await pump();
      expect(plugin.status.inputId, 'second');
      await plugin.commands.single.handler('');
      expect(output.lines.single, contains('instruction · git: push'));
      plugin.closeSession();
      expect(closed, 2);
    },
  );

  for (final mode in ['cancel', 'close', 'timeout']) {
    test('$mode cancels outstanding work and ignores late results', () async {
      final service = Pending();
      var closed = 0;
      final token = CancelToken();
      final plugin = ClassificationPlugin(
        terminal: Output(),
        timeout: mode == 'timeout'
            ? const Duration(milliseconds: 30)
            : const Duration(seconds: 5),
        open: () => ClassificationLease(
          service: service,
          budget: JudgmentRequestBudget(),
          close: () => closed++,
        ),
      );
      plugin.onInput(input('hello', token));
      await pump();
      if (mode == 'cancel') token.cancel('escape');
      if (mode == 'close') plugin.closeSession();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(service.tokens.single!.isCancelled, true);
      expect(closed, 1);
      final status = plugin.status;
      service.complete(0, {'agentInstruction': .99});
      await pump();
      expect(plugin.status, same(status));
      expect(service.requests, hasLength(1));
      if (mode == 'cancel') expect(status.phase, ClassificationPhase.cancelled);
      if (mode == 'timeout') expect(status.reason, 'timeout');
      plugin.closeSession();
    });
  }

  test('missing service and failures do not modify or cancel input', () async {
    for (final fail in [false, true]) {
      final plugin = ClassificationPlugin(
        terminal: Output(),
        open: () {
          if (fail) throw StateError('sensitive provider error');
          return null;
        },
      );
      final context = input('fix it');
      plugin.onInput(context);
      await pump();
      expect(context.cancelled, false);
      expect(context.input.text, 'fix it');
      expect(plugin.status.phase, ClassificationPhase.unavailable);
      expect(plugin.status.label, isNot(contains('sensitive')));
      plugin.closeSession();
    }
  });
}
