import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_mcp/tina_mcp.dart';

void main() {
  test(
      'config validates transport-specific keys and missing credential variables',
      () {
    expect(
        () => McpServerConfig(
            'x', {'command': 'cmd', 'url': 'https://example.com/mcp'}),
        throwsFormatException);
    expect(() => McpServerConfig('x', {'url': 'file:///tmp/server'}),
        throwsFormatException);
    expect(() => McpServerConfig('x', {'command': 'cmd', 'args': '--arg'}),
        throwsFormatException);
    expect(
        () => McpServerConfig('x', {
              'url': 'https://example.com/mcp',
              'headers': {'Mcp-Session-Id': 'x'}
            }),
        throwsFormatException);
    expect(() => McpServerConfig('x', {'command': 'cmd', 'timeout_ms': -1}),
        throwsFormatException);
    expect(() => McpServerConfig('x', {'command': 'cmd', 'enabeld': false}),
        throwsFormatException);
    expect(McpServerConfig('x', {'command': 'cmd', 'timeout_ms': 0}).timeout,
        isNull);
    expect(
        () => McpServerConfig.expand('\${MISSING}', {}), throwsFormatException);
    expect(McpServerConfig.expand('Bearer \${TOKEN}', {'TOKEN': 'fixture'}),
        'Bearer fixture');
  });
  test('plugin-owned saves preserve providers, variables and unknown tables',
      () {
    final directory = Directory.systemTemp.createTempSync('mcp-config-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/config')..writeAsStringSync('''
version = 1
[default]
model = "fixture"
[providers.fixture]
api_key_env = "KEEP_TOKEN"
[unrelated]
enabled = true
''');
    final store = McpConfigStore(file.path);
    store.save(McpServerConfig('blender', {
      'command': '/path/to/blender-mcp',
      'env': {'TOKEN': '\${BLENDER_TOKEN}'}
    }));
    store.save(store.read().single.withValue('enabled', false));
    expect(store.read().single.enabled, false);
    expect(store.read().single.environment['TOKEN'], '\${BLENDER_TOKEN}');
    expect(file.readAsStringSync(), contains('KEEP_TOKEN'));
    expect(file.readAsStringSync(), contains('[unrelated]'));
  });
}
