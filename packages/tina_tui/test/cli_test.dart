import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_tui/tina_tui.dart';

void main() {
  test('informational flags need neither config nor a provider', () async {
    expect(await runCli(['--help']), 0);
    expect(await runCli(['--version'], version: '1.2.3'), 0);
    for (final shell in ['bash', 'zsh', 'fish']) {
      expect(shellCompletion(shell), contains('tina')); // shell-specific script
    }
  });
  test('incomplete, unknown and conflicting CLI flags fail before startup',
      () async {
    expect(await runCli(['--config']), 64);
    expect(await runCli(['--unknown']), 64);
    expect(await runCli(['--sessions', '--resume', 'id']), 64);
    expect(await runCli(['--completion', 'unsupported']), 64);
  });
  test(
      'missing config in a pipe gives setup instructions without creating a store',
      () async {
    final dir = Directory.systemTemp.createTempSync('tina-cli-');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(await runCli(['--config', '${dir.path}/config', '--cwd', dir.path]),
        78);
    expect(dir.listSync(), isEmpty);
  });
}
