import '../runtime/invocation.dart';
import 'policy.dart';
import 'prompt.dart';
import 'classifier.dart';

/// Appended to the judge's system prompt only while the session is read-only.
/// The base prompt ALLOWs "ordinary development … building, testing" — true
/// in auto mode, wrong here, where the question is "may this command only
/// READ?". One additive sentence keeps a single judge prompt for both modes
/// instead of a second full prompt that could drift from the first.
const _readOnlyDirective =
    'This session is in READ-ONLY mode: ALLOW only a command whose every '
    'effect is reading — listing, printing, querying, searching. DENY '
    'anything that creates, modifies, or deletes files or system state, '
    'installs or builds anything, or runs a program beyond well-known '
    'read-only utilities. When uncertain, DENY.';

/// Wraps an interactive [PermissionAsker] with the classifier-backed
/// permission modes, consulting [PermissionPolicy.mode] per call so
/// `/permissions <mode>` switches take effect immediately on agents already
/// running:
///
/// * [PermissionMode.auto] — the judge decides every call that reaches this
///   asker. Any classifier failure (error, timeout, unparseable answer)
///   falls back to [fallback] — the normal y/n prompt — never silently
///   allows; the failure is announced through [notice] so the ask that
///   appears never looks like auto mode ignoring itself.
/// * [PermissionMode.readAll] — the fail-closed twin. The policy routes
///   bash here as an `ask` (see [PermissionPolicy.classifierGatesShell]);
///   this wrapper judges it under [_readOnlyDirective] and answers any
///   failure — timeout, stream error, garbage answer, cancelled turn,
///   outside-sandbox retry — with a DENY. There is no path to [fallback]
///   while read-all holds: an `ask` this wrapper cannot answer must not
///   become a prompt in a mode that promised none. A mode flip *during* the
///   judge call re-routes to [fallback], like auto's, because the user has
///   just re-enabled asking by hand.
///
/// Constructing this wrapper sets [PermissionPolicy.classifierGatesShell]
/// on [policy] — the wrapper IS the gate that flag promises, so flag and
/// wrapper cannot drift apart; policy copies spread the flag to keep the
/// route alive for sub-agents and new conversations.
///
/// A classifier verdict is remembered like a manual a/d: allow carries the
/// same `remember` flag the user's `a` would (and deny the `d` equivalent),
/// so the agent installs the same session rule — exact bash command,
/// parent-dir glob — with `decidedBy: 'classifier'` recording that no human
/// answered. Identical calls short-circuit the rule cascade before ever
/// re-classifying — a fan-out of 30 identical bash calls pays one classifier
/// round-trip, not 30. Outside-sandbox approvals use the same exact session
/// grant as a human approval, and include the execution boundary in the
/// classifier request. Extra writable-directory grants still require the
/// interactive asker.
PermissionAsker modeAwareAsker({
  required PermissionPolicy policy,
  required PermissionClassifier classifier,
  required PermissionAsker fallback,
  void Function(String line)? notice,
}) {
  // The policy learns its classifier gate exists the moment the wrapper is
  // wired on it. This call is the ONLY place the flag is set (copies then
  // spread it), so a policy that routes bash to `ask` in read-all always
  // has something fail-closed standing behind that ask — and a policy
  // without the wrapper keeps read-all's original hard block.
  policy.classifierGatesShell = true;

  return (prompt) async {
    // One verdict path for both modes: the notice line, the invocation-
    // scoped output, and the remembered response a manual a/d would install.
    PermissionResponse decide(bool verdict) {
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
    }

    if (policy.mode == PermissionMode.readAll) {
      // Fail-closed: widen nothing read-all did not already promise. A
      // directory grant can only ADD machine effects, so it is denied here
      // outright — before the judge is even consulted — and the model gets
      // an explanation instead of silence.
      if (prompt.sandboxAccess != null) {
        notice?.call('  ${prompt.toolName} denied by read-only mode: '
            'outside-sandbox access cannot be granted while the session is '
            'read-only: ${prompt.key}\n');
        return PermissionResponse.denyOnce;
      }
      var cancelled = false;
      prompt.cancelSignal?.then((_) => cancelled = true);
      final outcome =
          await classifier.classify(prompt, directive: _readOnlyDirective);
      if (cancelled) return PermissionResponse.denyOnce;
      if (policy.mode != PermissionMode.readAll) return fallback(prompt);
      final verdict = outcome.allow;
      if (verdict == null) {
        // Announce WHY nothing ran: read-all staying closed on a classifier
        // failure must not read as the tool working or as silence.
        notice?.call(
            '  ${prompt.toolName} classifier ${outcome.failure!.phrase(timeout: classifier.timeout)} — read-only stays closed: ${prompt.key}\n');
        return PermissionResponse.denyOnce;
      }
      return decide(verdict);
    }

    if (prompt.sandboxAccess != null || policy.mode != PermissionMode.auto)
      return fallback(prompt);
    var cancelled = false;
    prompt.cancelSignal?.then((_) => cancelled = true);
    final outcome = await classifier.classify(prompt);
    final verdict = outcome.allow;
    if (cancelled) return PermissionResponse.denyOnce;
    if (policy.mode != PermissionMode.auto) return fallback(prompt);
    if (verdict == null) {
      // Say why the human is being asked after all: a silent fallback reads
      // as auto mode ignoring itself. Same dim channel as the verdict line.
      notice?.call(
          '  ${prompt.toolName} classifier ${outcome.failure!.phrase(timeout: classifier.timeout)} — asking instead: ${prompt.key}\n');
      return fallback(prompt);
    }
    return decide(verdict);
  };
}
