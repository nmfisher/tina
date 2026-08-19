import 'policy.dart';
import 'prompt.dart';
import 'classifier.dart';

/// Wraps an interactive [PermissionAsker] with the "auto" permission mode:
/// when [PermissionPolicy.mode] is [PermissionMode.auto] at call time, an
/// independent [PermissionClassifier] decides the call instead of the user.
///
/// The policy is consulted per call, so `/permissions <mode>` switches take
/// effect immediately on agents already running. Any classifier failure
/// (error, timeout, unparseable answer) falls back to [fallback] — the normal
/// y/n prompt — never silently allows.
PermissionAsker modeAwareAsker({
  required PermissionPolicy policy,
  required PermissionClassifier classifier,
  required PermissionAsker fallback,
  void Function(String line)? notice,
}) {
  return (prompt) async {
    if (policy.mode != PermissionMode.auto) return fallback(prompt);
    final verdict = await classifier.allow(prompt.toolName, prompt.input);
    if (verdict == null) return fallback(prompt);
    notice?.call(verdict
        ? '  ${prompt.toolName} allowed by classifier: ${prompt.key}\n'
        : '  ${prompt.toolName} denied by classifier: ${prompt.key}\n');
    return verdict
        ? PermissionResponse.allowOnce
        : PermissionResponse.denyOnce;
  };
}
