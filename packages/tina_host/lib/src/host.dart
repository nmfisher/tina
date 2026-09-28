/// The assembly: build the provider (via the config's factory), mount the
/// config's plugins — one of which owns the tool set and the mode — and
/// expose start and send.
///
/// One host owns one session. The provider is built **per host** — two
/// hosts from one config never share an instance, which is what lets a
/// daemon hold many sessions later without double-closes.
///
/// When the config names a [HostConfig.storePath], the host owns that
/// store link: it records the session, subscribes the store as the log's
/// listener, and appends every entry as the loop publishes it. The loop
/// stays the only writer of the log; the store is its durable cache, and
/// the bytes it holds are the bytes the loop published ([SessionStore]).
/// A host without a store path runs entirely in memory.
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
import 'store.dart';

/// One running session and everything it needs.
final class Host {
  Host._({
    required this.config,
    required this.session,
    this.store,
    this.registryKey,
  });

  /// The config this host was built from. Held, not owned: a second host
  /// from the same config is legitimate.
  final HostConfig config;

  /// The one session this host owns.
  final Session session;

  /// The store link this host owns, when the config named one. Null for
  /// an in-memory session.
  final SessionStore? store;

  /// The store's registry row for this session, when persisted; null for
  /// an in-memory session.
  final int? registryKey;

  /// Start a session from [config]: build the provider via the config's
  /// factory (once, for this host alone), then register the config's
  /// plugins on the loop. Whoever contributes tools also registers their
  /// executors — the host only creates the loop and hands it over.
  ///
  /// With a [HostConfig.storePath] the host opens the store, records the
  /// session (or resumes it — see [resume]) and wires the store to the
  /// log before the first turn can run, so no entry can be missed.
  static Host start(HostConfig config, {String? sessionId}) {
    final id = sessionId ?? 's-${DateTime.now().microsecondsSinceEpoch}';
    final provider = config.providerFactory(config.model);
    final loop = AgentLoop(
        provider: provider,
        plugins: config.plugins,
        settings: SessionSettings(systemPrompt: config.systemPrompt));
    // A plugin that owns executors mounts them itself; the host only
    // creates the loop and honors the interface.
    for (final plugin in config.plugins) {
      if (plugin is MountsTools) (plugin as MountsTools).mountOn(loop);
    }
    SessionStore? store;
    int? registryKey;
    if (config.storePath != null) {
      store = SessionStore.open(config.storePath!);
      registryKey =
          store.createSession(id, title: config.sessionTitle, details: config.details);
      // The store is the log's first listener: everything the loop
      // publishes from here on lands in SQLite, in publish order.
      loop.subscribe((entry, event) {
        if (event == LogEvent.appended) {
          store!.append(id, [entry]);
        }
      });
    }
    final host = Host._(
      config: config,
      session: Session(id: id, loop: loop, details: config.details),
      store: store,
      registryKey: registryKey,
    );
    return host;
  }

  /// Resume a persisted session: the loop is seeded from the store's
  /// slice and subscribes from there, so history is the derived context
  /// and new entries continue the same log. (Wired into the shell in the
  /// next slice step; the store mechanics live here.)
  static Host resume(HostConfig config, String sessionId) {
    if (config.storePath == null) {
      throw StateError('resume needs a config with a storePath');
    }
    final store = SessionStore.open(config.storePath!);
    final history = store.readEntries(sessionId);
    final gaps = store.checkGaps(sessionId);
    if (gaps.isNotEmpty) {
      store.close();
      throw SessionStoreException(
          'session $sessionId is corrupt: ${gaps.join('; ')}');
    }
    final provider = config.providerFactory(config.model);
    final loop = AgentLoop(
        provider: provider,
        plugins: config.plugins,
        settings: SessionSettings(systemPrompt: config.systemPrompt),
        seedLog: history);
    for (final plugin in config.plugins) {
      if (plugin is MountsTools) (plugin as MountsTools).mountOn(loop);
    }
    // New entries continue the same slice: the store listener appends as
    // before (the registry row already exists).
    loop.subscribe((entry, event) {
      if (event == LogEvent.appended) {
        store.append(sessionId, [entry]);
      }
    });
    return Host._(
      config: config,
      session: Session(
          id: sessionId,
          loop: loop,
          // The counters a resume restores: what the registry row
          // carried when the session last saved them.
          details: store.readDetails(sessionId)),
      store: store,
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

  /// Persist the session's details as they read right now. The registry
  /// row is append-only, so this writes a fresh row naming the same
  /// session: [readDetails] and [resume] take the **latest** row. Call
  /// it whenever the counters change and durability matters — a child
  /// spawned, a child settled, tokens booked — so a crash loses at most
  /// the delta since the last save. No-op for an in-memory session.
  void saveDetails() {
    final store = this.store;
    if (store == null) return;
    store.updateDetails(session.id, session.details);
  }

  /// Close the store link. The session stays usable in memory; the store
  /// stops accepting writes. Idempotent.
  void close() {
    store?.close();
  }
}
