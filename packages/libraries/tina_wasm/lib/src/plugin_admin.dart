/// TUI/agent-facing plugin management command (issue #85, principal
/// decision): `/plugins` shows the lease book, `/plugins reload` drops the
/// live lease and attaches a fresh plugin Store — with the host's
/// compile-on-load watch mode this picks up a rebuilt artifact without
/// restarting the engine.
///
/// Deliberately lifecycle-only: no prompt surface, no approval behavior.
/// The prompt adapter shares this plugin's [PluginManager], so a reload is
/// adopted by the next prompt automatically; an in-flight prompt observes
/// the lease change and discards itself instead of writing through a
/// retired store.
library;

import 'package:tina_core/tina_core.dart' show Command, Terminal;
import 'package:tina_engine_2/tina_engine_2.dart' show AgentPlugin;

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
      this.artifact})
    : _manager = manager,
      _terminal = terminal;

  static const pluginId = 'tina/wasm-plugin-admin';

  final PluginManager _manager;
  final Terminal _terminal;
  final PluginArtifactOrigin? artifact;

  @override
  String get id => pluginId;

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
