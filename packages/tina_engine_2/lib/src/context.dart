/// The per-turn snapshot plugins receive, and the one cancellation token.
/// Plugin-facing types: every hook takes a [Context].
library;

import 'dart:collection';

import 'package:tina_core/tina_core.dart';

/// The one cancellation path. Set once; there is no unset. The loop checks
/// it before every model call and before every tool.
final class CancelToken {
  bool cancelled = false;
  String reason = '';

  /// First cancel wins. Later calls change nothing.
  void cancel(String why) {
    if (cancelled) return;
    cancelled = true;
    reason = why;
  }
}

/// What a plugin sees when a hook runs.
///
/// A snapshot: the transcript up to now, the tools pinned for this turn, and
/// the registries the plugin may read. Read-only by construction — the core
/// owns the transcript, and a plugin's only way to act is to return a
/// decision from a hook. The loop builds a fresh snapshot per hook; all of
/// them share one [CancelToken].
final class Context {
  Context({
    required List<Message> transcript,
    required List<ToolSchema> tools,
    required bool Function(String pluginId) isLive,
    required Map<String, Object> services,
    required Map<String, Object?> turnState,
    required CancelToken cancel,
  })  : transcript = UnmodifiableListView(transcript),
        tools = UnmodifiableListView(tools),
        _isLive = isLive,
        _services = UnmodifiableMapView(services),
        turn = UnmodifiableMapView(turnState),
        _cancel = cancel;

  /// The transcript up to the point this snapshot was built, including
  /// everything the turn has appended so far. Mutating it throws.
  final List<Message> transcript;

  /// The tools pinned at the turn boundary, for the whole turn.
  final List<ToolSchema> tools;

  final bool Function(String pluginId) _isLive;
  final Map<String, Object> _services;
  final CancelToken _cancel;

  /// Is the plugin with this id still registered? The loop re-checks this
  /// before dispatching a tool; a plugin may read it too.
  bool isLive(String pluginId) => _isLive(pluginId);

  /// A service registry the host fills before the loop runs. Tools look up
  /// their collaborators here. Read-only for plugins.
  Object? service(String name) => _services[name];

  /// Per-turn scratch space, cleared at the turn boundary. The core never
  /// reads it and it is not part of any snapshot.
  final Map<String, Object?> turn;

  /// True once the turn has been cancelled.
  bool get cancelled => _cancel.cancelled;

  /// Why the turn was cancelled. Empty when not cancelled.
  String get cancelReason => _cancel.reason;

  /// Mark the turn cancelled. First call wins.
  void cancel(String why) => _cancel.cancel(why);

  /// Number of messages in the snapshot.
  int get messageCount => transcript.length;
}
