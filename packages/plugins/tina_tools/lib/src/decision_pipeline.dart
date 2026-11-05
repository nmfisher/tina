/// The decision pipeline: one precedence implementation.
///
/// Every permission check for a command funnels through [decidePermission].
/// It takes the capability envelope (what the command touches), the scopes
/// (what is already approved), and sandbox feasibility (whether a backend
/// can hold the command inside those scopes). It returns one of three
/// outcomes:
///
/// - [PermissionOutcome.run]: the mechanical layer answered. No model, no
///   ask. Everything the command touches sits inside an approved scope,
///   and the sandbox can keep it there.
/// - [PermissionOutcome.refuse]: fail closed. When no enforcing backend is
///   available, refuse — even for a certified reader with a grant. A
///   grant allows the read; it does not make the run safe.
/// - [PermissionOutcome.judgment]: everything else. Interactive mode asks
///   the user. Auto mode asks the classifier. Destructive commands always
///   land here: a table verdict goes to judgment, never to a silent run.
///
/// Certified reads, command patterns, directory grants and MCP rules are
/// all inputs to this one function, expressed through the [ScopesView].
library;

import 'capability_envelope.dart';

/// What the pipeline decided, and why.
enum PermissionOutcome { run, refuse, judgment }

/// The scopes the pipeline matches against — the one scopes store seen from
/// the command side. Implemented by the runner over its plan and grants.
abstract interface class ScopesView {
  /// May the command read [path] (read grant, workspace, mounted scope)?
  bool canRead(String path);

  /// May the command write [path] (write grant, workspace, temp scratch)?
  bool canWrite(String path);

  /// Is [path] inside the sandbox plan at all (grantable, not necessarily
  /// granted)?
  bool withinPlan(String path);
}

/// The mechanical-layer verdict.
final class PermissionDecision {
  const PermissionDecision._(this.outcome, this.reason);

  /// The outcome.
  final PermissionOutcome outcome;

  /// Human-readable; also the refusal text on [PermissionOutcome.refuse].
  final String reason;

  /// Convenience predicates.
  bool get runs => outcome == PermissionOutcome.run;
  bool get refuses => outcome == PermissionOutcome.refuse;
  bool get needsJudgment => outcome == PermissionOutcome.judgment;
}

/// The precedence, one rule at a time:
///
/// 1. The command is destructive by table → judgment. Each mode then
///    batches or denies it.
/// 2. The command wants the network or host execution → judgment. Only a
///    human approves running without the sandbox. The classifier denies
///    and batches such requests.
/// 3. No enforcing backend ([confined] is false) → refuse. A grant allows
///    the read; it does not remove the need for a backend that can
///    confine execution.
/// 4. Everything the command touches sits inside approved scopes → run.
///    This covers certified readers with grant-covered paths. It also
///    covers the agent-created-script fast path: a script this session
///    created, executed confined to workspace and temp, with no network
///    and no paths outside approved scopes.
/// 5. Anything else → judgment.
PermissionDecision decidePermission(
  CapabilityEnvelope envelope, {
  required ScopesView scopes,
  required bool confined,
  required bool agentCreatedScript,
}) {
  if (envelope.destructive) {
    return const PermissionDecision._(
        PermissionOutcome.judgment, 'destructive operation');
  }
  if (envelope.network) {
    return const PermissionDecision._(
        PermissionOutcome.judgment, 'network access');
  }
  if (!confined) {
    return const PermissionDecision._(PermissionOutcome.refuse,
        'no enforcing sandbox backend: refusing, fail closed');
  }
  // The agent-script fast path: the agent wrote this script itself, this
  // session, and runs it confined. The sandbox holds it inside workspace
  // and temp, so the execution itself needs no question. Writes the script
  // performs are enforced by the sandbox.
  if (agentCreatedScript &&
      envelope.reads.every((path) => scopes.canRead(path)) &&
      envelope.argumentPaths.every((path) => scopes.canRead(path)) &&
      envelope.writes.every((path) => scopes.canWrite(path))) {
    return const PermissionDecision._(PermissionOutcome.run,
        'agent-created script inside workspace and temp');
  }

  // The certified-reader fast path: a pinned read-only pipeline, and every
  // path it touches sits inside a granted read scope. The certification
  // proves the command cannot write. The grants carry the user's approval.
  // The backend enforces both.
  final readTouches = {...envelope.reads, ...envelope.argumentPaths};
  if (envelope.certifiedReadOnly &&
      readTouches.isNotEmpty &&
      readTouches.every((path) => scopes.canRead(path)) &&
      envelope.writes.isEmpty) {
    return const PermissionDecision._(PermissionOutcome.run,
        'certified reader inside granted scopes');
  }

  // Anything else has effects the mechanical layer cannot clear. Judgment
  // decides whether the scopes cover them.
  return const PermissionDecision._(
      PermissionOutcome.judgment, 'uncovered effects');
}
