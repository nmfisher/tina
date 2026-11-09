/// Runs the real Tina lifecycle inside a Wasm guest. All checks throw in
/// product builds; the probe does not depend on Dart assertions.

library;

import 'dart:convert';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:wasm_components/wasm_components.dart' as cm;

import 'package:tina_wasm/src/components/tina_probe_engine_probe.dart' as root;
import 'package:tina_wasm/src/components/wasi_cli.dart' as wasi_cli;
import 'package:tina_wasm/src/components/wasmdart_tests.dart' as tests;
import 'package:tina_wasm/src/remote_prompt_plugin.dart';
import 'package:tina_wasm/src/wasm_prompt_bridge.dart';

void main() {
  root.engineProbeComponent(
    (imports) => (
      unnamedExport27: _LifecycleProbe(imports),
      unnamedExport16: const _Run(),
    ),
  );
}

final class _Run implements wasi_cli.Run {
  const _Run();

  @override
  Future<cm.Result<void, void>> run() async => const cm.OkResult(null);
}

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

/// Records real leases while forwarding every call to the generated imports.
final class _ObservedBridge implements PromptPluginHostBridge {
  _ObservedBridge(this.delegate);

  final PromptPluginHostBridge delegate;
  final leases = <String>[];

  @override
  PromptBridgeResult<String> open() {
    final result = delegate.open();
    if (result case PromptBridgeOk(value: final lease)) leases.add(lease);
    return result;
  }

  @override
  Future<PromptBridgeResult<String>> onPrompt({
    required String lease,
    required String sessionId,
    required String model,
  }) => delegate.onPrompt(lease: lease, sessionId: sessionId, model: model);

  @override
  PromptBridgeResult<void> close({required String lease}) =>
      delegate.close(lease: lease);
}

final class _LifecycleProbe implements tests.TestedModule {
  const _LifecycleProbe(this.imports);

  final root.EngineProbeImports imports;

  @override
  int countTests() => 1;

  void record(String check, Map<String, Object?> evidence) {
    imports.testsResultCollector.recordString(
      e: jsonEncode({'check': check, ...evidence}),
    );
  }

  void checkSection(Host host, Request request, int run) {
    const suffix = ';run=';
    final index = request.systemPrompt.lastIndexOf(suffix);
    _check(index > 0, 'Provider request has no plugin section');
    final decoded = jsonDecode(request.systemPrompt.substring(0, index));
    _check(decoded is Map, 'Plugin section is not a context object');
    final frame = decoded as Map;
    _check(frame.length == 2, 'Plugin received extra context fields');
    _check(frame['session_id'] == host.session.id, 'Wrong real session ID');
    _check(frame['model'] == host.model, 'Wrong current model');
    _check(
      int.parse(request.systemPrompt.substring(index + suffix.length)) == run,
      'Plugin-local run count did not match its Store lifetime',
    );
    _check(request.tools.isEmpty, 'Prompt hook changed tool registration');
  }

  @override
  Future<void> invokeTest({required int number}) async {
    _check(number == 0, 'Unknown lifecycle case');
    final bridge = _ObservedBridge(
      WasmPromptPluginHostBridge(imports.pluginHostSession),
    );
    final provider = ScriptedProvider(
      List.generate(5, (_) => scriptedReply('reply')),
      model: 'probe-model',
    );
    final host = Host.start(
      HostConfig(
        workingDirectory: '.',
        model: provider.model,
        providerFactory: (_) => provider,
      ),
      sessionId: 'wasm-prompt-lifecycle',
    );
    final session = host.session;
    final instances = <RemotePromptPlugin>[];
    final registry = PluginRegistry<void>(
      definitions: [
        PluginDefinition<void>(
          RemotePromptPlugin.pluginId,
          (_) {
            final instance = RemotePromptPlugin(bridge);
            instances.add(instance);
            return instance;
          },
          live: true,
          description: 'Lifecycle probe prompt contribution.',
        ),
      ],
    );
    final manager = PluginManager<void>(
      host: host,
      registry: registry,
      context: null,
    );
    try {
      manager.select([RemotePromptPlugin.pluginId]);
      _check(manager.lastError == null, 'Initial attachment failed');
      _check(bridge.leases.length == 1, 'Initial load did not open one lease');
      final oldLease = bridge.leases.single;
      final oldAdapter = instances.single;

      final first = await host.send('first turn');
      _check(first.stopReason == StopReason.complete, 'First turn failed');
      _check(provider.callCount == 1, 'First turn did not reach the provider');
      checkSection(host, provider.requests.last, 1);

      final second = await host.send('second turn');
      _check(second.stopReason == StopReason.complete, 'Second turn failed');
      _check(provider.callCount == 2, 'Second turn did not reach the provider');
      checkSection(host, provider.requests.last, 2);
      record('attached', {'session': host.session.id, 'calls': 2, 'run': 2});

      manager.select(const []);
      _check(manager.lastError == null, 'Live detach failed');
      _check(host.plugins.isEmpty, 'Adapter stayed mounted after detach');
      final baseline = await host.send('turn after unload');
      _check(
        baseline.stopReason == StopReason.complete,
        'Session stopped at unload',
      );
      _check(provider.callCount == 3, 'Post-unload turn missed the provider');
      _check(
        provider.requests.last.systemPrompt.isEmpty,
        'Unloaded section leaked',
      );
      _check(identical(session, host.session), 'Unload replaced the session');
      _check(
        provider.requests.last.messages.any(
          (message) =>
              message.role == Role.user &&
              message.content.whereType<TextBlock>().any(
                (block) => block.text == 'first turn',
              ),
        ),
        'Unload discarded prior conversation state',
      );
      record('unloaded-session-continues', {
        'session': host.session.id,
        'calls': 3,
      });

      final stale = await bridge.onPrompt(
        lease: oldLease,
        sessionId: host.session.id,
        model: host.model,
      );
      _check(
        stale is PromptBridgeError<String> &&
            stale.failure == PromptBridgeFailure.denied,
        'Retired host lease was accepted',
      );
      _check(provider.callCount == 3, 'Stale call affected the provider');
      record('stale-lease-denied', {'calls': provider.callCount});

      manager.select([RemotePromptPlugin.pluginId]);
      _check(manager.lastError == null, 'Reload attachment failed');
      _check(instances.length == 2, 'Reload reused the old adapter');
      _check(
        !identical(oldAdapter, instances.last),
        'Factory reused an adapter',
      );
      _check(bridge.leases.length == 2, 'Reload did not issue a lease');
      _check(bridge.leases.last != oldLease, 'Reload reused the retired lease');
      final reloaded = await host.send('turn after reload');
      _check(reloaded.stopReason == StopReason.complete, 'Reload turn failed');
      _check(provider.callCount == 4, 'Reload missed the provider');
      checkSection(host, provider.requests.last, 1);
      record('reloaded-fresh-store', {'calls': 4, 'run': 1});

      // Closing an already-detached adapter cannot close its successor's lease.
      oldAdapter.closeSession();
      final successor = await host.send('turn after stale adapter close');
      _check(
        successor.stopReason == StopReason.complete,
        'Old close broke successor',
      );
      _check(provider.callCount == 5, 'Successor missed the provider');
      checkSection(host, provider.requests.last, 2);
      _check(identical(session, host.session), 'Reload replaced the session');
      _check(
        host.session.turns.length == 5,
        'Completed turns were not retained',
      );
      record('old-close-keeps-successor', {'calls': 5, 'turns': 5, 'run': 2});
    } catch (error) {
      rethrow;
    } finally {
      manager.select(const []);
      await host.shutdown();
    }
  }
}
