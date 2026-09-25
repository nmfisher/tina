import 'dart:async';

import 'package:tina_engine/tina_engine.dart';

import '../commands/command_context.dart';
import '../commands/command_registry.dart';
import '../execution/input_status.dart';
import 'goal_store.dart';

export 'goal_store.dart';

/// The service key sibling code uses to require the store; the composition
/// plugin provides it at activation.
final goalStoreServiceKey = ServiceKey<GoalStore>('tina.goal.store');

/// One conversation's goal rendered as agent-visible request context,
/// appended to the system prompt per request by [GoalMiddleware].
/// Request-time (deliberately not a PromptContributor), exactly like the
/// plan's middleware: prompts are resolved once per conversation and replayed
/// from stored meta on resume, so a static section would freeze the goal at
/// conversation start.
class GoalMiddleware extends AgentMiddleware {
  final GoalStore store;

  /// The conversation this middleware was built for. Shared-scope
  /// contributions cannot tell whose goal to inject — and two live
  /// conversations must not overwrite each other's context.
  final String conversationId;
  GoalMiddleware(this.store, this.conversationId);

  @override
  String get id => 'tina.goal.middleware';

  @override
  String get name => 'Goal tracker';

  @override
  FutureOr<AgentDecision<AgentRequest>> beforeRequest(
    AgentContext context,
    AgentRequest request,
  ) async {
    if (context.stage != AgentStage.request) return AgentDecision.next(request);
    final goal = store.read(conversationId);
    if (goal.isEmpty) return AgentDecision.next(request);
    return AgentDecision.next(
      request.copyWith(system: '${request.system}\n${_section(goal)}'),
    );
  }
}

String _section(Goal goal) {
  final buffer = StringBuffer(
    '<current-goal>\n'
    'This conversation has a session goal, set by the user via /goal.\n'
    'Keep it in mind for every request in this conversation: steer each turn '
    'toward it, and say so explicitly when you believe it is fully met.\n',
  );
  buffer.writeln('Goal: ${goal.text}');
  if (goal.hasVerdict) {
    final status = goal.status!;
    final line = switch (status.verdict) {
      GoalVerdict.achieved =>
        'The goal judge last marked this goal ACHIEVED (${status.evidence}). '
            'If the user keeps working, treat further turns as verification '
            'or a new related objective, not a re-open.',
      GoalVerdict.uncertain =>
        'The goal judge last could not tell whether this goal is met '
            '(${status.evidence}). Address the ambiguity directly.',
      GoalVerdict.inProgress =>
        'The goal judge last assessed this goal as still in progress '
            '(${status.evidence}).',
      GoalVerdict.none => '',
    };
    if (line.isNotEmpty) buffer.writeln(line);
  }
  buffer.writeln('</current-goal>');
  return buffer.toString();
}

/// The user's glanceable surface: exposes the focused conversation's goal and
/// verdict to the strip; the frontend's [Renderer] for [GoalSummary] lives in
/// the root package (tina_app has no console dependency), registered by the
/// same composition plugin.
class GoalStatusSource implements StatusSource {
  final GoalStore store;
  GoalStatusSource(this.store);

  @override
  Object? read(String conversationId) {
    final goal = store.read(conversationId);
    if (goal.isEmpty) return null;
    return GoalSummary.fromGoal(goal);
  }

  @override
  Stream<void> get changes => store.changes;
}

/// Strip view-model: the goal text, its verdict mark and (when judged) the
/// evidence line, kept value-shaped so the renderer stays a pure function.
class GoalSummary {
  final String text;
  final GoalVerdict verdict;
  final String evidence;
  const GoalSummary({
    required this.text,
    this.verdict = GoalVerdict.none,
    this.evidence = '',
  });

  factory GoalSummary.fromGoal(Goal goal) => GoalSummary(
    text: goal.text,
    verdict: goal.status?.verdict ?? GoalVerdict.none,
    evidence: goal.status?.evidence ?? '',
  );

  bool get isAchieved => verdict == GoalVerdict.achieved;
  bool get isUncertain => verdict == GoalVerdict.uncertain;

  /// Summary for the strip and command echo: the verdict mark and the
  /// (possibly truncated) text.
  String get summary {
    final text = this.text.length > 60
        ? '${this.text.substring(0, 57)}…'
        : this.text;
    return switch (verdict) {
      GoalVerdict.achieved => '✓ $text',
      GoalVerdict.uncertain => '? $text',
      _ => text,
    };
  }
}

/// The human override. Writes the store directly; every subcommand answers in
/// the invoking conversation. The judge is read from [store.judgeHook] at
/// dispatch time (late-bound: the coordinator installs it after composition,
/// once the scheduler + conversations exist).
Command goalCommand(GoalStore store) => Command(
  names: ['/goal'],
  argsHint: '[clear | check | status | <free text>]',
  summary:
      'set, show or clear the conversation goal (judged after each turn '
      'when a judge is wired)',
  helpOrder: 46,
  handler: (call) async {
    final id = call.conversationId;
    final args = call.arguments.trim();
    if (args.isEmpty ||
        RegExp(r'^status$', caseSensitive: false).hasMatch(args)) {
      _show(call, store.read(id));
      return const CmdHandled();
    }
    if (RegExp(r'^clear$', caseSensitive: false).hasMatch(args)) {
      final had = !store.read(id).isEmpty;
      store.clear(id);
      call.write(had ? 'Goal cleared.\n' : 'No goal set.\n');
      return const CmdHandled();
    }
    if (RegExp(r'^check$', caseSensitive: false).hasMatch(args)) {
      if (store.read(id).isEmpty) {
        call.write('No goal to check. Set one with `/goal <text>`.\n');
        return const CmdHandled(failed: true);
      }
      final judge = store.judgeHook;
      if (judge == null) {
        call.write('No goal judge is wired in this session.\n');
        return const CmdHandled(failed: true);
      }
      call.write('Judging goal…\n', style: HostMessageStyle.dim);
      final verdict = await judge(id, force: true);
      if (call.isCancelled) return const CmdHandled();
      if (verdict == null) {
        call.write(
          'Goal check failed (see log); previous status '
          'unchanged.\n',
          style: HostMessageStyle.warning,
        );
        return const CmdHandled(failed: true);
      }
      _show(call, store.read(id));
      return const CmdHandled();
    }
    // Free text falls through as the new goal. A new goal resets the
    // judge verdict by construction (GoalStore.set).
    try {
      store.set(id, args);
    } on ArgumentError catch (error) {
      call.write('${error.message}\n', style: HostMessageStyle.warning);
      return const CmdHandled(failed: true);
    }
    _show(call, store.read(id));
    return const CmdHandled();
  },
);

void _show(CommandCall call, Goal goal) {
  if (goal.isEmpty) {
    call.write(
      'No goal. `/goal <text>` sets one; it is injected into every request '
      'and judged after each turn (when a judge is wired). `/goal clear` '
      'removes it.\n',
    );
    return;
  }
  final buffer = StringBuffer('Goal: ${goal.text}\n');
  final status = goal.status;
  if (status != null && status.verdict != GoalVerdict.none) {
    final mark = switch (status.verdict) {
      GoalVerdict.achieved => 'ACHIEVED',
      GoalVerdict.uncertain => 'UNCERTAIN',
      GoalVerdict.inProgress => 'in progress',
      GoalVerdict.none => '',
    };
    buffer.writeln('  verdict: $mark');
    if (status.evidence.isNotEmpty) {
      buffer.writeln('  evidence: ${status.evidence}');
    }
  } else {
    buffer.writeln('  not judged yet');
  }
  call.write(buffer.toString());
}
