/// Lifecycle-level management for the host-mediated wasm prompt plugin:
/// open, status, reload and close over a [PromptPluginHostBridge].
///
/// This is the groundwork a TUI panel or agent management command would
/// consult inside the engine component. It deliberately covers lease
/// bookkeeping only: prompt content, the onPrompt frame shape and approval
/// behavior are embedder-surface decisions (issue #85, escalated with the
/// principal) and are out of scope here.
///
/// Semantics mirror the host runtime (`docs/plugin_boundary.md` in
/// wasm.dart): the lease tracked here is revoked by any host-side kill or
/// close-during-call, so a bridge `denied` on close means "already gone"
/// rather than "refused": the manager drops its bookkeeping and reports
/// idle. A transient host failure (`unavailable`/`failed`) keeps the lease
/// so a retry can still retire it.
library;

import 'remote_prompt_plugin.dart'
    show
        PromptBridgeError,
        PromptBridgeFailure,
        PromptBridgeOk,
        PromptBridgeResult,
        PromptPluginHostBridge,
        RemotePromptPlugin;

/// Immutable observation of one [PluginManager]'s lease book.
final class PluginManagerStatus {
  const PluginManagerStatus({
    required this.pluginId,
    required this.open,
    required this.lifecycle,
    required this.opens,
    required this.closes,
    required this.reloads,
    this.lastFailure,
  });

  final String pluginId;

  /// Whether a lease is currently tracked (the guest Store may still be
  /// draining a deferred retirement host-side).
  final bool open;

  /// Bumped on every lifecycle transition, mirroring
  /// `RemotePromptPlugin`'s counter: an in-flight prompt that observes a
  /// different value knows its lease was retired underneath it.
  final int lifecycle;
  final int opens;
  final int closes;
  final int reloads;

  /// The most recent bridge failure, if any. Cleared by nothing: status is
  /// an observation, not a reset surface.
  final PromptBridgeFailure? lastFailure;

  Map<String, Object?> toJson() => {
    'pluginId': pluginId,
    'open': open,
    'lifecycle': lifecycle,
    'opens': opens,
    'closes': closes,
    'reloads': reloads,
    'lastFailure': lastFailure?.name,
  };
}

/// Tracks exactly one lease over one host bridge.
final class PluginManager {
  PluginManager({required PromptPluginHostBridge bridge, String? pluginId})
    : _bridge = bridge,
      pluginId = pluginId ?? RemotePromptPlugin.pluginId;

  final PromptPluginHostBridge _bridge;
  final String pluginId;

  String? _lease;
  var _lifecycle = 0;
  var _opens = 0;
  var _closes = 0;
  var _reloads = 0;
  PromptBridgeFailure? _lastFailure;

  PluginManagerStatus status() => PluginManagerStatus(
    pluginId: pluginId,
    open: _lease != null,
    lifecycle: _lifecycle,
    opens: _opens,
    closes: _closes,
    reloads: _reloads,
    lastFailure: _lastFailure,
  );

  /// Attach a fresh plugin Store. Throws [StateError] when a lease is
  /// already tracked; call [reload] instead — the host runtime refuses a
  /// second open while the boundary is busy anyway (`Busy`).
  PromptBridgeResult<String> open() {
    if (_lease != null) {
      throw StateError('plugin $pluginId is already open');
    }
    final result = _track(_bridge.open());
    switch (result) {
      case PromptBridgeOk(value: final lease):
        _lease = lease;
        _opens++;
        _lifecycle++;
      case PromptBridgeError():
        break;
    }
    return result;
  }

  /// Revoke the tracked lease and retire its Store. A `denied` failure is
  /// still terminal (the host already revoked the lease), so the manager
  /// reports idle afterwards; a transient failure keeps the lease.
  PromptBridgeResult<void> close() {
    final lease = _lease;
    if (lease == null) {
      throw StateError('plugin $pluginId is not open');
    }
    final result = _track(_bridge.close(lease: lease));
    switch (result) {
      case PromptBridgeOk():
      case PromptBridgeError(failure: PromptBridgeFailure.denied):
        _lease = null;
        _closes++;
        _lifecycle++;
      case PromptBridgeError():
        break;
    }
    return result;
  }

  /// Drop the live lease and attach a fresh plugin Store. With the host's
  /// compile-on-load `--plugin-watch` mode this picks up a rebuilt artifact
  /// without restarting or rebuilding the engine. A transient close failure
  /// aborts the reload (no second lease is stacked on a live one).
  PromptBridgeResult<String> reload() {
    if (_lease != null) {
      final closed = close();
      if (closed case PromptBridgeError(failure: final failure)) {
        return PromptBridgeResult<String>.error(failure);
      }
    }
    _reloads++;
    return open();
  }

  PromptBridgeResult<T> _track<T>(PromptBridgeResult<T> result) {
    if (result case PromptBridgeError(failure: final failure)) {
      _lastFailure = failure;
    }
    return result;
  }
}
