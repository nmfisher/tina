import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_mcp/tina_mcp.dart';

void main() {
  late Directory root;
  late McpConfigStore store;
  late McpPlugin plugin;
  setUp(() {
    root = Directory.systemTemp.createTempSync('mcp-management-');
    store = McpConfigStore('${root.path}/config');
    plugin = McpPlugin.configured(
        store: store,
        workingDirectory: root.path,
        approve: (
                {required operation,
                required target,
                required reason,
                context = const {}}) async =>
            ApprovalDecision.deny);
  });
  tearDown(() async {
    await plugin.shutdown();
    root.deleteSync(recursive: true);
  });

  test('management merges current file values without owning other config', () {
    final management = plugin.management!;
    management.addLocalServer('fixture');
    store.save(store.read().single.withValue('args', ['external-edit']));
    management.setValue('fixture', 'enabled', true);
    expect(management.servers.single.arguments, ['external-edit']);
    expect(management.servers.single.enabled, isTrue);
    expect(() => (management.servers.single.values['args'] as List).clear(),
        throwsUnsupportedError);
    expect(() => management.servers.clear(), throwsUnsupportedError);
    expect(() => management.serverStatus['fixture'] = 'fake',
        throwsUnsupportedError);
    File(store.path).writeAsStringSync('');
    expect(() => management.setValue('fixture', 'enabled', true),
        throwsStateError);
    expect(store.read(), isEmpty,
        reason: 'stale editors must not recreate servers');
  });

  test('closed session rejects saves and paused views cannot delay shutdown',
      () async {
    final management = plugin.management!;
    final subscription = management.changes.listen((_) {});
    subscription.pause();
    management.addHttpServer('remote');
    await plugin.shutdown().timeout(const Duration(seconds: 1));
    final saved = File(store.path).readAsStringSync();
    expect(() => management.addLocalServer('fixture'), throwsStateError);
    expect(
        () => management.setValue('remote', 'enabled', true), throwsStateError);
    expect(File(store.path).readAsStringSync(), saved);
    await subscription.cancel();
  });
}
