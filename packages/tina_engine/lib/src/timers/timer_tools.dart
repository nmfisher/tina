/// The three thin timer tools (§6 of docs/proposals/timer_system.md):
/// `set_timer`, `cancel_timer`, `list_timers`. They validate input in the
/// spec's order, call the service, and translate [TimerSetOutcome] /
/// [TimerSnapshot]s into `ToolResult` text — the service never words tool
/// output itself.
library;

import 'dart:async';

import '../tools/tool.dart';
import '../tools/tool_input.dart';
import 'interval_parser.dart';
import 'timer_service.dart';

/// Renders a clamped duration the way the result texts say it (`90s`, `5m`,
/// `1h30m`, `1d`). Largest-unit-first, omitting zero components.
String formatEvery(Duration d) {
  var seconds = d.inSeconds;
  final parts = <String>[];
  final days = seconds ~/ 86400;
  seconds -= days * 86400;
  final hours = seconds ~/ 3600;
  seconds -= hours * 3600;
  final minutes = seconds ~/ 60;
  seconds -= minutes * 60;
  if (days > 0) parts.add('${days}d');
  if (hours > 0) parts.add('${hours}h');
  if (minutes > 0) parts.add('${minutes}m');
  if (seconds > 0 || parts.isEmpty) parts.add('${seconds}s');
  return parts.join();
}

/// The `<recurring | once | stops after <N> fires>` phrase in §6.1's created
/// text, and the `<recurring | once | max <N> fires>` variant in §6.3.
String _schedulePhrase(TimerSpec spec) {
  if (spec.once) return 'once';
  final maxFires = spec.maxFires;
  if (maxFires != null) return 'stops after $maxFires fires';
  return 'recurring';
}

/// Builds the three tools over [timers]. Registered app-side (leg 2);
/// `ToolRegistry` is last-wins and the names are new, so no collisions.
List<Tool> timerToolsFor(TimerService timers, {DateTime Function()? clock}) =>
    [
      SetTimerTool(timers),
      CancelTimerTool(timers),
      ListTimersTool(timers, clock: clock),
    ];

/// `set_timer` (§6.1). Validation order is the spec's: name → every →
/// instruction → once/max_fires → cap. Cap is service-side (only counts on
/// create).
class SetTimerTool implements Tool {
  final TimerService timers;

  SetTimerTool(this.timers);

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'set_timer',
        description:
            'Set a named timer that fires a REAL agent turn on a fixed '
            'schedule. The instruction must be SELF-CONTAINED: compaction '
            'may have summarized the context that motivated the check. '
            'Prefer cheap, read-only checks; if a check keeps failing, '
            'cancel it instead of leaving it burning turns. Setting an '
            "existing name replaces that timer's schedule and instruction "
            'with fresh counters. Input: name (required), every (required), '
            'instruction (required), once (default false), max_fires '
            '(optional).',
        inputSchema: {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description':
                  'Timer name: starts alphanumeric; then letters, digits, '
                  'dot, underscore, hyphen; 1-64 chars total.',
            },
            'every': {
              'type': 'string',
              'description':
                  'Interval, e.g. 90s, 5m, 1h30m. Clamped to 30s minimum '
                  'and 24h maximum.',
            },
            'instruction': {
              'type': 'string',
              'description':
                  'Self-contained check instruction, replayed verbatim as '
                  'the turn prompt each fire.',
            },
            'once': {
              'type': 'boolean',
              'description': 'Fire exactly once. Mutually exclusive with '
                  'max_fires. Default false.',
            },
            'max_fires': {
              'type': 'integer',
              'description': 'Stop after N fires (>= 1). Mutually exclusive '
                  'with once. Omit for recurring.',
            },
          },
          'required': ['name', 'every', 'instruction'],
        },
      );

  /// Name grammar (§6.1 step 1): starts alphanumeric (so `/timers cancel
  /// <name>` parsing stays unambiguous), then `[A-Za-z0-9._-]`, 1-64 chars.
  static bool _validName(String name) {
    if (name.isEmpty || name.length > 64) return false;
    final first = name.codeUnitAt(0);
    final firstOk = (first >= 0x30 && first <= 0x39) || // 0-9
        (first >= 0x41 && first <= 0x5A) || // A-Z
        (first >= 0x61 && first <= 0x7A); // a-z
    if (!firstOk) return false;
    for (var i = 1; i < name.length; i++) {
      final c = name.codeUnitAt(i);
      final ok = (c >= 0x30 && c <= 0x39) || // 0-9
          (c >= 0x41 && c <= 0x5A) || // A-Z
          (c >= 0x61 && c <= 0x7A) || // a-z
          c == 0x2E || // .
          c == 0x5F || // _
          c == 0x2D; // -
      if (!ok) return false;
    }
    return true;
  }

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final String name;
    try {
      name = requiredString(input, 'name');
    } on ToolValidationException {
      return ToolResult.error('name is required');
    }

    // 1. Name syntax (§6.1 step 1).
    if (!_validName(name)) {
      return ToolResult.error(
        'set_timer rejected: name must match '
        "[A-Za-z0-9][A-Za-z0-9._-]{0,63}. (active timers: ${_activeNames(timers)})",
      );
    }

    // 2. Interval grammar + clamp (§6.1 step 2; clamp is not an error).
    final String everyRaw;
    try {
      everyRaw = requiredString(input, 'every');
    } on ToolValidationException {
      return ToolResult.error('every is required');
    }
    final parsed = parseInterval(everyRaw);
    if (parsed == null) {
      return ToolResult.error(
        'set_timer rejected: every does not parse — '
        '$describeIntervalGrammar. (active timers: ${_activeNames(timers)})',
      );
    }
    final interval = parsed.duration;

    // 3. Instruction: non-empty, <= kMaxTimerInstructionChars (§6.1 step 3).
    final String instruction;
    try {
      instruction = requiredString(input, 'instruction');
    } on ToolValidationException {
      return ToolResult.error('instruction is required');
    }
    if (instruction.length > kMaxTimerInstructionChars) {
      return ToolResult.error(
        'set_timer rejected: instruction must be at most '
        '$kMaxTimerInstructionChars characters. (active timers: '
        '${_activeNames(timers)})',
      );
    }

    // 4. once / max_fires mutual exclusion and max_fires >= 1 (§6.1 step 4).
    final once = optionalBool(input, 'once') ?? false;
    final maxFires = optionalInt(input, 'max_fires');
    if (once && maxFires != null) {
      return ToolResult.error(
        'set_timer rejected: once and max_fires are mutually exclusive. '
        '(active timers: ${_activeNames(timers)})',
      );
    }
    if (maxFires != null && maxFires < 1) {
      return ToolResult.error(
        'set_timer rejected: max_fires must be at least 1. '
        '(active timers: ${_activeNames(timers)})',
      );
    }

    final spec = TimerSpec(
      name: name,
      interval: interval,
      instruction: instruction,
      once: once,
      maxFires: maxFires,
    );
    final outcome = timers.set(spec);

    // Cap rejection (service-side — only counts on create, §6.1 step 5).
    if (outcome is TimerSetRejected) {
      return ToolResult.error(
        'set_timer rejected: ${outcome.reason}. '
        '(active timers: ${_activeNames(timers)})',
      );
    }

    final created = outcome is TimerSetCreated;
    final verb = created ? 'set' : 'replaced';
    final schedule = _schedulePhrase(spec);
    var text =
        "timer '$name' $verb: every ${formatEvery(interval)}, $schedule. "
        "cancel with cancel_timer('$name') or /timers cancel $name.";
    if (parsed.clamped) {
      text += parsed.duration == kMinTimerInterval
          ? ' interval clamped to the 30s minimum.'
          : ' interval clamped to the 24h maximum.';
    }
    return ToolResult(text);
  }
}

/// `cancel_timer` (§6.2). Cancels the schedule; a running fire turn is NOT
/// killed (sub-decision d) — the ack path settles it.
class CancelTimerTool implements Tool {
  final TimerService timers;

  CancelTimerTool(this.timers);

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'cancel_timer',
        description:
            "Cancel a named timer (from set_timer). Does not interrupt a "
            'fire turn already in flight. Use list_timers to see active '
            'timer names.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': 'Timer name to cancel.',
            },
          },
          'required': ['name'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final String name;
    try {
      name = requiredString(input, 'name');
    } on ToolValidationException {
      return ToolResult.error('name is required');
    }
    final fireCount = _fireCountOf(timers, name);
    if (timers.cancel(name)) {
      return ToolResult("timer '$name' cancelled ($fireCount fires so far).");
    }
    return ToolResult.error(
      "no timer named '$name'. active timers: ${_activeNames(timers)}.",
    );
  }
}

/// `list_timers` (§6.3). One line per timer; snapshots include suspended
/// timers (they hold their cap slot).
class ListTimersTool implements Tool {
  final TimerService timers;

  /// Clock for the `next in <human duration>` phrase. Defaults to
  /// [DateTime.now]; tests inject the service's fake clock for determinism.
  final DateTime Function() clock;

  ListTimersTool(this.timers, {DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'list_timers',
        description:
            'List the active timers with their schedules, fire counts, '
            'suspension state, and next fire time.',
        inputSchema: {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final snapshots = timers.list();
    if (snapshots.isEmpty) {
      return ToolResult('no active timers.');
    }
    final now = clock();
    final lines = <String>[];
    for (final s in snapshots) {
      final schedule = s.once
          ? 'once'
          : s.maxFires != null
              ? 'max ${s.maxFires} fires'
              : 'recurring';
      String status;
      if (s.suspended) {
        status =
            'SUSPENDED (after ${s.consecutiveAbortedFires} failed fires)';
      } else if (s.state == TimerEntryState.queued ||
          s.state == TimerEntryState.running) {
        status = 'next in flight';
      } else if (s.nextFireAt != null) {
        status = 'next in ${formatHumanDuration(s.nextFireAt!.difference(now))}';
      } else {
        status = 'next unknown';
      }
      lines.add(
        '${s.name}: every ${formatEvery(s.interval)}, $schedule, '
        'fired ${s.fireCount}x, $status',
      );
    }
    return ToolResult(lines.join('\n'));
  }
}

/// Human duration for §6.3's `next in <human duration>` phrase: `2m13s`
/// style (largest two nonzero units, largest-first).
String formatHumanDuration(Duration d) {
  if (d.isNegative) return '0s';
  var seconds = d.inSeconds;
  final days = seconds ~/ 86400;
  seconds -= days * 86400;
  final hours = seconds ~/ 3600;
  seconds -= hours * 3600;
  final minutes = seconds ~/ 60;
  seconds -= minutes * 60;
  final parts = <String>[];
  if (days > 0) parts.add('${days}d');
  if (hours > 0) parts.add('${hours}h');
  if (minutes > 0) parts.add('${minutes}m');
  if (seconds > 0 || parts.isEmpty) parts.add('${seconds}s');
  return parts.take(2).join();
}

String _activeNames(TimerService timers) {
  final names = timers.list().map((s) => s.name).toList();
  return names.isEmpty ? 'none' : names.join(', ');
}

int? _fireCountOf(TimerService timers, String name) {
  for (final s in timers.list()) {
    if (s.name == name) return s.fireCount;
  }
  return null;
}
