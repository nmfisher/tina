import 'dart:io';

import '../permissions/policy.dart';
import '../runtime/contracts.dart';
import '../runtime/runtime.dart';
import '../tools/mutation_lock.dart';
import '../tools/workspace_capabilities.dart';
import '../tools/workspace_tool_plugins.dart';
import '../tools/tool.dart';

import 'tool_profile.dart';

/// Service key under which a composition registers/resolves the assembled
/// [WorkspaceToolScope].
final ServiceKey<WorkspaceToolScope> workspaceToolScopeServiceKey =
    ServiceKey<WorkspaceToolScope>('tina.engine.workspace_tool_scope');

/// Project-owned tools and write coordination. Main agents, delegates and
/// same-project background runs borrow this scope. Creating another scope never
/// changes these tool instances or their sandbox configuration.
///
/// The tools are no longer wired by hand here: the scope composes a
/// [PluginRuntime] from [workspaceToolPlugins] and activates it synchronously —
/// one plugin per tool, each factory building the tool from the shared
/// [WorkspaceCapabilities]. The scope keeps only the capabilities' identity
/// fields; every tool lives in the runtime's scope as contributions.
class WorkspaceToolScope {
  final String workspaceRoot;
  final Map<String, String> environment;
  final FileMutationLock mutationLock;

  /// The runtime this scope composed and activated; its root scope holds the
  /// tool contributions.
  final PluginRuntime runtime;

  WorkspaceToolScope({
    required String workspaceRoot,
    required Map<String, String> env,
    bool sandboxEnabled = true,
    bool sandboxNet = false,
    bool sandboxReadOnly = false,
  }) : this._(
          capabilities: WorkspaceCapabilities.build(
            workspaceRoot: workspaceRoot,
            env: env,
            confineFiles: true,
            sandboxEnabled: sandboxEnabled,
            sandboxNet: sandboxNet,
            sandboxReadOnly: sandboxReadOnly,
          ),
        );

  /// Standalone tool assembly for engine consumers without application setup.
  /// Production composition uses the confined constructor above.
  WorkspaceToolScope.unconfined({String? workspaceRoot, Map<String, String>? env})
      : this._(
          capabilities: WorkspaceCapabilities.build(
            workspaceRoot: workspaceRoot ?? Directory.current.path,
            env: env ?? Platform.environment,
            confineFiles: false,
            sandboxEnabled: false,
            sandboxNet: false,
            sandboxReadOnly: false,
          ),
        );

  /// Composition seam: assembles the scope from already-built [capabilities].
  /// The app-level plugin that provides the scope as a service uses this; the
  /// two public constructors above keep building the capabilities themselves.
  WorkspaceToolScope.fromCapabilities(WorkspaceCapabilities capabilities)
      : this._(capabilities: capabilities);

  WorkspaceToolScope._({required WorkspaceCapabilities capabilities})
      : workspaceRoot = capabilities.workspaceRoot,
        environment = capabilities.environment,
        mutationLock = capabilities.mutationLock,
        runtime = PluginRuntime(
          name: 'workspace-tools',
          plugins: workspaceToolPlugins(capabilities),
        ) {
    runtime.activateSync();
  }

  /// The concrete tool set for [profile]. `read-only` is the read/explore tools
  /// plus the sidecar `write_summary` capture (which never touches source); `full`
  /// is the whole base set ([buildTools]) plus `write_summary`. Under
  /// `--safe-mode` the caller strips the mutating tools from whichever set a
  /// sub-agent received (see [stripForSafeMode]).
  List<Tool> toolSetFor(ToolProfile profile) {
    switch (profile) {
      case ToolProfile.readOnly:
        return _toolsByName(const [
          'read',
          'fetch',
          'search',
          'grep',
          'glob',
          'ls',
          'stat',
          'which',
          'execution_info',
          'git',
          'write_summary',
        ]);
      case ToolProfile.full:
        return [...buildTools().all, _writeSummary];
    }
  }

  /// Reconstruct a tool set from the names a stored permission policy *allows* —
  /// used when restoring a persisted sub-agent/spawn conversation (its exact
  /// profile isn't stored, but its policy is, and that determines its tools).
  /// Evaluates the full policy (defaults + static rules) for each project-scoped
  /// tool, so it works whether the policy was built from `defaults`
  /// (sub-agents) or `rules` (spawns/branches).
  List<Tool> toolsFromPolicy(PermissionPolicy policy) {
    final candidates = _toolsByName(const [
      'read',
      'write',
      'edit',
      'fetch',
      'bash',
      'exec',
      'execution_info',
      'search',
      'grep',
      'glob',
      'ls',
      'stat',
      'which',
      'git',
      'write_summary',
    ]);
    return [
      for (final t in candidates)
        if (policy.check(t.schema.name, const {}) == PermissionDecision.allow)
          t,
    ];
  }

  /// The full base tool set — read/write/edit/bash/search/grep/glob — plus
  /// `web_search` when a search API key is configured. Used by the headless
  /// `--prompt` path (main as a direct worker), by [ToolProfile.full], and by
  /// the node run (attractor seam).
  ///
  /// Both Brave and Tavily answer the same `web_search` tool name; a user only
  /// needs one index. When *both* keys are set, Tavily answers `web_search`
  /// (the plugin contributes only the winning provider). The model doesn't
  /// care which backend responds.
  ToolRegistry buildTools({bool safeMode = false}) =>
      toolRegistryFromScope(runtime.scope, safeMode: safeMode);

  /// The scope's tool contributions by declared tool name, in [names] order.
  /// A name missing from the runtime (an unconfigured `web_search`, say) is
  /// simply absent from the result — callers compose from what exists.
  List<Tool> _toolsByName(List<String> names) {
    final tools = <Tool>[];
    for (final name in names) {
      final tool = _toolNamed(name);
      if (tool != null) tools.add(tool);
    }
    return tools;
  }

  Tool? _toolNamed(String name) {
    for (final contribution in runtime.scope.contributions) {
      final tool = contribution.contribution;
      if (tool is Tool && tool.schema.name == name) return tool;
    }
    // The sidecar capture is composed by the runtime as a singleton under
    // [writeSummaryToolServiceKey], not as a registry contribution — see
    // [workspaceToolPlugins].
    if (name == 'write_summary') return _writeSummary;
    return null;
  }

  /// The sidecar summaries capture: composed by the runtime under its
  /// [writeSummaryToolServiceKey] singleton (it is deliberately not a registry
  /// contribution — see [workspaceToolPlugins]).
  Tool get _writeSummary =>
      runtime.scope.lookup(writeSummaryToolServiceKey) as Tool;
}
