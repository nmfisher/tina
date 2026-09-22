import '../runtime/invocation.dart';
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
///
/// A classifier verdict is remembered like a manual a/d: allow carries the same
/// `remember` flag the user's `a` would (and deny the `d` equivalent), so the
/// agent installs the same session rule — exact bash command, parent-dir glob —
/// with `decidedBy: 'classifier'` recording that no human answered. Identical
/// calls short-circuit the rule cascade before ever re-classifying — a fan-out
/// of 30 identical bash calls pays one classifier round-trip, not 30.
/// Outside-sandbox approvals use the same exact session grant as a human
/// approval, and include the execution boundary in the classifier request.
/// Extra writable-directory grants still require the interactive asker.
PermissionAsker modeAwareAsker({
  required PermissionPolicy policy,
  required PermissionClassifier classifier,
  required PermissionAsker fallback,
  void Function(String line)? notice,
}) {
  return (prompt) async {
    if (prompt.sandboxAccess != null || policy.mode != PermissionMode.auto)
      return fallback(prompt);
    var cancelled = false;
    prompt.cancelSignal?.then((_) => cancelled = true);
    final verdict = await classifier.allowPrompt(prompt);
    if (cancelled) return PermissionResponse.denyOnce;
    if (policy.mode != PermissionMode.auto) return fallback(prompt);
    if (verdict == null) return fallback(prompt);
    final boundary = prompt.outsideSandbox ? ' outside sandbox' : '';
    final line = verdict
        ? '  ${prompt.toolName} allowed by classifier$boundary: ${prompt.key}\n'
        : '  ${prompt.toolName} denied by classifier$boundary: ${prompt.key}\n';
    final invocation = InvocationContext.current?.invocation;
    if (invocation == null) {
      notice?.call(line);
    } else {
      invocation.output(() => notice?.call(line), size: line.length);
    }
    return verdict
        ? const PermissionResponse(PermissionDecision.allow,
            remember: true, decidedBy: 'classifier')
        : const PermissionResponse(PermissionDecision.deny,
            remember: true, decidedBy: 'classifier');
  };
}
