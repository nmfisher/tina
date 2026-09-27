/// The assembly: build the provider (via the config's factory), mount the
/// config's plugins — one of which owns the tool set and the mode — and
/// expose start and send.
///
/// One host owns one session. The provider is built **per host** — two
/// hosts from one config never share an instance, which is what lets a
/// daemon hold many sessions later without double-closes.
///
/// The host is mode-blind: it never asks what the permission mode is,
/// never branches on it, and never decides whether something may run. The
/// value lives in the plugin that mounts the tool set
/// ([ToolsPlugin.mode] / [ToolsPlugin.setMode]); the file system reads it
/// per call.
library;

import 'package:tina_engine_2/tina_engine_2.dart';

import 'host_config.dart';
import 'plugins.dart';
import 'session.dart';

/// One running session and everything it needs.
final class Host {
  Host._({required this.config, required this.session});

  /// The config this host was built from. Held, not owned: a second host
  /// from the same config is legitimate.
  final HostConfig config;

  /// The one session this host owns.
  final Session session;

  /// Start a session from [config]: build the provider via the config's
  /// factory (once, for this host alone), then register the config's
  /// plugins on the loop. Whoever contributes tools also registers their
  /// executors — the host only creates the loop and hands it over.
  static Host start(HostConfig config, {String? sessionId}) {
    // One provider per session: the factory is called here, once. Never a
    // shared instance — the old engine is explicit that sharing causes
    // double-closes.
    final provider = config.providerFactory(config.model);
    final loop = AgentLoop(provider: provider, plugins: config.plugins);
    // A plugin that owns executors mounts them itself; the host only
    // creates the loop and honors the interface.
    for (final plugin in config.plugins) {
      if (plugin is MountsTools) (plugin as MountsTools).mountOn(loop);
    }
    final host = Host._(
      config: config,
      session: Session(
        id: sessionId ?? 's-${DateTime.now().microsecondsSinceEpoch}',
        loop: loop,
      ),
    );
    return host;
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
