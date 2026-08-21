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
