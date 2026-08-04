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

  const PermissionResponse(this.decision, {this.remember = false});

  static const allowOnce =
      PermissionResponse(PermissionDecision.allow);
  static const denyOnce =
      PermissionResponse(PermissionDecision.deny);
  static const allowAlways =
      PermissionResponse(PermissionDecision.allow, remember: true);
  static const denyAlways =
      PermissionResponse(PermissionDecision.deny, remember: true);
}

typedef PermissionAsker = Future<PermissionResponse> Function(PermissionPrompt);
