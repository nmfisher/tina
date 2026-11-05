/// The decision pipeline: one precedence implementation.
///
/// Every permission check for a command funnels through here.
/// [readOnlyProfileOf] computes the execution profile (the Layer-1 fast
/// paths live inside it); [decidePermission] returns the verdict. Inputs
/// are the capability envelope (what the command touches), the scopes
/// (what is already approved), sandbox feasibility (whether a backend can
/// confine the command), the mode, and the grant-coverage facts the caller
/// computes as plumbing. One of three outcomes:
///
/// - [PermissionOutcome.run]: the mechanical layer answered. No model, no
///   ask. The request's requirements are covered — by grants, by the mode
///   ceiling, or by the certified-reader exemption (a pinned reader's
///   execution requirement is covered by certification).
/// - [PermissionOutcome.refuse]: a mode ceiling or the sandbox refused.
///   Without an enforcing backend, a read-profile command is refused —
///   a grant allows the read; it does not make the run safe. A
///   write-profile command without a backend is NOT refused here: it
///   carries a host requirement and goes to judgment, where only a human
///   can approve it.
/// - [PermissionOutcome.judgment]: everything else. Interactive mode asks
///   the user; auto mode asks the classifier. The judgment layer — the
///   mode plugin — owns the asking and its consequences.
///
/// Certified reads, command patterns, directory grants and MCP rules are
/// all inputs, expressed through the [ScopesView] and the caller's
/// coverage facts.
library;

import 'capability_envelope.dart';
import 'package:tina_mode/tina_mode.dart'
    show PermissionMode, PermissionAccessOperation;

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

/// Which rule produced the verdict. The caller wires behavior (dialog
/// text, execution profile) off the rule, never off strings.
enum PermissionRule {
  /// Every requirement covered by grants, the mode ceiling, or the
  /// certified-reader exemption.
  grantsRun,

  /// Read-only mode ceiling: mutations, host execution or declared writes.
  readOnlyCeilingRefuse,

  /// A read-profile command with no enforcing backend.
  readOnlyBackendRefuse,

  /// An uncovered requirement: ask (human, or the classifier in auto).
  judgment,
}

/// What the pipeline decided, and why.
enum PermissionOutcome { run, refuse, judgment }

final class PermissionDecision {
  const PermissionDecision._(
      this.outcome, this.rule, this.reason, this.readOnlyProfile);

  /// The outcome.
  final PermissionOutcome outcome;

  /// Which rule fired.
  final PermissionRule rule;

  /// Human-readable; also the refusal text on [PermissionOutcome.refuse].
  final String reason;

  /// The execution profile the verdict implies. Callers need it to build
  /// the permission set and the sandbox control (read-only enforcement).
  final bool readOnlyProfile;

  /// Convenience predicates.
  bool get runs => outcome == PermissionOutcome.run;
  bool get refuses => outcome == PermissionOutcome.refuse;
  bool get needsJudgment => outcome == PermissionOutcome.judgment;
}

/// The execution profile for a command in a mode — the Layer-1 fast paths
/// plus the mode default. Pure: the same inputs always give the same
/// profile.
///
/// The fast paths, exactly as the merged contract defines them:
/// - A certified reader whose declared directories are empty and whose
///   verified read accesses all sit inside granted scopes, confined, with
///   no network.
/// - The agent's own script ([agentCreatedScriptArguments] — every
///   argument names a file this session's own write/edit tools created),
///   run confined, inside the sandbox, with no network.
///
/// Neither fast path is by itself permission to run: they select the
/// read-only enforcement profile. The run verdict still comes from
/// [decidePermission] — a certified reader's execution requirement is
/// exempt from the missing set, an agent script's is not and still asks.
bool readOnlyProfileOf(
  CapabilityEnvelope envelope, {
  required ScopesView scopes,
  required bool confined,
  required bool network,
  required bool outsideSandbox,
  required bool agentCreatedScriptArguments,
  required bool declaredReadsEmpty,
  required bool declaredWritesEmpty,
  bool? controlReadOnlyRequested,
  required PermissionMode mode,
}) {
  if (controlReadOnlyRequested != null) return controlReadOnlyRequested;
  return _certifiedReadWithinGrants(
          envelope,
          scopes: scopes,
          confined: confined,
          network: network,
          outsideSandbox: outsideSandbox,
          declaredReadsEmpty: declaredReadsEmpty,
          declaredWritesEmpty: declaredWritesEmpty) ||
      _agentScriptFastPath(
          confined: confined,
          network: network,
          outsideSandbox: outsideSandbox,
          agentCreatedScriptArguments: agentCreatedScriptArguments) ||
      _defaultReadOnlyProfile(mode,
          confined: confined,
          certifiedReadOnly: envelope.certifiedReadOnly,
          writeRequested: !declaredWritesEmpty);
}

bool _certifiedReadWithinGrants(
  CapabilityEnvelope envelope, {
  required ScopesView scopes,
  required bool confined,
  required bool network,
  required bool outsideSandbox,
  required bool declaredReadsEmpty,
  required bool declaredWritesEmpty,
}) =>
    confined &&
    !outsideSandbox &&
    !network &&
    envelope.certifiedReadOnly &&
    declaredReadsEmpty &&
    declaredWritesEmpty &&
    envelope.verifiedAccesses.every((access) =>
        access.operation != PermissionAccessOperation.read ||
        scopes.canRead(access.path));

bool _agentScriptFastPath({
  required bool confined,
  required bool network,
  required bool outsideSandbox,
  required bool agentCreatedScriptArguments,
}) =>
    confined && !outsideSandbox && !network && agentCreatedScriptArguments;

bool _defaultReadOnlyProfile(PermissionMode mode,
        {required bool confined,
        required bool certifiedReadOnly,
        bool writeRequested = false}) =>
    mode == PermissionMode.readOnly ||
    confined &&
        (certifiedReadOnly ||
            !writeRequested &&
                (mode == PermissionMode.ask || mode == PermissionMode.auto));

/// The verdict, in the live precedence order:
///
/// 1. The execution profile (the Layer-1 fast paths above): read-only
///    enforcement where they apply.
/// 2. The read-only mode ceiling: a mutation, host execution or a declared
///    write in read-only mode → refuse.
/// 3. A read-profile command with no enforcing backend → refuse. The
///    sandbox is the enforcement; without it the read claim cannot hold.
/// 4. Every requirement covered — grants, the mode ceiling, the
///    certified-reader exemption, or yolo launch-time authorization → run.
/// 5. Anything else → judgment, with the reason the dialog shows. A
///    requirement outside the workspace — network, host, external — says
///    so; a workspace write asks for approval.
PermissionDecision decidePermission(
  CapabilityEnvelope envelope, {
  required ScopesView scopes,
  required bool confined,
  required bool network,
  required bool outsideSandbox,
  bool? controlReadOnlyRequested,
  required bool agentCreatedScriptArguments,
  required bool declaredReadsEmpty,
  required bool declaredWritesEmpty,
  required PermissionMode mode,
  required bool requirementsCovered,
  required bool judgmentOutsideWorkspace,
}) {
  final readOnlyProfile = readOnlyProfileOf(envelope,
      scopes: scopes,
      confined: confined,
      network: network,
      outsideSandbox: outsideSandbox,
      agentCreatedScriptArguments: agentCreatedScriptArguments,
      declaredReadsEmpty: declaredReadsEmpty,
      declaredWritesEmpty: declaredWritesEmpty,
      controlReadOnlyRequested: controlReadOnlyRequested,
      mode: mode);
  if (mode == PermissionMode.readOnly &&
      (!readOnlyProfile || outsideSandbox || !declaredWritesEmpty)) {
    return PermissionDecision._(
        PermissionOutcome.refuse,
        PermissionRule.readOnlyCeilingRefuse,
        'Read-only mode blocks workspace mutations, external writes and '
        'host execution.',
        readOnlyProfile);
  }
  // The judgment table's read-only mutation deny: in read-only mode the
  // host requirement a missing backend adds counts as a mutation. It runs
  // before the backend deny and carries its own message.
  if (mode == PermissionMode.readOnly && !confined) {
    return PermissionDecision._(
        PermissionOutcome.refuse,
        PermissionRule.readOnlyCeilingRefuse,
        'read-only mode blocks mutations and host or external execution. '
        'Change mode to edit.',
        readOnlyProfile);
  }
  if (readOnlyProfile && !outsideSandbox && !confined) {
    return PermissionDecision._(
        PermissionOutcome.refuse,
        PermissionRule.readOnlyBackendRefuse,
        'Read-only execution requires an available OS sandbox.',
        readOnlyProfile);
  }
  if (requirementsCovered || mode == PermissionMode.yolo) {
    return PermissionDecision._(
        PermissionOutcome.run,
        PermissionRule.grantsRun,
        'Covered by workspace policy or explicit grants',
        readOnlyProfile);
  }
  return PermissionDecision._(
      PermissionOutcome.judgment,
      PermissionRule.judgment,
      judgmentOutsideWorkspace
          ? 'Access outside the workspace requires explicit human approval'
          : 'Workspace mutation requires approval',
      readOnlyProfile);
}
