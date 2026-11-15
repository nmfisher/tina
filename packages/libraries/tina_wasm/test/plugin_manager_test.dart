import 'package:test/test.dart';
import 'package:tina_wasm/src/plugin_manager.dart';
import 'package:tina_wasm/src/remote_prompt_plugin.dart';

/// Mirrors the host runtime's lease rules: a close of an unknown lease is
/// denied (it was already revoked host-side), and calls on a revoked lease
/// are denied too.
final class _RecordingBridge implements PromptPluginHostBridge {
  var _next = 1;
  final opened = <String>[];
  final retired = <String>[];
  bool denyOpen = false;
  bool failClose = false;

  void revoke(String lease) {
    opened.remove(lease);
    retired.add(lease);
  }

  @override
  PromptBridgeResult<String> open() {
    if (denyOpen) {
      return const PromptBridgeResult<String>.error(
        PromptBridgeFailure.unavailable,
      );
    }
    final lease = 'lease-${_next++}';
    opened.add(lease);
    return PromptBridgeResult<String>.ok(lease);
  }

  @override
  Future<PromptBridgeResult<String>> onPrompt({
    required String lease,
    required String sessionId,
    required String model,
  }) async {
    if (!opened.contains(lease)) {
      return const PromptBridgeResult<String>.error(
        PromptBridgeFailure.denied,
      );
    }
    return PromptBridgeResult<String>.ok('session=$sessionId model=$model');
  }

  @override
  PromptBridgeResult<void> close({required String lease}) {
    if (failClose) {
      return const PromptBridgeResult<void>.error(PromptBridgeFailure.failed);
    }
    if (!opened.contains(lease)) {
      return const PromptBridgeResult<void>.error(PromptBridgeFailure.denied);
    }
    opened.remove(lease);
    retired.add(lease);
    return const PromptBridgeResult<void>.ok(null);
  }
}

void main() {
  test('open, status and close track the lease book', () {
    final bridge = _RecordingBridge();
    final manager = PluginManager(bridge: bridge);

    final idle = manager.status();
    expect(idle.open, isFalse);
    expect(idle.pluginId, RemotePromptPlugin.pluginId);
    expect(idle.toJson()['lastFailure'], isNull);

    final lease = manager.open();
    expect(lease, isA<PromptBridgeOk<String>>());
    final open = manager.status();
    expect(open.open, isTrue);
    expect(open.lifecycle, 1);
    expect(open.opens, 1);

    final done = manager.close();
    expect(done, isA<PromptBridgeOk<void>>());
    final closed = manager.status();
    expect(closed.open, isFalse);
    expect(closed.lifecycle, 2);
    expect(closed.opens, 1);
    expect(closed.closes, 1);
    expect(bridge.retired, [lease.valueOrThrow()]);
  });

  test('double open and stray close are contract violations', () {
    final manager = PluginManager(bridge: _RecordingBridge());
    manager.open();
    expect(() => manager.open(), throwsStateError);
    manager.close();
    expect(() => manager.close(), throwsStateError);
  });

  test('reload retires the live lease and attaches a fresh one', () {
    final bridge = _RecordingBridge();
    final manager = PluginManager(bridge: bridge);
    final first = manager.open().valueOrThrow();

    final second = manager.reload().valueOrThrow();
    expect(second, isNot(first));
    expect(bridge.retired, [first]);
    final status = manager.status();
    expect(status.open, isTrue);
    expect(status.opens, 2);
    expect(status.closes, 1);
    expect(status.reloads, 1);
    expect(status.lifecycle, 3);
  });

  test('reload while idle is a plain open', () {
    final bridge = _RecordingBridge();
    final manager = PluginManager(bridge: bridge);
    final lease = manager.reload().valueOrThrow();
    expect(bridge.opened, [lease]);
    final status = manager.status();
    expect(status.reloads, 1);
    expect(status.closes, 0);
    expect(status.opens, 1);
  });

  test('a transient close failure keeps the lease and aborts reload', () {
    final bridge = _RecordingBridge();
    final manager = PluginManager(bridge: bridge);
    final first = manager.open().valueOrThrow();

    bridge.failClose = true;
    final closed = manager.close();
    expect(closed, isA<PromptBridgeError<void>>());
    // The lease stays tracked so a retry can retire it.
    expect(manager.status().open, isTrue);
    expect(manager.status().lastFailure, PromptBridgeFailure.failed);

    final reload = manager.reload();
    expect(reload, isA<PromptBridgeError<String>>());
    // No second lease was stacked on the live one.
    expect(bridge.opened, [first]);
    expect(manager.status().reloads, 0);

    bridge.failClose = false;
    expect(manager.close(), isA<PromptBridgeOk<void>>());
    expect(manager.status().open, isFalse);
  });

  test('a denied close means the host already revoked the lease', () {
    final bridge = _RecordingBridge();
    final manager = PluginManager(bridge: bridge);
    final first = manager.open().valueOrThrow();

    // Host-side epoch kill / close-during-call: the lease is already gone.
    bridge.revoke(first);
    final closed = manager.close();
    expect(closed, isA<PromptBridgeError<void>>());
    final status = manager.status();
    expect(status.open, isFalse);
    expect(status.lifecycle, 2);
    expect(status.lastFailure, PromptBridgeFailure.denied);
    // The manager can open again immediately.
    expect(manager.open(), isA<PromptBridgeOk<String>>());
  });

  test('a failed open records the failure and stays idle', () {
    final bridge = _RecordingBridge();
    final manager = PluginManager(bridge: bridge);
    bridge.denyOpen = true;
    final opened = manager.open();
    expect(opened, isA<PromptBridgeError<String>>());
    final status = manager.status();
    expect(status.open, isFalse);
    expect(status.opens, 0);
    expect(status.lifecycle, 0);
    expect(status.lastFailure, PromptBridgeFailure.unavailable);

    bridge.denyOpen = false;
    expect(manager.open(), isA<PromptBridgeOk<String>>());
  });
}

extension on PromptBridgeResult<String> {
  // Test-only convenience: the manager returns lease strings.
  String valueOrThrow() => switch (this) {
    PromptBridgeOk(value: final value) => value,
    PromptBridgeError(failure: final failure) => throw StateError(
      'expected a lease, got $failure',
    ),
  };
}
