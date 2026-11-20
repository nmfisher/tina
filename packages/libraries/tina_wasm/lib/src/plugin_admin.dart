/// TUI/agent-facing plugin management command and tools (issue #85,
/// principal decision): `/plugins` shows the lease book, `/plugins
/// reload` drops the live lease and attaches a fresh plugin Store —
/// with the host's compile-on-load watch mode this picks up a rebuilt
/// artifact without restarting the engine.
///
/// The agent surface (commit 25) contributes the same lifecycle to the
/// loop as three tools — `plugin_build`, `plugin_reload`,
/// `plugin_status` — plus one prompt section describing them. The build
/// tool runs the shared commit-24 [PluginBuildFlow] (the same
/// implementation the TUI's `/plugins build` command drives; one
/// implementation, two surfaces) when the composition supplies its
/// compile/install seams; the engine component cannot spawn processes,
/// so a composition without the seams gets the honest host-side
/// fallback, exactly like the command's `build` argument.
///
/// Deliberately lifecycle-only: no prompt surface beyond the one
/// capability section, no approval behavior. The prompt adapter shares
/// this plugin's [PluginManager], so a reload is adopted by the next
/// prompt automatically; an in-flight prompt observes the lease change
/// and discards itself instead of writing through a retired store.
library;

import 'package:tina_core/tina_core.dart'
    show Command, Terminal, ToolResult, ToolSchema;
import 'package:tina_engine_2/tina_engine_2.dart'
    show AgentLoop, AgentPlugin, ToolExecutionContext, TurnContext;
import 'package:tina_plugin_registry/build_flow.dart'
    show LocalConsentBook, LocalPluginBuild, PluginBuildFlow;

import 'plugin_manager.dart';
import 'prompt_bridge_types.dart';

/// The attached plugin artifact's provenance, surfaced in /plugins
/// status. Supplied by the composition root from the launch
/// environment (the launcher passes the active plugin's origin, hash
/// and build timestamp); null keeps status as it was.
final class PluginArtifactOrigin {
  const PluginArtifactOrigin({
    required this.origin,
    this.hash,
    this.builtAt,
  });

  /// 'local' (built with plugins build) or 'registry'.
  final String origin;
  final String? hash;
  final String? builtAt;
}

final class WasmPluginAdminPlugin extends AgentPlugin {
  WasmPluginAdminPlugin({required PluginManager manager, required Terminal terminal,
      this.artifact,
      this.buildArtifact,
      this.consent,
      this.consentPrompt})
    : _manager = manager,
      _terminal = terminal;

  static const pluginId = 'tina/wasm-plugin-admin';

  /// `plugin_build(source_dir)`: compile + install, consent by hash,
  /// auto-reload when a plugin is attached.
  static const pluginBuildTool = 'plugin_build';

  /// `plugin_reload()`: close the live lease, attach a fresh Store.
  static const pluginReloadTool = 'plugin_reload';

  /// `plugin_status()`: lease book + artifact provenance.
  static const pluginStatusTool = 'plugin_status';

  final PluginManager _manager;
  final Terminal _terminal;
  final PluginArtifactOrigin? artifact;

  /// The shared build flow's compile-and-install seam: compiles a
  /// plugin source directory with the local toolchain and installs the
  /// artifact (origin local), or throws [PluginBuildException] with a
  /// clean message. The engine component has no local toolchain, so a
  /// composition supplies this (and [consent] and [consentPrompt]) only
  /// where builds can actually run; all three must be present together.
  final Future<LocalPluginBuild> Function(String sourcePath)? buildArtifact;

  /// The hash-keyed local consent book for [pluginBuildTool].
  final LocalConsentBook? consent;

  /// The consent prompt for a new artifact hash (a human decision; the
  /// TUI surfaces a modal, a headless composition may answer through
  /// its approvals channel).
  final Future<bool> Function(LocalPluginBuild build)? consentPrompt;

  PluginBuildFlow? _flow;
  PromptBridgeResult<String>? _lastReload;

  /// The shared commit-24 flow with this plugin's manager bound as the
  /// reload/attached side, or null when the composition cannot build.
  PluginBuildFlow? get _buildFlow {
    final existing = _flow;
    if (existing != null) return existing;
    final buildArtifact = this.buildArtifact;
    final consent = this.consent;
    final consentPrompt = this.consentPrompt;
    if (buildArtifact == null || consent == null || consentPrompt == null) {
      return null;
    }
    return _flow = PluginBuildFlow(
      buildArtifact: buildArtifact,
      consent: consent,
      prompt: consentPrompt,
      notice: _terminal.writeln,
      attached: () => _manager.isOpen,
      reload: () async {
        _lastReload = _manager.reload();
      },
    );
  }

  @override
  String get id => pluginId;

  @override
  List<ToolSchema> get tools => [
        ToolSchema(
          name: pluginBuildTool,
          description: 'Build a plugin from its Dart source directory with '
              'the local toolchain and install it into the plugin cache '
              '(origin local). Consent is asked once per artifact hash; '
              'when a plugin is attached the fresh artifact is reloaded '
              'automatically. Not a general code-execution path: compiled '
              'artifacts pass the unchanged capability/policy gate.',
          inputSchema: const {
            'type': 'object',
            'properties': {
              'source_dir': {
                'type': 'string',
                'description': 'path of the plugin source directory '
                    '(the one containing bin/<name>.dart or bin/main.dart)',
              },
            },
            'required': ['source_dir'],
          },
        ),
        ToolSchema(
          name: pluginReloadTool,
          description: 'Reload the attached plugin artifact: drop the live '
              'lease and attach a fresh plugin instance. In-instance state '
              'not written through the artifact\'s persistence is lost.',
          inputSchema: const {
            'type': 'object',
            'properties': <String, Object>{},
          },
        ),
        ToolSchema(
          name: pluginStatusTool,
          description: 'Report the attached plugin: plugin id, origin '
              '(local or registry), artifact hash, build timestamp, lease '
              'and lifecycle counters.',
          inputSchema: const {
            'type': 'object',
            'properties': <String, Object>{},
          },
        ),
      ];

  /// The one capability section (commit 25): the tools exist, when to
  /// use them, consent once per artifact hash, the fresh-instance state
  /// loss on reload, and the unchanged capability/policy gate — the
  /// build tool is not a general code-execution path.
  static const pluginLifecycleSection = '''
<plugin-lifecycle>
Plugin lifecycle tools: plugin_build(source_dir), plugin_reload() and
plugin_status(). Use them when the user asks to add or update a plugin, or
after editing a plugin's source. plugin_build compiles plugin source and
installs it (origin local); consent is asked once per artifact hash.
plugin_reload attaches a fresh plugin instance — in-instance state not
written through the artifact's persistence is lost. Building plugins is
not a general code-execution path: compiled artifacts pass the unchanged
capability/policy gate like any other plugin.
</plugin-lifecycle>''';

  @override
  void onPrompt(TurnContext c) {
    c.promptSections.add(pluginLifecycleSection);
  }

  @override
  void mountOn(AgentLoop loop) {
    loop.registerContextExecutor(pluginBuildTool, _runBuild);
    loop.registerContextExecutor(
        pluginReloadTool, (_, _) async => _runReload());
    loop.registerContextExecutor(
        pluginStatusTool, (_, _) async => _runStatus());
  }

  Future<ToolResult> _runBuild(
      Map<String, Object?> input, ToolExecutionContext context) async {
    final source = input['source_dir'];
    if (source is! String || source.trim().isEmpty) {
      return ToolResult(
        'plugin_build requires source_dir: the plugin source directory path',
        isError: true,
      );
    }
    final flow = _buildFlow;
    if (flow == null) {
      // The honest fallback, mirroring the command's `build` argument:
      // this composition cannot compile (the engine component has no
      // local toolchain), so the build runs in the front end.
      return ToolResult(
        'plugin builds run where the toolchain lives: run '
        '/plugins build ${source.trim()} from the terminal session, or '
        'tina plugin build ${source.trim()} from the shell',
        isError: true,
      );
    }
    final report = await flow.run(source.trim());
    if (report.failure != null) {
      return ToolResult('plugin build failed: ${report.failure}',
          isError: true);
    }
    if (report.consentDeclined) {
      return ToolResult(
        'consent declined: nothing was installed and the previous artifact '
        'stays attached',
        isError: true,
      );
    }
    final build = report.build!;
    final lines = [
      'built ${build.name} ${build.version} (origin local, hash '
      '${build.hash.substring(0, 12)}…, built '
      '${build.builtAt.toUtc().toIso8601String()})',
    ];
    if (!report.attached) {
      lines.add('plugin not attached: the artifact is installed and mounts '
          'on the next session (or /plugins reload when one is)');
    } else if (report.reloaded) {
      final reload = _lastReload;
      final status = _manager.status();
      lines.add(switch (reload) {
        PromptBridgeOk(value: final lease) =>
          'reloaded: fresh store attached (lease $lease, '
              'lifecycle=${status.lifecycle}, reloads=${status.reloads})',
        PromptBridgeError(failure: final failure) =>
          'reload failed: ${failure.name} (lifecycle=${status.lifecycle})',
        null => 'reload offered (lifecycle=${status.lifecycle})',
      });
    }
    return ToolResult(lines.join('\n'));
  }

  ToolResult _runReload() {
    if (!_manager.isOpen) {
      return ToolResult('no wasm plugin attached; nothing to reload',
          isError: true);
    }
    return switch (_manager.reload()) {
      PromptBridgeOk(value: final lease) => ToolResult(
          'plugin ${_manager.status().pluginId} reloaded: fresh store '
          'attached (lease $lease, lifecycle='
          '${_manager.status().lifecycle}, opens='
          '${_manager.status().opens}, closes=${_manager.status().closes}, '
          'reloads=${_manager.status().reloads})'),
      PromptBridgeError(failure: final failure) =>
        ToolResult('plugin reload failed: ${failure.name}', isError: true),
    };
  }

  ToolResult _runStatus() {
    final status = _manager.status();
    final lines = [
      'plugin ${status.pluginId}: '
      '${status.open ? 'open' : 'closed'} (lease ${_manager.lease ?? '-'})',
      'lifecycle=${status.lifecycle} opens=${status.opens} '
      'closes=${status.closes} reloads=${status.reloads} '
      'lastFailure=${status.lastFailure?.name ?? 'none'}',
    ];
    final artifact = this.artifact;
    if (artifact != null) {
      lines.add(
        'artifact: origin=${artifact.origin}'
        '${artifact.hash == null ? '' : ' hash=${artifact.hash}'}'
        '${artifact.builtAt == null ? '' : ' built=${artifact.builtAt}'}',
      );
    } else {
      lines.add('artifact: provenance not reported by the launcher');
    }
    return ToolResult(lines.join('\n'));
  }

  @override
  List<Command> get commands => [
    Command(
      name: 'plugins',
      description: 'wasm plugin status; "reload" reattaches the plugin artifact',
      complete: (prefix) async => const ['build', 'reload']
          .where((word) => word.startsWith(prefix))
          .toList(),
      handler: (argument) async {
        switch (argument.trim().toLowerCase()) {
          case '' || 'status':
            final status = _manager.status();
            _terminal.writeln(
              'plugin ${status.pluginId}: '
              '${status.open ? 'open' : 'closed'} (lease ${_manager.lease ?? '-'})',
            );
            _terminal.writeln(
              'lifecycle=${status.lifecycle} opens=${status.opens} '
              'closes=${status.closes} reloads=${status.reloads} '
              'lastFailure=${status.lastFailure?.name ?? 'none'}',
            );
            final artifact = this.artifact;
            if (artifact != null) {
              _terminal.writeln(
                'artifact: origin=${artifact.origin}'
                '${artifact.hash == null ? '' : ' hash=${artifact.hash}'}'
                '${artifact.builtAt == null ? '' : ' built=${artifact.builtAt}'}',
              );
            }
          case 'build':
            // The compile runs host-side (the session front end runs the
            // local Dart SDK; this component cannot spawn processes).
            // The front end intercepts `/plugins build` there; this
            // reply is the honest fallback when it arrives raw.
            _terminal.writeln(
              'plugins build runs in the front end (it compiles with the '
              'local Dart SDK): run /plugins build <source-dir> from the '
              'terminal session, or tina plugin build <source-dir> from '
              'the shell.',
            );
          case 'reload':
            if (!_manager.isOpen) {
              _terminal.writeln('no wasm plugin attached; nothing to reload');
              return;
            }
            switch (_manager.reload()) {
              case PromptBridgeOk(value: final lease):
                final status = _manager.status();
                _terminal.writeln(
                  'plugin ${status.pluginId} reloaded: fresh store attached '
                  '(lease $lease, lifecycle=${status.lifecycle})',
                );
              case PromptBridgeError(failure: final failure):
                _terminal.writeln('plugin reload failed: ${failure.name}');
            }
          default:
            _terminal.writeln(
              "unknown /plugins argument "
              "(try '', 'status', 'build <source-dir>' or 'reload')",
            );
        }
      },
    ),
  ];
}
