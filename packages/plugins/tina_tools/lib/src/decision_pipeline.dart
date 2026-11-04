/// The decision pipeline: one precedence implementation.
///
/// Every permission check for a command funnels through [decidePermission]:
/// the capability envelope (what the command touches), the scopes (what is
/// already approved), and sandbox feasibility (can a backend hold the
/// command inside those scopes) produce one of three outcomes —
///
/// - [PermissionOutcome.run]: the mechanical layer answered. No model, no
///   ask. Everything touched sits inside an approved scope and the sandbox
///   can keep it there.
/// - [PermissionOutcome.refuse]: fail closed. No enforcing backend means
///   refuse, even for certified readers with a grant — a grant authorizes,
///   it never confines.
/// - [PermissionOutcome.judgment]: everything else. Interactive mode asks
///   the user; auto mode asks the classifier. Destructive commands always
///   land here — a table verdict routes to judgment, never a silent run.
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

/// One precedence, in order:
///
/// 1. Destructive table verdict → judgment (batched/denied there per mode).
/// 2. Network or host execution requested → judgment (unconfined execution
///    is human-only; the classifier denies and batches it).
/// 3. No enforcing backend ([confined] false) → refuse, fail closed. The
///    grant authorizes the read; it does not remove the need for a backend
///    that can confine execution.
/// 4. Everything the command touches inside approved scopes → run. This
///    covers certified readers with grant-covered paths, and the
///    agent-created-script fast path: a script this session created,
///    executed confined to workspace + temp with no network and no paths
///    outside approved scopes.
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
  // The sandbox fast path: the agent wrote this script itself, this session,
  // and runs it confined. The sandbox holds it inside workspace + temp; no
  // ask needed for the execution itself. Writes the script performs still
  // ride the sandbox's own enforcement.
  if (agentCreatedScript &&
      envelope.reads.every((path) => scopes.canRead(path)) &&
      envelope.argumentPaths.every((path) => scopes.canRead(path)) &&
      envelope.writes.every((path) => scopes.canWrite(path))) {
    return const PermissionDecision._(PermissionOutcome.run,
        'agent-created script inside workspace and temp');
  }

  // The certified-reader fast path: a pinned read-only pipeline whose every
  // touched path sits inside a granted read or write scope. The certification
  // pins capability; the grants carry authorization; the backend enforces.
  final readTouches = {...envelope.reads, ...envelope.argumentPaths};
  if (envelope.certifiedReadOnly &&
      readTouches.isNotEmpty &&
      readTouches.every((path) => scopes.canRead(path)) &&
      envelope.writes.isEmpty) {
    return const PermissionDecision._(PermissionOutcome.run,
        'certified reader inside granted scopes');
  }

  // Unknown commands with effects: judgment decides scope questions.
  return const PermissionDecision._(
      PermissionOutcome.judgment, 'uncovered effects');
}
