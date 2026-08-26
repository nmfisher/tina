import 'policy.dart';

class PermissionPrompt {
  final String toolName;
  final Map<String, dynamic> input;
  const PermissionPrompt(this.toolName, this.input);

  String get key => PermissionPolicy.keyFor(toolName, input);
  String get alwaysPattern =>
      PermissionPolicy.defaultAlwaysPatternFor(toolName, input);
}

class PermissionResponse {
  final PermissionDecision decision;

  /// If true and decision is allow/deny, the policy will add a session rule
  /// using the prompt's [PermissionPrompt.alwaysPattern].
  final bool remember;

  /// Optional model-facing explanation an auto-refusing asker supplies (e.g.
  /// headless non-interactive refusal). Appended to the denied tool result
  /// content when non-null.
  final String? note;

  const PermissionResponse(
    this.decision, {
    this.remember = false,
    this.note,
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
