import '../permissions/policy.dart';
import '../runtime/plugin.dart';
import '../tools/tool.dart';

/// One pre-execution gate on a tool call: a deny-preserving check that runs
/// BEFORE the permission asker and before the tool itself (the [ToolExecutor]
/// combines the mandatory policy and phase guards with any extra guards via
/// [combineGuardBlocks]).
///
/// [block] returns null when the call may proceed. A non-null return is the
/// denial text shipped to the model as the tool result (an error result, with
/// no ask prompt and no execution). A guard can only ever REJECT: there is no
/// allow verdict, so no guard — and no wrapper around one — can override an
/// earlier guard's rejection.
abstract class ToolGuard {
  /// Whether this guard rejects the call [toolName] with [input]: null allows,
  /// a string denies and becomes the tool result content.
  String? block(String toolName, Map<String, dynamic> input);
}

/// The mandatory policy gate, as a [ToolGuard]: [PermissionPolicy.executionBlock]
/// is the hard mode boundary (e.g. read-all) the executor already applied
/// first. Extracted as a guard so the ordered [combineGuardBlocks] chain and
/// ad-hoc [executionGuards] all flow through one mechanism.
class PolicyToolGuard implements ToolGuard {
  final PermissionPolicy policy;

  PolicyToolGuard(this.policy);

  @override
  String? block(String toolName, Map<String, dynamic> input) =>
      policy.executionBlock(toolName, input);
}

/// The mandatory phase gate, as a [ToolGuard]: the step's [ToolRegistry] view
/// (e.g. the environment-stage registry delegating to its own per-step
/// registry) keeps the same-phase semantics the executor applied second,
/// before any extra guard.
class RegistryPhaseGuard implements ToolGuard {
  final ToolRegistry registry;

  RegistryPhaseGuard(this.registry);

  @override
  String? block(String toolName, Map<String, dynamic> input) =>
      registry.executionBlock(toolName, input);
}

/// Runs [guards] IN ORDER against one call and returns the first non-null
/// block — combining by denial, so the FIRST guard that rejects wins and no
/// later guard (allow-ish, wrapper, or otherwise) can override an earlier
/// guard's rejection.
///
/// Fail closed: a guard that THROWS rejects the call with
/// `'execution guard failed: <error>'` — a broken guard never silently skips
/// its check. The mandatory policy and phase guards always come first in the
/// list the executor builds; extra [ToolGuard]s (Agent.executionGuards) are
/// appended after them and are checked only when every earlier guard allowed.
String? combineGuardBlocks(
  List<ToolGuard> guards,
  String toolName,
  Map<String, dynamic> input,
) {
  for (final guard in guards) {
    String? block;
    try {
      block = guard.block(toolName, input);
    } catch (e) {
      // Fail closed: a throwing guard rejects the call rather than skipping.
      return 'execution guard failed: $e';
    }
    if (block != null) return block;
  }
  return null;
}

/// Service key under which the policy guard plugin exposes its
/// [PolicyToolGuard]. Guard plugins that want to activate after the mandatory
/// policy guard declare the key as a requirement; [phaseGuardPlugin] does, so
/// the phase guard always registers after the policy guard. (Activation is
/// topological — required providers first, ties by plugin id.) Note this
/// orders REGISTRATION only: execution precedence is fixed by the executor's
/// chain — policy, phase, extras — regardless of this list's order.
final ServiceKey<ToolGuard> toolGuardServiceKey =
    ServiceKey<ToolGuard>('tina.engine.tool_guard');

/// The scope's [ToolGuard] contributions, in declared registration order —
/// the order the plugins registered them, with no reordering (unlike
/// [toolRegistryFromScope]'s catalog rank). Registration follows activation
/// (dependency-first, ties by plugin id), so [policyGuardPlugin]'s
/// contribution lands before [phaseGuardPlugin]'s; this list is
/// informational — the executor builds its guard chain itself.
List<ToolGuard> toolGuardsFromScope(PluginScope scope) => [
      for (final contribution in scope.contributions)
        if (contribution.contribution is ToolGuard)
          contribution.contribution as ToolGuard,
    ];

/// Composition plugin (engine style, like project_tool_plugins.dart) that
/// registers the mandatory [PolicyToolGuard] for [policy] as a contribution
/// and exposes it under [toolGuardServiceKey].
PluginDescriptor policyGuardPlugin(PermissionPolicy policy) =>
    PluginDescriptor(
      id: 'tina.guard.policy',
      provides: [toolGuardServiceKey],
      factory: FnPluginFactory((context) {
        final guard = PolicyToolGuard(policy);
        context.register(guard, id: 'tina.guard.policy');
        return guard;
      }),
    );

/// Composition plugin that registers the mandatory [RegistryPhaseGuard] for
/// [registry] as a contribution. Requires [toolGuardServiceKey] so it
/// activates strictly after the policy guard plugin — the mandatory guards
/// register in policy-then-phase order.
PluginDescriptor phaseGuardPlugin(ToolRegistry registry) => PluginDescriptor(
      id: 'tina.guard.phase',
      requires: {toolGuardServiceKey},
      factory: FnPluginFactory((context) {
        // Order-only dependency: the policy guard must already be registered.
        context.require(toolGuardServiceKey);
        final guard = RegistryPhaseGuard(registry);
        context.register(guard, id: 'tina.guard.phase');
        return guard;
      }),
    );
