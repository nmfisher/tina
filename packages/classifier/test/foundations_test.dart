import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:classifier/judgments.dart';
import 'package:classifier/typesafe_classifier.dart';

final q = NoulQuestion('q', instructions: 'Relevant?');
JudgmentRequest req([String s = 'hello']) =>
    JudgmentRequest(state: s, questions: [q]);
JudgmentResult result(JudgmentRequest r, [int? tokens]) =>
    JudgmentResult.fromJson({
      'model': 'jev-latest',
      'answers': {
        'q': {'type': 'noul', 'noul': 0.8}
      },
      'usage': {if (tokens != null) 'input_tokens': tokens},
    }, request: r);
Matcher failure(JudgmentFailure f) =>
    isA<JudgmentException>().having((e) => e.failure, 'failure', f);

class Fake implements JudgmentService {
  final Future<JudgmentResult> Function(JudgmentRequest, JudgmentCancellation?)
      fn;
  Fake(this.fn);
  @override
  Future<JudgmentResult> evaluate(JudgmentRequest r,
          {JudgmentCancellation? cancellation}) =>
      fn(r, cancellation);
}

JudgmentBatchRunner runner(Fake service,
        {int tokens = 100000,
        int concurrency = 2,
        Duration timeout = const Duration(seconds: 5),
        Duration callTimeout = const Duration(seconds: 5)}) =>
    JudgmentBatchRunner(
        service: service,
        budget: JudgmentRequestBudget(),
        limits: JudgmentBatchLimits(
            concurrency: concurrency,
            maxChargedTokens: tokens,
            outputTokenAllowance: 100,
            timeout: timeout,
            requestTimeout: callTimeout));
void main() {
  test('explicit pre-dispatch rejections release reservations for queued work', () async {
    var calls = 0;
    final unit = JudgmentRequestBudget().estimate(req()) + 100;
    final batch = runner(Fake((r, _) async {
      if (++calls == 1) {
        throw const JudgmentException(JudgmentFailure.closed, attempted: false);
      }
      return result(r);
    }), tokens: unit, concurrency: 2);
    final out = await batch.run([req(), req()]);
    expect(calls, 2);
    expect(out.items.first.attempted, isFalse);
    expect(out.items.first.failure, JudgmentFailure.closed);
    expect(out.items.last.result, isNotNull);
    expect(out.chargedTokens, unit);
  });

  test('complete measured usage releases reservations for queued requests',
      () async {
    var calls = 0;
    final order = <Object?>[];
    final unit = JudgmentRequestBudget().estimate(req()) + 100;
    final batch = runner(Fake((r, c) async {
      calls++;
      order.add(r.state.value);
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return JudgmentResult.fromJson({
        'model': 'jev-latest',
        'answers': {
          'q': {'type': 'noul', 'noul': 0.9},
        },
        'usage': {'input_tokens': 100, 'output_tokens': 10}
      }, request: r);
    }), tokens: unit + 550, concurrency: 4);
    final out = await batch.run(List.generate(6, (i) => req("$i")));
    expect(calls, 6);
    expect(order, ["0", "1", "2", "3", "4", "5"]);
    expect(out.items.every((i) => i.result != null), isTrue);
    expect(out.chargedTokens, 660);
  });

  test('invalid batch is rejected atomically before any dispatch', () async {
    var calls = 0;
    final batch = runner(Fake((r, c) async {
      calls++;
      return result(r);
    }));
    await expectLater(batch.run(List.filled(257, req())),
        throwsA(failure(JudgmentFailure.budgetExceeded)));
    await expectLater(batch.run([req(), req('x' * 30000)]),
        throwsA(failure(JudgmentFailure.requestTooLarge)));
    expect(calls, 0);
    expect((await batch.run([])).chargedTokens, 0);
  });

  test('cancellation retains results already completed', () async {
    final token = JudgmentCancellation();
    var calls = 0;
    final batch = runner(Fake((r, c) async {
      if (++calls == 2) {
        token.cancel();
        throw const JudgmentException(JudgmentFailure.cancelled);
      }
      return result(r);
    }), concurrency: 1);
    final out = await batch.run([req(), req(), req()], cancellation: token);
    expect(out.items.first.result, isNotNull);
    expect(out.items[1].failure, JudgmentFailure.cancelled);
    expect(out.items.last.attempted, isFalse);
  });

  test('counts complete UTF-8 JSON with overhead', () {
    final b = JudgmentRequestBudget(overheadTokens: 77);
    expect(
        b.estimate(req('汉字👋')),
        utf8.encode(jsonEncode(req('汉字👋').toJson(model: b.model))).length +
            77);
  });
  test('chunks preserve Unicode evidence, offsets and complete choice rubric',
      () {
    final b = JudgmentRequestBudget(maxInputTokens: 420, overheadTokens: 10);
    final choice = ChoiceQuestion('where',
        instructions: 'Select', criteria: {'a': 'first', 'b': 'second'});
    for (final text in ['👋' * 200, 'void hello() { /* 汉字👋 */ }\n' * 40, '']) {
      final chunks =
          b.chunkText(source: 'a.dart', text: text, questions: [choice]);
      expect(chunks.map((c) => (c.request.state.value as Map)['text']).join(),
          text);
      var offset = 0;
      for (final c in chunks) {
        expect(c.startScalar, offset);
        expect(c.request.questions['where'], same(choice));
        expect(b.check(c.request), lessThanOrEqualTo(420));
        offset = c.endScalar;
      }
      expect(offset, text.runes.length);
    }
    expect(
        () => b.chunkText(
            source: 'a', text: 'x' * 1000, questions: [q], maxChunks: 1),
        throwsA(failure(JudgmentFailure.requestTooLarge)));
    expect(
        () => b.chunkText(
            source: 'a',
            text: '',
            questions: [NoulQuestion('big', instructions: 'x' * 1000)]),
        throwsA(failure(JudgmentFailure.requestTooLarge)));
  });
  test('oversize rejected before creating HTTP client', () async {
    var created = false;
    final service = TypeSafeJudgmentService(
        config: TypeSafeConfig(
            apiKey: 'key',
            requestBudget:
                JudgmentRequestBudget(maxInputTokens: 200, overheadTokens: 10)),
        clientFactory: () {
          created = true;
          throw StateError('no network');
        });
    await expectLater(service.evaluate(req('x' * 1000)),
        throwsA(failure(JudgmentFailure.requestTooLarge)));
    expect(created, isFalse);
  });
  test('concurrency bounded; unknown usage retains reservation', () async {
    var active = 0;
    var peak = 0;
    final batch = runner(Fake((r, c) async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      active--;
      return result(r);
    }));
    final out = await batch.run(List.filled(7, req()));
    expect(peak, 2);
    expect(out.items.every((i) => i.result != null && i.attempted), isTrue);
    expect(out.chargedTokens, 7 * (batch.budget.estimate(req()) + 100));
  });
  test('atomic reservations and failed attempts limit dispatch', () async {
    var calls = 0;
    final unit = JudgmentRequestBudget().estimate(req()) + 100;
    final batch = runner(Fake((r, c) async {
      calls++;
      throw const JudgmentException(JudgmentFailure.unavailable);
    }), tokens: unit * 2, concurrency: 4);
    final out = await batch.run(List.filled(6, req()));
    expect(calls, 2);
    expect(out.chargedTokens, unit * 2);
    expect(
        out.items.skip(2).every(
            (i) => !i.attempted && i.failure == JudgmentFailure.budgetExceeded),
        isTrue);
  });
  for (final deadline in [false, true]) {
    test(
        '${deadline ? 'deadline' : 'cancellation'} stops active and queued work',
        () async {
      var calls = 0;
      var cancelled = 0;
      final started = Completer<void>();
      final token = JudgmentCancellation();
      final batch = runner(Fake((r, c) {
        calls++;
        if (calls == 2) started.complete();
        final pending = Completer<JudgmentResult>();
        c!.listen(() {
          cancelled++;
          pending.completeError(
              const JudgmentException(JudgmentFailure.cancelled));
        });
        return pending.future;
      }), timeout: Duration(milliseconds: deadline ? 20 : 5000));
      final pending = batch.run(List.filled(5, req()), cancellation: token);
      await started.future;
      if (!deadline) token.cancel();
      final out = await pending;
      expect(calls, 2);
      expect(cancelled, 2);
      expect(
          out.items.every((i) =>
              i.failure ==
              (deadline ? JudgmentFailure.timeout : JudgmentFailure.cancelled)),
          isTrue);
    });
  }
  test('pre-cancelled starts nothing; overlapping batches rejected', () async {
    final started = Completer<void>();
    final pending = Completer<JudgmentResult>();
    final batch = runner(Fake((r, c) {
      started.complete();
      return pending.future;
    }));
    final cancelled = await batch
        .run([req()], cancellation: JudgmentCancellation()..cancel());
    expect(cancelled.items.single.attempted, isFalse);
    final first = batch.run([req()]);
    await started.future;
    await expectLater(batch.run([req()]), throwsStateError);
    pending.complete(result(req()));
    await first;
  });
  test('reported overrun halts dispatch preserving completed evidence',
      () async {
    var calls = 0;
    final batch = runner(Fake((r, c) async {
      calls++;
      return result(r, 200000);
    }), concurrency: 1);
    final out = await batch.run([req(), req()]);
    expect(calls, 1);
    expect(out.chargedTokens, 200100);
    expect(out.items.first.result, isNotNull);
    expect(out.items.last.failure, JudgmentFailure.budgetExceeded);
  });
  test('per-call deadline cancels stalled transport', () async {
    var cancelled = false;
    final batch = runner(Fake((r, c) {
      c!.listen(() => cancelled = true);
      return Completer<JudgmentResult>().future;
    }), callTimeout: const Duration(milliseconds: 10));
    final out = await batch.run([req()]);
    expect(out.items.single.failure, JudgmentFailure.timeout);
    expect(cancelled, isTrue);
  });
}
