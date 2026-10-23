import 'package:tina_approvals/tina_approvals.dart';
import 'mode.dart';

/// Capabilities describe access, independently of which tool requests it.
enum AccessCapability { read, write, execute, network, host, external }

final class AccessRequirement {
  const AccessRequirement(
    this.capability,
    this.target, {
    this.workspace = false,
    this.granted = false,
  });
  final AccessCapability capability;
  final String target;
  final bool workspace;

  /// A matching explicit human grant, checked by the resource owner.
  final bool granted;
  Map<String, Object?> toJson() => {
    'capability': capability.name,
    'target': target,
    'workspace': workspace,
    'granted': granted,
  };
}

/// Canonical facts supplied by an enforcement boundary, never by the model.
final class AuthorizationRequest {
  AuthorizationRequest({
    required Iterable<AccessRequirement> requirements,
    this.readOnlyExecution = false,
    this.confined = false,
    this.blockedReason,
  }) : requirements = List.unmodifiable(requirements);
  final List<AccessRequirement> requirements;
  final bool readOnlyExecution;
  final bool confined;
  final String? blockedReason;
  bool get mutates => requirements.any(
    (r) =>
        r.capability == AccessCapability.write ||
        r.capability == AccessCapability.host ||
        r.capability == AccessCapability.external,
  );
  List<AccessRequirement> uncovered(PermissionMode mode) =>
      requirements.where((r) => !_covered(r, this, mode)).toList();
  Map<String, Object?> toJson({PermissionMode? mode}) => {
    'access_requirements': requirements
        .map(
          (r) => {
            ...r.toJson(),
            if (mode != null) 'granted': _covered(r, this, mode),
          },
        )
        .toList(),
    'execution_profile': readOnlyExecution ? 'read-only' : 'workspace-write',
  };
}

enum AuthorizationRoute { allow, deny, human, review }

typedef AuthorizationResolution = ({AuthorizationRoute route, String reason});

/// One total policy table. Mode ceilings are applied before remembered grants.
AuthorizationResolution resolveAuthorization(
  AuthorizationRequest request,
  PermissionMode mode, {
  ApprovalKind kind = ApprovalKind.permission,
}) {
  if (request.blockedReason case final String reason) {
    return (route: AuthorizationRoute.deny, reason: reason);
  }
  if (kind == ApprovalKind.confirmation) {
    return (
      route: AuthorizationRoute.human,
      reason: 'Explicit user confirmation',
    );
  }
  if (mode == PermissionMode.readOnly &&
      (request.mutates ||
          request.requirements.any(
                (r) => r.capability == AccessCapability.execute,
              ) &&
              (!request.readOnlyExecution || !request.confined))) {
    return (
      route: AuthorizationRoute.deny,
      reason:
          'read-only mode blocks mutations and host or external execution. Change mode to edit.',
    );
  }
  if (request.readOnlyExecution &&
      !request.confined &&
      request.requirements.any(
        (r) => r.capability == AccessCapability.execute,
      )) {
    return (
      route: AuthorizationRoute.deny,
      reason: 'Read-only execution requires an available OS sandbox.',
    );
  }
  final missing = request.uncovered(mode);
  if (missing.isEmpty || mode == PermissionMode.yolo) {
    return (
      route: AuthorizationRoute.allow,
      reason: missing.isEmpty
          ? 'Covered by workspace policy or explicit grants'
          : 'yolo launch-time authorization',
    );
  }
  if (missing.any(
    (r) =>
        !r.workspace ||
        {
          AccessCapability.network,
          AccessCapability.host,
          AccessCapability.external,
        }.contains(r.capability),
  )) {
    return (
      route: AuthorizationRoute.human,
      reason: 'Access outside the workspace requires explicit human approval',
    );
  }
  return (
    route: mode == PermissionMode.auto
        ? AuthorizationRoute.review
        : AuthorizationRoute.human,
    reason: 'Workspace mutation requires approval',
  );
}

bool _covered(
  AccessRequirement r,
  AuthorizationRequest request,
  PermissionMode mode,
) {
  if (r.granted) return true;
  if (r.capability == AccessCapability.read && r.workspace) return true;
  if (r.capability == AccessCapability.execute &&
      request.confined &&
      request.readOnlyExecution)
    return true;
  return mode == PermissionMode.allowEdits &&
      r.workspace &&
      (r.capability == AccessCapability.write ||
          r.capability == AccessCapability.execute && request.confined);
}
