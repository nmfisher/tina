import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_engine/src/timers/timer_service.dart';
import 'package:tina_engine/src/timers/timer_tools.dart';
import 'package:tina_engine/src/timers/interval_parser.dart';
import 'package:tina_engine/src/tools/tool.dart';

/// A controllable [Timer]: the test fires it by hand via [fire].
class FakeTimer implements Timer {
  final Duration initialDelay;
  void Function()? callback;
  bool cancelled = false;
  FakeTimer(this.initialDelay);
  @override
  bool get isActive => !cancelled && callback != null;
  @override
  void cancel() {
    cancelled = true;
    callback = null;
  }

  @override
  int get tick => initialDelay.inMilliseconds;
  void fire() {
    if (!isActive) throw StateError('timer not active');
    final cb = callback;
    callback = null;
    cb!();
  }
}

class Harness {
  late final TimerService service;
  final List<String> fires = [];
  final List<String> warnings = [];
  final List<FakeTimer> timers = [];

  Harness({DateTime Function()? clock}) {
    service = TimerService(
      onFire: (name, n) => fires.add('$name#$n'),
      onNotice: (text, {required bool warning}) {
        if (warning) warnings.add(text);
      },
      timerFactory: (d, cb) {
        final t = FakeTimer(d);
        t.callback = cb;
        timers.add(t);
        return t;
      },
      clock: clock,
    );
  }
}

void main() {
  group('parseInterval (§5 grammar)', () {
    test('simple forms', () {
      expect(parseInterval('90s')!.duration, const Duration(seconds: 90));
      expect(parseInterval('5m')!.duration, const Duration(minutes: 5));
      expect(parseInterval('1h')!.duration, const Duration(hours: 1));
      expect(parseInterval('1d')!.duration, const Duration(hours: 24));
    });

    test('compound sums in any order', () {
      expect(parseInterval('1h30m')!.duration, const Duration(seconds: 5400));
      expect(parseInterval('30m1h')!.duration, const Duration(seconds: 5400));
      expect(parseInterval('12h30m')!.duration, const Duration(seconds: 45000));
      expect(parseInterval('2m45s')!.duration, const Duration(seconds: 165));
      // A compound sum past the maximum clamps to it.
      final over = parseInterval('1d30m')!;
      expect(over.clamped, isTrue);
      expect(over.duration, kMaxTimerInterval);
    });

    test('case-insensitive units, surrounding and internal whitespace', () {
      expect(parseInterval('5M')!.duration, const Duration(minutes: 5));
      expect(parseInterval(' 1h30M ')!.duration, const Duration(seconds: 5400));
      expect(parseInterval('1 h')!.duration, const Duration(hours: 1));
    });

    test('clamps after summing, flagged not rejected', () {
      expect(parseInterval('20s')!.clamped, isTrue);
      expect(parseInterval('20s')!.duration, kMinTimerInterval);
      expect(parseInterval('4s5s')!.duration, kMinTimerInterval);
      expect(parseInterval('25h')!.duration, kMaxTimerInterval);
      expect(parseInterval('1d1s')!.clamped, isTrue);
      // 1d is exactly the maximum: not clamped.
      expect(parseInterval('1d')!.clamped, isFalse);
      expect(parseInterval('5m')!.clamped, isFalse);
    });

    test('rejects: empty, bare number, bare unit, words, signs, junk', () {
      expect(parseInterval(''), isNull);
      expect(parseInterval('   '), isNull);
      expect(parseInterval('5'), isNull);
      expect(parseInterval('m'), isNull);
      expect(parseInterval('five'), isNull);
      expect(parseInterval('0m'), isNull);
      expect(parseInterval('1h0m'), isNull);
      expect(parseInterval('1h-30m'), isNull);
      expect(parseInterval('+5m'), isNull);
      expect(parseInterval('5m!'), isNull);
      expect(parseInterval('1h30'), isNull);
      expect(parseInterval('every 5m'), isNull);
    });

    test('a run of more than 6 digits rejects the whole input', () {
      expect(parseInterval('1234567s'), isNull);
      expect(parseInterval('123456s'), isNotNull);
    });
  });

  group('formatEvery', () {
    test('renders largest-unit-first, omitting zeros', () {
      expect(formatEvery(const Duration(seconds: 90)), '1m30s');
      expect(formatEvery(const Duration(minutes: 5)), '5m');
      expect(formatEvery(const Duration(hours: 24)), '1d');
      expect(formatEvery(const Duration(seconds: 30)), '30s');
      expect(formatEvery(const Duration(hours: 1, minutes: 30)), '1h30m');
    });
  });

  group('formatHumanDuration', () {
    test('largest two nonzero units', () {
      expect(
          formatHumanDuration(const Duration(minutes: 2, seconds: 13)), '2m13s');
      expect(formatHumanDuration(const Duration(hours: 1)), '1h');
      expect(formatHumanDuration(const Duration(seconds: 45)), '45s');
      expect(formatHumanDuration(const Duration(hours: 25)), '1d1h');
    });
  });

  group('set_timer', () {
    late Harness h;
    late List<Tool> tools;
    setUp(() {
      h = Harness();
      tools = timerToolsFor(h.service);
    });

    test('missing required fields', () async {
      expect((await tools[0].execute({
        'every': '5m',
        'instruction': 'i',
      }))
          .content, 'name is required');
      expect((await tools[0].execute({
        'name': 'a',
        'instruction': 'i',
      }))
          .content, 'every is required');
      expect((await tools[0].execute({
        'name': 'a',
        'every': '5m',
      }))
          .content, 'instruction is required');
    });

    test('1. name syntax is validated before every grammar (§6.1)', () async {
      final r = await tools[0].execute({
        'name': 'has space',
        'every': 'also-bad',
        'instruction': 'i',
      });
      expect(r.isError, isTrue);
      expect(r.content, contains('name must match'));
      expect(r.content, isNot(contains('every does not parse')));
    });

    test('2. every grammar is validated before instruction length', () async {
      final r = await tools[0].execute({
        'name': 'ok',
        'every': 'nope',
        'instruction': 'x' * 5000,
      });
      expect(r.content, contains('every does not parse'));
      expect(r.content, isNot(contains('instruction must be at most')));
    });

    test('3. instruction length is validated before once/max_fires',
        () async {
      final r = await tools[0].execute({
        'name': 'ok',
        'every': '5m',
        'instruction': 'x' * 5000,
        'once': true,
        'max_fires': 3,
      });
      expect(r.content, contains('instruction must be at most'));
      expect(r.content, isNot(contains('mutually exclusive')));
    });

    test('name error text is byte-verbatim §6.1', () async {
      final r = await tools[0]
          .execute({'name': '_bad', 'every': '5m', 'instruction': 'i'});
      expect(r.isError, isTrue);
      expect(
        r.content,
        'set_timer rejected: name must match '
        "[A-Za-z0-9][A-Za-z0-9._-]{0,63}. (active timers: none)",
      );
    });

    test('every error text states the grammar (§6.1)', () async {
      final r = await tools[0]
          .execute({'name': 'ok', 'every': 'five', 'instruction': 'i'});
      expect(
        r.content,
        "set_timer rejected: every does not parse — $describeIntervalGrammar"
        '. (active timers: none)',
      );
    });

    test('instruction length error text', () async {
      final r = await tools[0].execute({
        'name': 'ok',
        'every': '5m',
        'instruction': 'x' * (kMaxTimerInstructionChars + 1),
      });
      expect(
        r.content,
        'set_timer rejected: instruction must be at most '
        '$kMaxTimerInstructionChars characters. (active timers: none)',
      );
    });

    test('once + max_fires mutually exclusive (byte-verbatim §6.1)',
        () async {
      final r = await tools[0].execute({
        'name': 'ok',
        'every': '5m',
        'instruction': 'i',
        'once': true,
        'max_fires': 3,
      });
      expect(r.isError, isTrue);
      expect(
        r.content,
        'set_timer rejected: once and max_fires are mutually exclusive. '
        '(active timers: none)',
      );
    });

    test('max_fires must be >= 1', () async {
      final r = await tools[0].execute({
        'name': 'ok',
        'every': '5m',
        'instruction': 'i',
        'max_fires': 0,
      });
      expect(r.content,
          'set_timer rejected: max_fires must be at least 1. (active timers: '
          'none)');
    });

    test('created text is byte-verbatim §6.1, recurring', () async {
      final r = await tools[0].execute({
        'name': 'check-build',
        'every': '5m',
        'instruction': 'i',
      });
      expect(r.isError, isFalse);
      expect(
        r.content,
        "timer 'check-build' set: every 5m, recurring. cancel with "
        "cancel_timer('check-build') or /timers cancel check-build.",
      );
    });

    test('created text, once', () async {
      final r = await tools[0].execute({
        'name': 'a',
        'every': '90s',
        'instruction': 'i',
        'once': true,
      });
      expect(
        r.content,
        "timer 'a' set: every 1m30s, once. cancel with cancel_timer('a') or "
        '/timers cancel a.',
      );
    });

    test('created text, max_fires phrasing', () async {
      final r = await tools[0].execute({
        'name': 'a',
        'every': '5m',
        'instruction': 'i',
        'max_fires': 3,
      });
      expect(
        r.content,
        "timer 'a' set: every 5m, stops after 3 fires. cancel with "
        "cancel_timer('a') or /timers cancel a.",
      );
    });

    test('clamp suffixes, byte-verbatim (§6.1)', () async {
      final r1 = await tools[0]
          .execute({'name': 'a', 'every': '10s', 'instruction': 'i'});
      expect(
        r1.content,
        "timer 'a' set: every 30s, recurring. cancel with cancel_timer('a') "
        'or /timers cancel a. interval clamped to the 30s minimum.',
      );
      final r2 = await tools[0]
          .execute({'name': 'b', 'every': '25h', 'instruction': 'i'});
      expect(
        r2.content,
        "timer 'b' set: every 1d, recurring. cancel with cancel_timer('b') "
        'or /timers cancel b. interval clamped to the 24h maximum.',
      );
    });

    test('replaced text is the created text with the replaced verb', () async {
      await tools[0].execute({'name': 'a', 'every': '5m', 'instruction': 'i'});
      final r = await tools[0].execute({
        'name': 'a',
        'every': '1h',
        'instruction': 'new',
        'max_fires': 2,
      });
      expect(
        r.content,
        "timer 'a' replaced: every 1h, stops after 2 fires. cancel with "
        "cancel_timer('a') or /timers cancel a.",
      );
    });

    test('cap rejection lists the active names (§6.1)', () async {
      for (var i = 0; i < kMaxActiveTimers; i++) {
        await tools[0].execute({'name': 't$i', 'every': '5m', 'instruction': 'i'});
      }
      final r = await tools[0]
          .execute({'name': 'extra', 'every': '5m', 'instruction': 'i'});
      expect(
        r.content,
        'set_timer rejected: $kMaxActiveTimers-timer limit reached. '
        '(active timers: t0, t1, t2, t3, t4, t5, t6, t7)',
      );
    });
  });

  group('cancel_timer', () {
    late Harness h;
    late List<Tool> tools;
    setUp(() {
      h = Harness();
      tools = timerToolsFor(h.service);
    });

    test('ok text is byte-verbatim §6.2 with the fire count', () async {
      await tools[0].execute({'name': 'a', 'every': '5m', 'instruction': 'i'});
      h.timers.first.fire();
      final r = await tools[1].execute({'name': 'a'});
      expect(r.isError, isFalse);
      expect(r.content, "timer 'a' cancelled (1 fires so far).");
    });

    test('unknown name text is byte-verbatim §6.2, isError', () async {
      final r = await tools[1].execute({'name': 'ghost'});
      expect(r.isError, isTrue);
      expect(r.content, "no timer named 'ghost'. active timers: none.");
    });

    test('unknown name lists the remaining active timers', () async {
      await tools[0].execute({'name': 'a', 'every': '5m', 'instruction': 'i'});
      await tools[0].execute({'name': 'b', 'every': '5m', 'instruction': 'i'});
      final r = await tools[1].execute({'name': 'ghost'});
      expect(r.content, "no timer named 'ghost'. active timers: a, b.");
    });
  });

  group('list_timers', () {
    late Harness h;
    late List<Tool> tools;
    // Fixed instant: 2020-01-01T00:00:00Z.
    final base = DateTime.fromMillisecondsSinceEpoch(1577836800000, isUtc: true);
    setUp(() {
      h = Harness(clock: () => base);
      tools = timerToolsFor(h.service, clock: () => base);
    });

    test('empty text is byte-verbatim §6.3', () async {
      final r = await tools[2].execute({});
      expect(r.content, 'no active timers.');
    });

    test('one line per timer with the §6.3 shape', () async {
      await tools[0]
          .execute({'name': 'watch-log', 'every': '1h', 'instruction': 'i'});
      final r = await tools[2].execute({});
      expect(
        r.content,
        'watch-log: every 1h, recurring, fired 0x, next in 1h',
      );
    });

    test('max_fires phrasing and fired counts', () async {
      await tools[0].execute({
        'name': 'a',
        'every': '5m',
        'instruction': 'i',
        'max_fires': 4,
      });
      h.timers.last.fire();
      h.service.ackStarted('a');
      h.service.ackFinished('a', aborted: false);
      final r = await tools[2].execute({});
      expect(r.content, 'a: every 5m, max 4 fires, fired 1x, next in 5m');
    });

    test('in-flight state while a fire is queued/running', () async {
      await tools[0].execute({'name': 'a', 'every': '5m', 'instruction': 'i'});
      h.timers.last.fire();
      final r = await tools[2].execute({});
      expect(r.content, 'a: every 5m, recurring, fired 1x, next in flight');
    });

    test('suspended timers list with the SUSPENDED marker', () async {
      await tools[0].execute({'name': 'a', 'every': '5m', 'instruction': 'i'});
      for (var i = 0; i < kMaxTimerFiresBeforeSuspend; i++) {
        h.timers.last.fire();
        h.service.ackStarted('a');
        h.service.ackFinished('a', aborted: true);
      }
      final r = await tools[2].execute({});
      expect(
        r.content,
        'a: every 5m, recurring, fired 6x, SUSPENDED (after 6 failed fires)',
      );
    });

    test('once phrasing', () async {
      await tools[0].execute({
        'name': 'a',
        'every': '5m',
        'instruction': 'i',
        'once': true,
      });
      final r = await tools[2].execute({});
      expect(r.content, startsWith('a: every 5m, once, fired 0x,'));
    });

    test('honours the injectable clock for the next-in phrase', () async {
      final base = DateTime.fromMillisecondsSinceEpoch(1000000000000);
      final h2 = Harness(clock: () => base);
      final tools2 = timerToolsFor(h2.service, clock: () => base);
      await tools2[0]
          .execute({'name': 'a', 'every': '5m', 'instruction': 'i'});
      final atSet = await tools2[2].execute({});
      expect(atSet.content, 'a: every 5m, recurring, fired 0x, next in 5m');
      // The list tool's own clock can differ from the service's.
      final laterTools = timerToolsFor(h2.service,
          clock: () => base.add(const Duration(minutes: 2)));
      final r = await laterTools[2].execute({});
      expect(r.content, 'a: every 5m, recurring, fired 0x, next in 3m');
    });
  });
}
