import 'policy.dart';
import '../tools/execution_request.dart';
import '../tools/edit_preparation.dart';
import 'sandbox_access.dart';

class PermissionPrompt {
  final String toolName;
  final Map<String, dynamic> input;
  final SandboxAccessRequest? sandboxAccess;
  final ExecutionRequest? execution;
  final PreparedEdit? preparedEdit;
  final String? retryExplanation;
  final String? retrySafety;
  /// Separate user authorization; never satisfied by ordinary command rules.
  final bool outsideSandbox;
  /// Settle the prompt and release any keyboard ownership when its turn stops.
  final Future<void>? cancelSignal;
  const PermissionPrompt(this.toolName, this.input,
      {this.sandboxAccess, this.retryExplanation, this.retrySafety, this.execution, this.preparedEdit,
      this.outsideSandbox = false, this.cancelSignal});

  String get approvalRow => sandboxAccess == null
      ? outsideSandbox
          ? '  approve? [y] outside once [a] outside for session [d] deny › '
          : approvalPromptRow(alwaysPattern)
      : '  approve? [y] once [a] session directories [n] deny › ';

  String get accessDescription {
    if (outsideSandbox) {
      return '  ${retryExplanation ?? "The sandbox blocked the command."}\n'
          '  This command might touch files on the filesystem. '
          'Are you definitely OK to run it outside the sandbox?\n'
          '  It will have your user account’s filesystem and network access. '
          'The first attempt may have made partial changes; retrying repeats the entire command.\n'
          '  y: this retry only; a: this exact command, cwd and environment '
          'outside the sandbox for this running session, including its agents. '
          'Other commands still use the sandbox; nothing is saved to disk.\n';
    }
    final access = sandboxAccess;
    if (access == null) return '';
    final retry = retryExplanation;
    final assessment = retrySafety == null
        ? ''
        : '  Agent’s partial-effects assessment: $retrySafety\n';
    final context = retry == null
        ? assessment
        : '  $retry\n$assessment'
            '  Allow these directories so the command can be retried?\n';
    return '${context}  Additional writable directories (including contents):\n'
        '${access.paths.map((path) => '    $path\n').join()}'
        '  Reason: ${access.reason}\n'
        '  y: this command only; a: directories shared by this project’s agents '
        'for this session. The command is approved once.\n';
  }

  String get key => PermissionPolicy.keyFor(toolName, input);
  String get alwaysPattern =>
      PermissionPolicy.defaultAlwaysPatternFor(toolName, input);
}

class PermissionResponse {
  final PermissionDecision decision;

  /// If true and decision is allow/deny, the policy will add a session rule
  /// using the prompt's [PermissionPrompt.alwaysPattern]. For a sandbox access
  /// prompt, allow remembers only the directories for this project session.
  /// For outside-sandbox approval, allow remembers the exact prepared command,
  /// cwd and full environment separately from ordinary command rules.
  final bool remember;

  /// Optional model-facing explanation an auto-refusing asker supplies (e.g.
  /// headless non-interactive refusal). Appended to the denied tool result
  /// content when non-null.
  final String? note;

  /// Who produced this response: `'user'` (an interactive asker), `'classifier'`
  /// (permission mode `auto` deciding instead of the user), or `'headless'`
  /// (the non-interactive auto-refuse). Recorded in the approval audit line —
  /// once a verdict lands as a session rule, a classifier grant and a user
  /// grant are otherwise indistinguishable.
  final String decidedBy;

  const PermissionResponse(
    this.decision, {
    this.remember = false,
    this.note,
    this.decidedBy = 'user',
  });

  static const allowOnce = PermissionResponse(PermissionDecision.allow);
  static const denyOnce = PermissionResponse(PermissionDecision.deny);
  static const allowAlways =
      PermissionResponse(PermissionDecision.allow, remember: true);
  static const denyAlways =
      PermissionResponse(PermissionDecision.deny, remember: true);
}

typedef PermissionAsker = Future<PermissionResponse> Function(PermissionPrompt);

// --- Approval-prompt affordances (#51) -------------------------------------
//
// Shared by BOTH interactive askers (TuiConversationHost.askPermission and
// WorkflowPermissionAsker._ask) so the two prompts cannot drift: the key
// meanings, the mode chip, and the ignored-key ack are one definition.

/// The interactive approval row. Spells out what each key DECIDES (#51a) —
/// the old `[y/n/a/d] (a/d remember …)` said the answers were remembered,
/// never that `a` allows and `d` denies. [alwaysPattern] names the scope an
/// "always" answer will remember. Kept compact: the row plus the user's
/// one-char answer must fit a 76-column chat region on one line — a wrapped
/// prompt row displaces the answer echo (and the `esc\n` deny echo) onto a
/// second line, where neither reads as the answer.
String approvalPromptRow(String alwaysPattern) =>
    '  approve? [y]es [n]o [a]lways allow [d]eny always '
    '(a/d: "$alwaysPattern") › ';

/// Dim annotation for an ask's header: the active permission mode (#51b).
/// The TUI has no persistent footer bar — outside the transient Shift+Tab /
/// `/permissions` messages, an approval is the only place the mode is ever
/// visible, so each ask carries the chip.
String permissionModeChip(PermissionMode mode) => '[mode: ${mode.label}]';

/// Acknowledgement echoed (dimmed) when the FIRST key that is not an answer
/// reaches an armed ask (#51c): proof the prompt is alive and swallowing
/// keys. Later ignored keys stay silent so scrollback can't be flooded —
/// exactly one ack per ask.
const String ignoredKeyAck = '…';
