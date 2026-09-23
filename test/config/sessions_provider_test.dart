import 'dart:io';

import 'package:test/test.dart';
import 'package:tina/config.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina_engine/tina_engine.dart';

void main() {
  // The `--list` informational path bypasses provider validation entirely
  // (it never builds a store), so tests that need the real parse supply
  // plausible model + budget values.
  const baseArgv = ['--model', 'anthropic/claude-sonnet-4-6'];

  Directory tempDir() {
    final d = Directory.systemTemp.createTempSync('tina-sp3-test');
    addTearDown(() => d.deleteSync(recursive: true));
    return d;
  }

  test('absent [sessions] config selects jsonl at the default location', () {
    final launch = Config.parse(baseArgv, env: const {});
    expect(launch.runtime.sessionStoreProvider, 'jsonl');
    expect(launch.runtime.sessionStoreRoot, isNull);
  });

  test('explicit jsonl provider decodes and projects to runtime', () {
    final launch = Config.parse(
      baseArgv,
      env: const {},
      userConfig: const UserConfig(sessions: SessionsConfig(provider: 'jsonl')),
    );
    expect(launch.runtime.sessionStoreProvider, 'jsonl');
    expect(launch.runtime.sessionStoreRoot, isNull);
  });

  test('jsonl root decodes and projects to runtime', () {
    final root = tempDir().path;
    final launch = Config.parse(
      baseArgv,
      env: const {},
      userConfig: UserConfig(
        sessions: SessionsConfig(provider: 'jsonl', jsonlRoot: root),
      ),
    );
    expect(launch.runtime.sessionStoreProvider, 'jsonl');
    expect(launch.runtime.sessionStoreRoot, root);
  });

  test('unknown provider fails fast at parse with the id named', () {
    expect(
      () => Config.parse(
        baseArgv,
        env: const {},
        userConfig: const UserConfig(
          sessions: SessionsConfig(provider: 'sqlite'),
        ),
      ),
      throwsA(
        isA<FormatException>()
            .having((e) => e.message, 'message', contains('sqlite'))
            .having(
              (e) => e.message,
              'known ids',
              contains(sessionStoreProviderIds.join(', ')),
            ),
      ),
    );
  });

  test('nonexistent root fails fast at parse', () {
    expect(
      () => Config.parse(
        baseArgv,
        env: const {},
        userConfig: const UserConfig(
          sessions: SessionsConfig(
            provider: 'jsonl',
            jsonlRoot: '/nonexistent-tina-sp3-root',
          ),
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('/nonexistent-tina-sp3-root'),
        ),
      ),
    );
  });

  test(
      'index and composition agree: resolveSessionIndex accepts every id the '
      'composition can mount', () {
    for (final id in sessionStoreProviderIds) {
      final root = tempDir();
      expect(
        resolveSessionIndex(provider: id, root: root),
        isA<SessionIndex>(),
      );
    }
  });

  test('resolveSessionIndex rejects an id outside sessionStoreProviderIds',
      () {
    expect(
      () => resolveSessionIndex(provider: 'sqlite'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('sqlite'),
        ),
      ),
    );
  });
}
