/// The assembly: build the provider (via the config's factory), the
/// sandboxed filesystem, the tool set, and the plugin; expose start, send
/// a turn, and switch mode.
///
/// One host owns one session. The provider is built **per host** — two
/// hosts from one config never share an instance, which is what lets a
/// daemon hold many sessions later without double-closes.
library;

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart';

import 'host_config.dart';
import 'plugins.dart';
import 'session.dart';
import 'tool_set.dart';

/// One running session and everything it needs.
final class Host {
  Host._({
    required this.config,
    required this.session,
    required this.toolSet,
    required this.sandbox,
    required this.plugin,
  });

  /// The config this host was built from. Held, not owned: a second host
  /// from the same config is legitimate.
  final HostConfig config;

  /// The one session this host owns.
  final Session session;

  /// The session's tools over its sandbox.
  final ToolSet toolSet;

  /// The enforcement boundary. Mode is consulted **per call**; switching
  /// it here takes effect on the next tool call, not the next session.
  final SandboxedFileSystem sandbox;

  /// The host's prompt plugin — reads this sandbox for the live mode.
  final HostPlugin plugin;

  /// The permission mode right now — the sandbox's live value.
  PermissionMode get mode => sandbox.mode;

  /// Switch the session's mode. The next tool call obeys it.
  set mode(PermissionMode mode) => sandbox.mode = mode;

  /// Start a session from [config]: build the provider via the config's
  /// factory (once, for this host alone), the sandbox and tool set for the
  /// working directory, the plugin, and the loop that joins them.
  static Host start(HostConfig config, {String? sessionId}) {
    // One provider per session: the factory is called here, once. Never a
    // shared instance — the old engine is explicit that sharing causes
    // double-closes.
    final provider = config.providerFactory(config.model);
    final toolSet = ToolSet.forWorkspace(
      workspaceRoot: config.workingDirectory,
      tinaDir: config.effectiveTinaDir,
      mode: config.mode,
    );
    final sandbox = toolSet.sandbox;
    final plugin = HostPlugin(
      workingDirectory: config.workingDirectory,
      modeOf: () => sandbox.mode,
    );
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    toolSet.mountOn(loop);
    return Host._(
      config: config,
      session: Session(
        id: sessionId ?? 's-${DateTime.now().microsecondsSinceEpoch}',
        loop: loop,
        mode: config.mode,
      ),
      toolSet: toolSet,
      sandbox: sandbox,
      plugin: plugin,
    );
  }

  /// Send one user turn. Returns the turn's outcome; the assistant's reply
  /// is [Session.lastReply] afterwards.
  Future<Outcome> send(String text, {String? turnId}) {
    final outcome = session.loop
        .runTurn(Input(text, id: turnId ?? 't-${session.turns.length}'));
    return outcome.then((o) {
      session.turns.add(o);
      return o;
    });
  }
}
