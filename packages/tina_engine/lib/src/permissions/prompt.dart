import 'approval_target.dart';
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

  /// The answers this prompt offers, in the order the row shows them: each key,
  /// what it says, and what answering it means.
  ///
  /// ONE list, so the row the asker prints, the keys it accepts, and the scope
  /// and rule a remembered answer is filed under cannot drift apart. The engine
  /// used to specify a row (see the old `approvalPromptRow`) that neither asker
  /// rendered, which is how the chat asker came to advertise a deny key that did
  /// nothing: for a sandbox-access prompt it printed `[d] deny`, ignored `d`, and
  /// offered the real deny (`n`) nowhere.
  List<ApprovalChoice> get choices {
    if (outsideSandbox) {
      return const [
        ApprovalChoice(
          key: 'y',
          label: 'run outside sandbox once',
          decision: PermissionDecision.allow,
        ),
        ApprovalChoice(
          key: 'a',
          label: 'outside for session',
          decision: PermissionDecision.allow,
          remember: true,
          scope: GrantScope.sessionOutside,
        ),
        ApprovalChoice(
          key: 'd',
          label: 'deny',
          decision: PermissionDecision.deny,
        ),
      ];
    }
    if (sandboxAccess != null) {
      return const [
        ApprovalChoice(
          key: 'y',
          label: 'allow once',
          decision: PermissionDecision.allow,
        ),
        ApprovalChoice(
          key: 'a',
          label: 'session directories',
          decision: PermissionDecision.allow,
          remember: true,
          scope: GrantScope.sessionDirectories,
        ),
        ApprovalChoice(
          key: 'n',
          label: 'deny',
          decision: PermissionDecision.deny,
        ),
      ];
    }
    return const [
      ApprovalChoice(
        key: 'y',
        label: 'allow once',
        decision: PermissionDecision.allow,
      ),
      ApprovalChoice(
        key: 'n',
        label: 'deny once',
        decision: PermissionDecision.deny,
      ),
      ApprovalChoice(
        key: 'a',
        label: 'allow always',
        decision: PermissionDecision.allow,
        remember: true,
        scope: GrantScope.conversation,
      ),
      ApprovalChoice(
        key: 'd',
        label: 'deny always',
        decision: PermissionDecision.deny,
        remember: true,
        scope: GrantScope.conversation,
      ),
    ];
  }

  /// The choice [key] answers, case-insensitively, or null when this prompt does
  /// not offer it — an unoffered key is ignored, never guessed at.
  ApprovalChoice? choiceForKey(String key) {
    final wanted = key.toLowerCase();
    for (final choice in choices) {
      if (choice.key == wanted) return choice;
    }
    return null;
  }

  /// The `[y] label [n] label …` text an asker frames into its row.
  String get approvalOptionsText =>
      [for (final choice in choices) '[${choice.key}] ${choice.label}'].join(' ');

  String get approvalRow => '  approve? $approvalOptionsText ‹ ';

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

  /// What this call is asking for, as the policy sees it. The header the asker
  /// shows and the rule an "always" answer installs both come from here, so they
  /// cannot disagree.
  ApprovalTarget get target => PermissionPolicy.targetFor(toolName, input);
  String get key => target.label;
  String get alwaysPattern => target.remember;

  /// What an "always" answer covers, in plain words, for the prompts whose own
  /// text does not already say it.
  ///
  /// The sandbox-access and outside-sandbox descriptions spell their scope out;
  /// the ordinary prompt said only "always allow", which reads as permanent and
  /// global when it is neither. Empty when [accessDescription] already covers it,
  /// so the note costs one dim line and says the thing that was missing.
  String get alwaysScopeNote {
    if (sandboxAccess != null || outsideSandbox) return '';
    // Both halves from the same list: which keys remember, and for how long.
    final remembering = [
      for (final choice in choices)
        if (choice.remember) '[${choice.key}]',
    ].join('/');
    final scope = choices.firstWhere((c) => c.remember).scope;
    return '  $remembering remember "$alwaysPattern" for ${scope.plainWords} — '
        'nothing is saved to disk.\n';
  }
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

  /// [decidedBy] as a grant source, for the policy to file the grant under. A
  /// headless refusal never grants, so it maps to [GrantSource.user] harmlessly.
  GrantSource get source =>
      decidedBy == 'classifier' ? GrantSource.classifier : GrantSource.user;

  /// How long this answer lasts. The asker sets it from the choice the user
  /// made, so the scope is a fact about the answer rather than something the
  /// executor re-derives from which prompt was on screen.
  final GrantScope scope;

  const PermissionResponse(
    this.decision, {
    this.remember = false,
    this.note,
    this.decidedBy = 'user',
    this.scope = GrantScope.call,
  });

  static const allowOnce = PermissionResponse(PermissionDecision.allow);
  static const denyOnce = PermissionResponse(PermissionDecision.deny);
  static const allowAlways = PermissionResponse(PermissionDecision.allow,
      remember: true, scope: GrantScope.conversation);
  static const denyAlways = PermissionResponse(PermissionDecision.deny,
      remember: true, scope: GrantScope.conversation);
}

typedef PermissionAsker = Future<PermissionResponse> Function(PermissionPrompt);

// --- Approval-prompt affordances (#51) -------------------------------------
//
// Shared by BOTH interactive askers (TuiConversationHost.askPermission and
// WorkflowPermissionAsker._ask) so the two prompts cannot drift: the key
// meanings, the mode chip, and the ignored-key ack are one definition.

/// One answer on the approval row: the key, what it says, and what it means.
///
/// [decision] and [remember] are the answer; [scope] is how long it lasts. The
/// row is built from these (see [PermissionPrompt.approvalOptionsText]), so what
/// the user is shown and what their key does are the same list.
class ApprovalChoice {
  final String key;
  final String label;
  final PermissionDecision decision;
  final bool remember;
  final GrantScope scope;

  const ApprovalChoice({
    required this.key,
    required this.label,
    required this.decision,
    this.remember = false,
    this.scope = GrantScope.call,
  });

  /// What answering this choice returns.
  PermissionResponse get response =>
      PermissionResponse(decision, remember: remember, scope: scope);

  @override
  String toString() => '[$key] $label';
}

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
