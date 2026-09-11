import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../llm/message.dart';
import '../permissions/policy.dart';
import '../permissions/prompt.dart';
import '../tools/tool.dart';
import '../tools/bash_tool.dart';
import '../tools/sandbox_failure.dart';
import '../tools/tool_input.dart';
import '../permissions/sandbox_access.dart';
import 'agent_sink.dart';
import 'tool_guards.dart';
import 'tool_hooks.dart';

final _log = Logger('tina.agent');

/// Marks an error escaping the delegate chain of an around-execution hook —
/// the tool itself failed, or a deeper hook's violation propagated. A hook
/// must not be able to rebrand a delegate failure as its own: the executor's
/// hook-level catch unwraps this and rethrows the original error with its
/// original stack trace, so the thrown-tool path keeps its exact content and
/// log severity.
class _DelegateFailure implements Exception {
  final Object error;
  final StackTrace stackTrace;
  _DelegateFailure(this.error, this.stackTrace);
  @override
  String toString() => 'delegate failure: $error';
}

/// Per-hook delegation ownership (P1: own and join hook delegates).
///
/// The executor hands exactly one handle to each hook invocation and closes
/// it when that invocation's `run` returns or throws. After closure any call
/// throws — a delegate saved and fired after the executor reported a hook
/// error can no longer execute a tool. A repeat call throws BEFORE starting
/// additional work (the single execution already started is unaffected), and
/// [future] joins whatever work started so the executor can await it on
/// success and failure paths before reporting completion.
final class _HookDelegate {
  _HookDelegate(this._toolName, this._start);

  final String _toolName;
  final Future<ToolResult> Function() _start;
  Future<ToolResult>? _future;
  bool _closed = false;

  /// Set when a repeat call was rejected while the handle was still open —
  /// the executor fails the call closed even if the hook swallowed the
  /// rejection (exactly-once is observable, not just enforced).
  bool repeatAttempt = false;

  /// The delegated work. Null until the hook first calls the delegate.
  Future<ToolResult>? get future => _future;

  /// Closes the handle on EVERY exit of the hook invocation, including
  /// exceptions.
  void close() => _closed = true;

  Future<ToolResult> call() {
    if (_closed) {
      throw StateError(
          'execution hook for $_toolName called the delegate after the hook '
          'returned — delegation is closed');
    }
    if (_future != null) {
      repeatAttempt = true;
      throw StateError(
          'execution hook for $_toolName called the delegate more than '
          'once');
    }
    // Start before returning: the work begins immediately and joins via
    // [future] whether or not the hook awaits it. The future returned to
    // the hook carries failures wrapped in [_DelegateFailure] — unchanged
    // from the previous delegateOnce contract, so a hook that lets the
    // error through cannot rebrand a tool failure as its own, and the
    // executor can tell them apart.
    final work = _start();
    final marked = work.then<ToolResult>((r) => r,
        onError: (Object e, StackTrace st) {
      Error.throwWithStackTrace(_DelegateFailure(e, st), st);
    });
    _future = marked;
    // Observe once so a failure the executor surfaces through its own join
    // never re-escapes as an unhandled async error.
    marked.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return marked;
  }
}

/// Consecutive denials of the SAME tool after which the denial result gains a
/// circuit-breaker line telling the model to stop calling that tool (#27).
/// Why 3: the live spiral runs wasted 12 steps (Run A) and 11 (the probe run)
/// re-denying one tool before the model gave up — three strikes is early
/// enough to cut most of that waste while leaving room for one legitimate
/// rephrase between attempts. Not configurable by design, like
/// [kMaxToolCallsPerRun].
const int consecutiveDenialNoticeThreshold = 3;

/// Consecutive anomalous executions of the SAME command (per-command
/// signature, #29) after which the tool_result gains a guardrail line telling
/// the model to stop re-running it unchanged. Same tool as the #27 denial
/// breaker above, one level down: the spiral it targets is not the policy
/// refusing a call but the call itself going nowhere — timeout, empty output,
/// or the identical error, over and over. Why 3: same reasoning as the denial
/// breaker's three strikes. Not configurable by design, like
/// [kMaxToolCallsPerRun].
const int consecutiveAnomalyNoticeThreshold = 3;

/// The operator-interrupt line (#31) as it lands in history and in the
/// notice the operator sees. Public so a caller (or test) can assert the
/// exact text without hard-coding it.
const String kOperatorInterruptedLine =
    'interrupted by operator — new input pending';

/// Result text for the tool calls a batch skips when the operator interrupt
/// (#31) fires mid-batch. Public for the same reason.
const String kOperatorInterruptedStub = 'skipped: operator interrupt';

/// The in-band guardrail line appended to an anomalous tool_result once the
/// same command has hit [consecutiveAnomalyNoticeThreshold] consecutive
/// anomalies in one turn (#29). In-band on purpose (#27's lesson): prose
/// outside tool results does not steer, so the instruction rides the result
/// the model actually reads. A code constant, not config — same rationale as
/// [kMaxToolCallsPerRun].
const String anomalyGuardrailNote =
    '[guardrail] this exact command has now failed '
    '$consecutiveAnomalyNoticeThreshold times in a row this turn (timeout, '
    'empty output, or an identical error). Do not re-run it unchanged. If the '
    'failure is unrelated to your task, note it and return to the primary '
    'objective. If it is essential, change the approach: narrow the target, '
    'adjust the timeout, use a different tool, or fix the underlying cause.';

/// Optional post-success gate on a tool result, run AFTER a tool completes
/// without error and BEFORE its result is appended to the history the model
/// reads next step (the [ToolExecutor] wires it; [Agent] holds the seam).
typedef ToolResultVerifier = Future<String?> Function(
  String toolName,
  Map<String, dynamic> input,
);

/// The retry-streak key for one tool invocation (#29): tool name plus a
/// normalized form of its input, so `ls -la`, `ls   -la`, and ` ls -la `
/// count as the same command while `ls -la` and `ls -la /tmp` stay
/// distinct. For `bash` the whitespace-collapsed command is the signature;
/// for every other tool the input map is serialized with sorted keys so the
/// key is stable regardless of map insertion order.
String anomalySignature(String toolName, Map<String, dynamic> input) {
  if (toolName == 'bash') {
    final command = input['command'];
    return '$toolName|'
        '${command is String ? _collapseWhitespace(command) : command}';
  }
  final keys = input.keys.toList()..sort();
  return '$toolName|${jsonEncode({
        for (final k in keys) k: input[k],
      })}';
}

/// Collapses every whitespace run (spaces, tabs, newlines) to a single
/// space, after trimming — the bash half of [anomalySignature].
String _collapseWhitespace(String s) =>
    s.trim().split(RegExp(r'\s+')).join(' ');

/// Whether [result] is an anomaly worth counting toward the #29 guardrail
/// for a command the agent keeps re-running. Three classes: the tool's own
/// timeout fired, the command produced zero output at any exit code, or it
/// errored with byte-identical output to the previous attempt of the SAME
/// signature this turn (a changed error means the model's retry is doing
/// something). The last comparison uses pre-note content only — the
/// appended guardrail line must never make identical failures look changed.
bool isAnomalousResult(
  ToolResult result, {
  String? previousContent,
}) {
  if (result.timedOut == true) return true;
  if (result.emptyOutput == true) return true;
  if (result.isError && previousContent != null) {
    return result.content == previousContent;
  }
  return false;
}

/// The remediation payload a denied tool call carries back to the model.
/// The old one-liner ('Denied by permission policy.') gave the model no way
/// to self-correct, so it retried blind variants of the same shape; the
/// model now sees the allowed shapes for its tool and (for bash) the
/// always-allowed native tools, and is told not to retry unchanged.
String deniedContent(PermissionPolicy policy, String tool) {
  final patterns = policy.allowedPatterns(tool);
  final lines = <String>[
    'Denied by permission policy.',
    'Allowed $tool patterns: '
        '${patterns.isEmpty ? 'none' : patterns.join(', ')}',
    if (tool == 'bash')
      'For read-only checks prefer the always-allowed tools: ls, stat, '
          'glob, grep, search, git, which.',
    'Do not retry the same call unchanged; rephrase it to an allowed '
        'shape or use one of those tools.',
  ];
  return lines.join('\n');
}

/// The mutable per-turn dispatch state shared by every [ToolExecutor.execute]
/// call of one turn. Moved verbatim from what used to be `_runTurn` locals:
/// created and discarded with the turn, so no streak or retry memory ever
/// survives into the next user turn. The run loop builds the instance, wires
/// [toolInterrupted] from the operator-interrupt signal, and hands it to the
/// executor.
class ToolCallState {
  /// Operator interrupt (#31), distinct from cancel: fires the turn-stop
  /// AROUND TOOL EXECUTION only — never mid-stream. Armed eagerly (by the
  /// run loop's `toolInterruptSignal?.then(...)` wiring) so an interrupt
  /// that lands before (or between) tool batches is already pending when
  /// the next batch starts (it then begins already-interrupted: the batch's
  /// first call ships the prefix line and the remainder stubs, and the turn
  /// ends). See Agent._runTurn for the wiring and the tool-execution block
  /// for the full mechanics.
  bool toolInterrupted = false;

  // Per-tool consecutive denial counter (#27): resets on any SUCCESS of
  // that tool, increments on each denial. Used to trip the circuit-breaker
  // message that tells the model to stop calling the same denied tool.
  final denialCounts = <String, int>{};

  // #29 retry guard, per-turn like everything above: signature → consecutive
  // anomalies, plus the pre-note content of the signature's last attempt.
  // Created and discarded with this turn — a streak never survives into the
  // next user turn.
  final consecutiveAnomalyCounts = <String, int>{};
  final previousAttemptContent = <String, String>{};

  // Recovery is keyed by exact shell text and cwd, not the anomaly signature
  // (which collapses whitespace, including meaningful quoted whitespace).
  final sandboxFailures = <String,
      ({SandboxWriteFailure failure, int step, List<String> priorPaths})>{};
  final promptedSandboxRetries = <String>{};
  final deniedSandboxRetries = <String>{};
  final deniedSandboxDirectories = <String>{};
}

/// The outcome of ONE tool-call dispatch: the [ToolResultBlock] the batch
/// appends for the call, and whether the operator interrupt (#31) landed
/// while THIS call was in flight — the batch then prefixes this result with
/// [kOperatorInterruptedLine] and stubs every later call (Agent._runTurn
/// owns that stamp; it maps this flag onto its batch-local
/// `interruptedCallIndex`).
typedef ToolCallOutcome = ({ToolResultBlock result, bool interruptedInFlight});

/// The per-call tool dispatch, extracted verbatim from [Agent._runTurn]'s
/// `for (final use in toolUses)` body. One executor (with one
/// [ToolCallState]) is built per turn; [execute] dispatches ONE tool call —
/// parse-error / unknown-tool / mode-block / denial / asker / sandbox-retry
/// gate / execution / verifier gate — and returns the exactly-one result the
/// batch appends for it. The run loop keeps the loop-header control flow
/// itself: the cancel break, the already-interrupted stub branch, the
/// action-limit check, and the post-batch interrupt stamp.
class ToolExecutor {
  final PermissionPolicy policy;
  final PermissionAsker asker;
  final AgentSink sink;
  final ToolResultVerifier? resultVerifier;

  /// The per-turn mutable dispatch state ([ToolCallState]) — built by the
  /// run loop, shared by every [execute] call of the turn.
  final ToolCallState state;

  /// The run's cancel and operator-interrupt signals, captured at
  /// construction (the executor is built per turn by the run loop that
  /// owns them). [execute]'s `isCancelled` covers the agent-level
  /// `cancelled` flag reads; the #31 effective-cancel seam around
  /// `tool.execute` needs the actual futures. [toolStopSignal] is the
  /// either-signal stop future the run loop computes
  /// (`Future.any([cancelSignal, toolInterruptSignal])`) — tools must stop
  /// for either; choosing the interrupt alone would mask ordinary
  /// cancellation when the host supplies both.
  final Future<void>? cancelSignal;
  final Future<void>? toolInterruptSignal;

  /// The either-signal tool stop future (see [cancelSignal]).
  final Future<void>? toolStopSignal;

  /// Extra deny-preserving guards beyond the mandatory policy and phase
  /// guards ([PolicyToolGuard], [RegistryPhaseGuard]). Checked in order after
  /// those two at every gate ([combineGuardBlocks]); empty by default, which
  /// preserves the pre-guard behavior exactly.
  final List<ToolGuard> executionGuards;

  /// AROUND-execution hooks ([ToolExecutionHook]), awaited in order around
  /// the actual `executionTool.execute(...)` call only — the guard gates and
  /// the dispatch-boundary guard recheck stay outside the wrapper, exactly
  /// where they are. The FIRST hook is the outermost wrapper. Exactly-once
  /// delegation is enforced per hook (fail closed — see [ToolExecutionHook]);
  /// empty by default, which preserves the pre-hook behavior exactly.
  final List<ToolExecutionHook> executionHooks;

  /// POST-tool hooks ([ToolResultHook]) plus the legacy verifier, run in
  /// order on a successful result: the verifier (adapted as
  /// [_VerifierHook], so `Agent.resultVerifier` keeps its exact API and
  /// behavior) runs first, then these, first-verdict-wins /
  /// crash-logs-and-skips — the verifier-gate semantics, unchanged.
  final List<ToolResultHook> resultHooks;

  /// OBSERVATION-only hooks ([ToolObserver]), notified additively at the
  /// existing toolStart / toolOutput / toolComplete points, each call
  /// individually exception-contained — an observer can never change
  /// execution. The sink calls themselves are UNCHANGED;
  /// [AgentSink] implementations (and BusSink) remain the built-in
  /// observe-only adapters. Empty by default.
  final List<ToolObserver> observers;

  /// Batch-scope attribution mirror (#31): the executor's copy of the run
  /// loop's batch-local `interruptedCallIndex`. One step produces exactly
  /// one tool-result batch, so a [ToolCallState.step] change is a batch
  /// boundary; the mirror is re-seeded there from the same
  /// [ToolCallState.toolInterrupted] sample the run loop's own batch header
  /// uses, so the two can never disagree. The header's
  /// [kOperatorInterruptedLine] notice itself stays in Agent._runTurn (it
  /// fires even when the whole batch is skipped) — this mirror only answers
  /// "may the in-flight re-sample fire for this call yet".
  int _interruptedCallIndex = -1;
  int? _batchStep;

  ToolExecutor({
    required this.policy,
    required this.asker,
    required this.sink,
    required this.state,
    this.resultVerifier,
    this.cancelSignal,
    this.toolInterruptSignal,
    this.toolStopSignal,
    this.executionGuards = const [],
    this.executionHooks = const [],
    this.resultHooks = const [],
    this.observers = const [],
  });

  /// Dispatch ONE tool call ([use]) against the step's [stepTools] snapshot.
  /// Every path returns EXACTLY ONE result — the block the batch appends for
  /// this call — plus the #31 in-flight flag.
  Future<ToolCallOutcome> execute({
    required ToolUseBlock use,
    required ToolRegistry stepTools,
    required int step,
    required bool Function() isCancelled,
  }) async {
    // Batch-scope attribution mirror reset: see [_interruptedCallIndex].
    if (step != _batchStep) {
      _batchStep = step;
      _interruptedCallIndex = state.toolInterrupted ? 0 : -1;
    }
    // Whether the operator interrupt (#31) landed while THIS call was in
    // flight — set by the re-sample below, reported on every exit path.
    var interruptedInFlight = false;
    // The model's tool-call arguments were not valid JSON (tin-p2sq: a
    // quote-heavy shell one-liner it failed to escape). The tool cannot
    // run, but the turn need not die: answer the call with an error the
    // model can act on, and let the next step re-emit it correctly.
    final parseError = use.argumentsParseError;
    if (parseError != null) {
      sink.notice(
          '  ${use.name}: malformed arguments — asking the model to '
          'retry\n',
          kind: NoticeKind.warning);
      return (
        result: ToolResultBlock(
          toolUseId: use.id,
          content: 'Your ${use.name} call was discarded: its arguments '
              'were not valid JSON ($parseError). This usually means '
              'quotes or backslashes in the command text were not escaped '
              'for JSON — re-emit the call with '
              r'inner double quotes written as \" and each literal '
              r'backslash as \\.',
          isError: true,
        ),
        interruptedInFlight: interruptedInFlight,
      );
    }
    final tool = stepTools[use.name];
    if (tool == null) {
      sink.notice('  unknown tool: ${use.name}\n', kind: NoticeKind.error);
      return (
        result: ToolResultBlock(
          toolUseId: use.id,
          content: 'Unknown tool: ${use.name}',
          isError: true,
        ),
        interruptedInFlight: interruptedInFlight,
      );
    }

    // One ordered guard chain shared by the three gates below (initial,
    // post-approval, dispatch boundary): mandatory policy guard, then the
    // phase guard over this step's registry view, then any extra guards.
    // [combineGuardBlocks] combines by denial — the FIRST non-null block
    // wins and a throwing guard fails closed — so policy-then-phase
    // preserves the old
    // `policy.executionBlock ?? stepTools.executionBlock` precedence
    // exactly, with extras checked only after both allowed.
    String? runtimeBlock() => combineGuardBlocks([
          PolicyToolGuard(policy),
          RegistryPhaseGuard(stepTools),
          ...executionGuards,
        ], use.name, use.input);
    final initialBlock = runtimeBlock();
    if (initialBlock != null) {
      sink.notice('$initialBlock\n', kind: NoticeKind.warning);
      return (
        result: ToolResultBlock(
            toolUseId: use.id, content: initialBlock, isError: true),
        interruptedInFlight: interruptedInFlight,
      );
    }
    var decision = tool is LocalControlTool
        ? PermissionDecision.allow
        : policy.check(use.name, use.input);
    Tool executionTool = tool;
    // Fix (P1, sealed arguments): ONE detached snapshot taken BEFORE
    // authorization; every later reader — the policy re-checks, the approval
    // prompt, the hooks' context, the observers' event, and the tool itself —
    // sees exactly these values. A caller mutating its original map during an
    // approval wait (or a hook mutating what it can see) cannot change what
    // executes. The snapshot is NEVER refreshed from the live input after the
    // wait — approval seals the decision, not new arguments — and the
    // sandbox-retry merge (below) builds its snapshot from this one before
    // the ask, so the explicit retry authorization path is preserved.
    var executionInput = snapshotToolInput(use.input);
    // What the hooks and observers may see: a deeply unmodifiable view of the
    // SAME snapshot — built once, after the retry merge, so it reflects the
    // arguments that will actually run.
    Map<String, dynamic> executionView = asDeepUnmodifiable(executionInput);
    final retryKey = tool is BashTool
        ? jsonEncode([
            optionalString(use.input, 'command')?.trim(),
            p.normalize(resolveToolPath(
                optionalString(use.input, 'cwd') ?? tool.projectRoot ?? '.',
                tool.projectRoot)),
          ])
        : null;
    final recovery = state.sandboxFailures[retryKey];
    String? retrySafety;
    SandboxAccessRequest? access;
    try {
      if (decision != PermissionDecision.deny && tool is BashTool) {
        if (recovery != null) {
          if (state.deniedSandboxRetries.contains(retryKey)) {
            throw const ToolValidationException(
                'The user denied this sandbox retry. Do not request it again this turn; proceed without this access.');
          }
          if (state.promptedSandboxRetries.contains(retryKey)) {
            throw const ToolValidationException(
                'The approved sandbox retry also failed. Do not keep requesting approval; investigate the failure and report it to the user.');
          }
          if (step <= recovery.step) {
            throw const ToolValidationException(
                'Inspect the sandbox failure and possible partial effects before submitting a retry in a subsequent step.');
          }
          retrySafety = requiredString(use.input, 'retrySafety').trim();
          if (retrySafety.isEmpty ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(retrySafety)) {
            throw const ToolValidationException(
                'retrySafety must explain the partial-effects checks and why replay is safe, on one line.');
          }
          final requested = use.input['writablePaths'] ?? const [];
          if (requested is! List ||
              requested.any((path) => path is! String)) {
            throw const ToolValidationException(
                'writablePaths must be a list of directory paths.');
          }
          executionInput = {
            ...executionInput,
            'writablePaths': {
              ...recovery.priorPaths,
              ...recovery.failure.writablePaths,
              ...requested
            }.toList(),
            'accessReason': optionalString(use.input, 'accessReason') ??
                'Retry the failed command with access to the directory named in its read-only filesystem error.',
          };
          // The hook/observer view tracks the merged snapshot — still the
          // one sealed snapshot's lineage, still built BEFORE the ask.
          executionView = asDeepUnmodifiable(executionInput);
        }
        access = tool.requestAccess(executionInput);
        // A retry is explicit even if another agent granted the directory
        // while this agent was inspecting partial effects.
        if (recovery != null) {
          access ??= SandboxAccessRequest(recovery.failure.writablePaths,
              executionInput['accessReason'] as String);
        }
        if (access != null) {
          if (access.paths.any((path) =>
              state.deniedSandboxDirectories.any((denied) =>
                  path == denied ||
                  p.isWithin(denied, path) ||
                  p.isWithin(path, denied)))) {
            throw const ToolValidationException(
                'The user denied writable access to this directory this turn. Do not request it again under another command.');
          }
          decision = PermissionDecision.ask;
        }
      }
    } on ToolValidationException catch (e) {
      return (
        result: ToolResultBlock(
            toolUseId: use.id, content: e.message, isError: true),
        interruptedInFlight: interruptedInFlight,
      );
    }
    // The asker's response, when the decision went through the asker
    // (ask → refused). Null for a static deny RULE — a rule deny is a
    // policy choice; the allowed-shapes text is its remedy, so no asker
    // note is expected there.
    PermissionResponse? resp;
    String? changedModeBlock;
    if (decision == PermissionDecision.ask) {
      final prompt = PermissionPrompt(use.name, executionInput,
          sandboxAccess: access,
          retryExplanation: recovery?.failure.explanation,
          retrySafety: retrySafety);
      if (recovery != null) state.promptedSandboxRetries.add(retryKey!);
      resp = await asker(prompt);
      changedModeBlock = runtimeBlock();
      decision = changedModeBlock == null &&
              resp.decision == PermissionDecision.allow &&
              !isCancelled() &&
              !state.toolInterrupted
          ? PermissionDecision.allow
          : PermissionDecision.deny;
      if (changedModeBlock == null &&
          resp.remember &&
          access == null &&
          !isCancelled() &&
          !state.toolInterrupted) {
        policy.remember(use.name, prompt.alwaysPattern, decision);
      }
      // Sealed arguments: the snapshot taken BEFORE authorization stays the
      // one truth for the whole dispatch — nothing is re-read from the live
      // input after the approval wait. Re-snapshotting here let a caller
      // mutate its original map while the asker was pending and swap what a
      // JUST-APPROVED call would execute (a probe got "approved" approved and
      // ran "unapproved", past a deny rule covering it). The merged
      // sandbox-retry snapshot was already re-derived from the recovery
      // record + the sealed snapshot BEFORE the ask, so both branches of the
      // old re-snapshot are simply gone: approval changes the DECISION, never
      // the arguments.
    }
    if (decision == PermissionDecision.deny) {
      if (recovery != null) state.deniedSandboxRetries.add(retryKey!);
      if (access != null) state.deniedSandboxDirectories.addAll(access.paths);
      sink.notice('  ${use.name} denied\n');
      // Circuit breaker (#27): a model that keeps re-denying the SAME
      // tool never gets new information from the plain denial text, and
      // the asker's own refusal hint only went to stderr — so it spun
      // (12 wasted steps in Run A; 11 in the probe run). Past the
      // threshold the denial result itself says "stop calling this".
      final denials = (state.denialCounts[use.name] ?? 0) + 1;
      state.denialCounts[use.name] = denials;
      var content = changedModeBlock ??
          (access == null
              ? deniedContent(policy, use.name)
              : 'Command and additional writable directory access denied. '
                  'The command was not executed. Proceed without this access.');
      final note = resp?.note;
      if (note != null && note.isNotEmpty) {
        content = '$content\n$note';
      }
      if (denials >= consecutiveDenialNoticeThreshold) {
        content =
            '$content\nNOTE: $denials consecutive ${use.name} denials '
            'this turn — this tool will keep being refused. Stop calling '
            'it; proceed with the allowed tools or answer from what you '
            'have.';
        sink.notice(
            '  ${use.name}: $denials consecutive denials this turn — '
            'circuit-breaker notice attached to the denial result\n',
            kind: NoticeKind.warning);
      }
      return (
        result: ToolResultBlock(
          toolUseId: use.id,
          content: content,
          isError: true,
        ),
        interruptedInFlight: interruptedInFlight,
      );
    }

    if (access != null) {
      try {
        executionTool = (tool as BashTool)
            .withApprovedAccess(access, remember: resp?.remember ?? false);
      } on ToolValidationException catch (e) {
        return (
          result: ToolResultBlock(
              toolUseId: use.id, content: e.message, isError: true),
          interruptedInFlight: interruptedInFlight,
        );
      }
    }

    // An ALLOWED call resets this tool's denial streak — the policy
    // let the shape through, so the refusal pattern it was counting is
    // over (whether the execution then succeeds or errors).
    state.denialCounts.remove(use.name);
    // Observation is additive: the sink call is unchanged (AgentSink /
    // BusSink remain the built-in observe-only adapters); observers get the
    // same payload, each individually exception-contained. The payload is the
    // unmodifiable VIEW — an event consumer that tries to mutate an argument
    // throws instead of silently changing what the tool executes.
    sink.toolStart(ToolStartEvent(use.name, use.id, executionView));
    _notifyObservers((observer) =>
        observer.onToolStart(ToolStartEvent(use.name, use.id, executionView)));
    try {
      // #31: while THIS call runs, the operator interrupt rides the
      // tool's existing cancel seam — bash kills via its existing
      // cancel path; no new kill path is added. The agent-level cancel
      // semantics ([cancelled]) are untouched: an interrupt is NOT a
      // cancel. Runs without the feature keep the same shape as before
      // it: the run's own (non-null) cancel signal.
      final effectiveCancelSignal = state.toolInterrupted
          ? cancelSignal
          : (toolStopSignal ?? toolInterruptSignal ?? cancelSignal);
      // The final authority + cancellation check lives INSIDE the innermost
      // delegate (P1: recheck authority at actual dispatch): the pre-hook
      // check stays above for fast rejection, but a hook that waits
      // asynchronously can no longer slip a mode change, phase change, or
      // cancel past it — the last thing that happens before `execute` is the
      // same mandatory guard chain, with no await between the check and the
      // tool call. The operator INTERRUPT is deliberately absent here (#31):
      // it is not a cancel — the batch's in-flight call must still execute
      // honestly (its result is what the interrupted prefix lands over), and
      // the interrupt reaches the tool through [effectiveCancelSignal].
      //
      // Formatting and event shape are unchanged: one toolComplete event, an
      // error result — a blocked call never invokes the tool and never
      // requests fresh approval.
      Future<ToolResult> dispatch() {
        final finalBlock = runtimeBlock();
        if (finalBlock != null) {
          return Future<ToolResult>.value(ToolResult(finalBlock,
              isError: true));
        }
        if (isCancelled()) {
          return Future<ToolResult>.value(
              ToolResult('tool ${use.name} cancelled', isError: true));
        }
        return executionTool.execute(
          executionInput,
          cancelSignal: effectiveCancelSignal,
          onOutput: (chunk, {bool stderr = false}) {
            sink.toolOutput(
                ToolOutputEvent(use.name, use.id, chunk, stderr: stderr));
            _notifyObservers((observer) => observer.onToolOutput(
                ToolOutputEvent(use.name, use.id, chunk, stderr: stderr)));
          },
        );
      }

      final out = await _runWithExecutionHooks(
        toolName: use.name,
        toolId: use.id,
        input: executionView,
        isCancelled: isCancelled,
        delegate: dispatch,
      );
      if (retryKey != null &&
          out is BashToolResult &&
          out.sandboxFailure != null &&
          !isCancelled() &&
          !state.toolInterrupted) {
        state.sandboxFailures.putIfAbsent(
            retryKey,
            () => (
                  failure: out.sandboxFailure!,
                  step: step,
                  priorPaths: List<String>.from(
                      executionInput['writablePaths'] as List? ?? const [])
                ));
        sink.notice(
            '${out.sandboxFailure!.explanation}\n'
            'The agent must check partial effects before requesting approval to retry.\n',
            kind: NoticeKind.warning);
      } else if (!out.isError && retryKey != null) {
        state.sandboxFailures.remove(retryKey);
      }
      // #31: the interrupt is re-sampled right after EVERY call, not
      // only at batch start — a signal that fired while THIS call was
      // in flight makes it the in-flight one: its result is the one the
      // post-batch stamp prefixes, and every LATER call of the batch
      // stubs without executing. Sampled before ANY result-shipping
      // path runs (verifier block, plain add, thrown-tool catch adds
      // from its own path), so the flag is already settled when this
      // call's result ships below. The batch-local `interruptedCallIndex`
      // the original read lives in Agent._runTurn; the mirror
      // [_interruptedCallIndex] answers the same `< 0` question (it is
      // seeded to 0 — never negative — exactly when the batch began
      // already-interrupted, the case where this path must not fire).
      if (_interruptedCallIndex < 0 && state.toolInterrupted) {
        _interruptedCallIndex = 0;
        sink.notice('$kOperatorInterruptedLine\n');
        interruptedInFlight = true;
      }
      // #29 retry guard, BEFORE anything mutates the result content: the
      // identical-error class must compare what the tool actually
      // returned last time, not last time plus an appended guardrail
      // note (the note would otherwise make identical failures look
      // changed).
      final sig = anomalySignature(use.name, use.input);
      final anomaly = isAnomalousResult(
        out,
        previousContent: state.previousAttemptContent[sig],
      );
      state.previousAttemptContent[sig] = out.content;
      final streak =
          anomaly ? (state.consecutiveAnomalyCounts[sig] ?? 0) + 1 : 0;
      if (anomaly) {
        state.consecutiveAnomalyCounts[sig] = streak;
      } else {
        state.consecutiveAnomalyCounts.remove(sig);
      }
      // Ride the note on every anomaly from the threshold on; the
      // operator notice fires exactly once, on the crossing.
      var content = out.content;
      if (anomaly && streak >= consecutiveAnomalyNoticeThreshold) {
        content = '$content\n$anomalyGuardrailNote';
        if (streak == consecutiveAnomalyNoticeThreshold) {
          sink.notice(
            '${use.name} hit $consecutiveAnomalyNoticeThreshold '
            'consecutive anomalies this turn (timeout / empty output / '
            'identical error) — guardrail note attached\n',
            kind: NoticeKind.warning,
          );
        }
      }
      // Operator interrupt (#31): this call was in flight when the
      // signal fired. The operator line is stamped onto the FIRST
      // result after the batch loop (one site, every result path), so
      // here the text ships as the tool produced it.
      sink.toolComplete(ToolCompleteEvent(use.name, use.id,
          isError: out.isError, result: content));
      _notifyObservers((observer) => observer.onToolComplete(
          ToolCompleteEvent(use.name, use.id,
              isError: out.isError, result: content)));
      // Post-tool stage: the success-only gate (#22a), now as hooks. The
      // legacy verifier runs first (adapted as [_VerifierHook], which
      // calls it with (name, input) and ignores the result — so
      // `Agent.resultVerifier` keeps its exact public API and behavior),
      // then any declared [ToolResultHook]s, in declared order. Exactly
      // today's semantics: the FIRST non-null verdict is appended to the
      // result content and the rest are skipped; a throwing hook is
      // logged and processing continues with the content unchanged. Error
      // results, the parse-error / unknown-tool / denied / thrown paths
      // above all skip the stage, and it never fires when the batch is
      // operator-interrupted.
      if (!out.isError && !state.toolInterrupted) {
        content = await _runResultHooks(
          toolName: use.name,
          input: use.input,
          result: ToolResultBlock(
            toolUseId: use.id,
            content: content,
            isError: out.isError,
          ),
          hooks: [
            if (resultVerifier != null) _VerifierHook(resultVerifier!),
            ...resultHooks,
          ],
        );
      }
      return (
        result: ToolResultBlock(
          toolUseId: use.id,
          content: content,
          isError: out.isError,
        ),
        interruptedInFlight: interruptedInFlight,
      );
    } catch (e, st) {
      // Route thrown-tool failures through the same toolComplete path so
      // a tool strip / observer learns about them too. (Previously this
      // printed the bare exception; it now renders like an error result.)
      _log.severe('unhandled exception in tool ${use.name}', e, st);
      sink.toolComplete(ToolCompleteEvent(use.name, use.id,
          isError: true, result: e.toString()));
      _notifyObservers((observer) => observer.onToolComplete(
          ToolCompleteEvent(use.name, use.id,
              isError: true, result: e.toString())));
      return (
        result: ToolResultBlock(
          toolUseId: use.id,
          content: e.toString(),
          isError: true,
        ),
        interruptedInFlight: interruptedInFlight,
      );
    }
  }

  /// Runs the AROUND-execution hook chain around [delegate]. The FIRST
  /// declared hook is the outermost wrapper (`hooks.reversed.fold`); the
  /// guard gates and the dispatch-boundary guard recheck stay OUTSIDE this
  /// wrapper, exactly where they are today (moving the recheck inside the
  /// delegate is deliberately deferred until a real preparation hook needs
  /// it — there is no async preparation between recheck and execute, so the
  /// order is unobservable).
  ///
  /// Each hook's [delegate] is exactly-once and fail closed:
  ///  * a second delegation throws, and ANY hook error is converted into an
  ///    error tool result;
  ///  * a hook that returns WITHOUT delegating becomes an error tool result
  ///    (`hook did not execute the tool`).
  /// The delegate closure captures the tool, the input, the effective cancel
  /// signal, and the output routing — a hook cannot swap the tool identity
  /// or arguments and cannot detach cancellation.
  Future<ToolResult> _runWithExecutionHooks({
    required String toolName,
    required String toolId,
    required Map<String, dynamic> input,
    required bool Function() isCancelled,
    required Future<ToolResult> Function() delegate,
  }) async {
    Future<ToolResult> chain(int index) async {
      if (index >= executionHooks.length) return delegate();
      final hook = executionHooks[index];
      final handle = _HookDelegate(toolName, () => chain(index + 1));

      ToolResult result;
      try {
        result = await hook.run(
          ToolCallContext(
            toolName: toolName,
            toolId: toolId,
            input: input,
            isCancelled: isCancelled,
          ),
          handle.call,
        );
      } on _DelegateFailure catch (f) {
        // The delegate chain failed and the hook let it through. Join the
        // work first (it is settled — its failure IS this failure), ship the
        // delegate's real failure, and keep the original stack trace when
        // the join somehow finds nothing.
        handle.close();
        final joined = await _joinDelegate(handle);
        if (joined != null) return joined;
        Error.throwWithStackTrace(f.error, f.stackTrace);
      } catch (e, st) {
        handle.close();
        // Fix (P1, join on every exit): the hook threw AFTER starting its
        // delegation and swallowed the rejection. Join the started work
        // BEFORE reporting — a swallowed second call must not orphan the
        // first execution. A delegate failure ships as the call result; a
        // delegate success keeps flowing to the fail-closed exits below.
        final joined = await _joinDelegate(handle);
        if (joined != null) return joined;
        if (handle.repeatAttempt) {
          // The hook swallowed its own double-delegation rejection:
          // exactly-once is still observable to the executor.
          _log.warning('execution hook for $toolName called the delegate '
              'more than once — failing the tool call closed', e, st);
          return ToolResult(
            'tool execution hook failed: execution hook for $toolName '
            'called the delegate more than once',
            isError: true,
          );
        }
        _log.warning('execution hook for $toolName failed — failing the '
            'tool call closed', e, st);
        return ToolResult(
          'tool execution hook failed: $e',
          isError: true,
        );
      } finally {
        handle.close();
      }
      // Fail closed on BOTH exactly-once violations, even when the hook
      // swallowed the throw above: zero delegations (`hook did not execute
      // the tool`) or more than one.
      if (handle.repeatAttempt) {
        // Fix (P1, join on every exit): the first execution already started
        // before the repeat call was rejected — join it before failing the
        // call, so a swallowed rejection cannot orphan running work behind a
        // reported failure. A delegate failure ships as the call result.
        _log.warning('execution hook for $toolName called the delegate '
            'more than once — failing the tool call closed');
        final joined = await _joinDelegate(handle);
        if (joined != null) return joined;
        return ToolResult(
          'tool execution hook failed: execution hook for $toolName called '
          'the delegate more than once',
          isError: true,
        );
      }
      if (handle.future == null) {
        _log.warning('execution hook for $toolName did not execute the '
            'tool — failing the tool call closed');
        return ToolResult(
          'tool execution hook failed: execution hook for $toolName did '
          'not execute the tool',
          isError: true,
        );
      }
      // Join: the delegated work settles BEFORE the executor reports, emits
      // completion, or allows teardown downstream of this call. Null means
      // the work succeeded and the hook's returned — possibly transformed —
      // result stands; a rendered failure result ships instead.
      final joined = await _joinDelegate(handle);
      return joined ?? result;
    }

    return chain(0);
  }

  /// Awaits the delegate handle's started work, if any. Returns null when
  /// the work SUCCEEDED — the caller keeps its own result (the hook's
  /// returned, possibly transformed, result stands). Returns an error
  /// [ToolResult] when the work FAILED, rendered exactly like the
  /// executor's thrown-tool path (`e.toString()`), so a hook that returns
  /// without awaiting its delegation still ships the real tool failure.
  /// Never throws; this join and the handle's own observation are the only
  /// consumers, so no failure escapes as an unhandled async error.
  Future<ToolResult?> _joinDelegate(_HookDelegate handle) async {
    final work = handle.future;
    if (work == null) return null;
    try {
      await work;
      return null;
    } on _DelegateFailure catch (f) {
      _log.warning('delegated tool work failed — shipping the delegate '
          'failure as the call result', f.error, f.stackTrace);
      return ToolResult(f.error.toString(), isError: true);
    }
  }

  /// Runs the POST-tool stage: the legacy verifier (adapted as
  /// [_VerifierHook], first) plus the declared [ToolResultHook]s, in order.
  /// The FIRST non-null verdict is appended to the result content and the
  /// rest are skipped; a throwing hook is logged and processing continues
  /// with the content unchanged.
  Future<String> _runResultHooks({
    required String toolName,
    required Map<String, dynamic> input,
    required ToolResultBlock result,
    required List<ToolResultHook> hooks,
  }) async {
    var content = result.content;
    for (final hook in hooks) {
      try {
        final verdict = await hook.process(
          toolName,
          input,
          ToolResult(content, isError: result.isError),
        );
        if (verdict != null && verdict.isNotEmpty) {
          return '$content\n$verdict';
        }
      } catch (e, st) {
        _log.warning(
            'result hook for $toolName failed — shipping the '
            'tool content unchanged',
            e,
            st);
      }
    }
    return content;
  }

  /// Notifies every observer through [body], each call individually
  /// exception-contained — observers are notify-only and can never change
  /// execution.
  void _notifyObservers(void Function(ToolObserver observer) body) {
    for (final observer in observers) {
      try {
        body(observer);
      } catch (e, st) {
        _log.warning('tool observer failed — continuing', e, st);
      }
    }
  }
}

/// Adapter that presents the legacy `Agent.resultVerifier` as the first
/// [ToolResultHook] of the post-tool stage: it calls the verifier with
/// (name, input) and ignores the hook's (toolName, input, result) arguments —
/// so `Agent.resultVerifier` keeps its exact public API and behavior.
class _VerifierHook implements ToolResultHook {
  final ToolResultVerifier verifier;

  const _VerifierHook(this.verifier);

  @override
  Future<String?> process(
      String toolName, Map<String, dynamic> input, ToolResult result) {
    return verifier(toolName, input);
  }
}
