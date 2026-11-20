/// The wasm compiled-component cache wiring (commit 29): the host gets
/// `--component-cache=<global dir>` when the directory preflights
/// clean; an unusable directory launches without the flag and produces
/// exactly one notice; the flag rides the wasm-host argv convention.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina/src/engine_launcher.dart'
    show prepareWasmComponentCache, wasmComponentCacheDir, wasmEngineArgv;

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('tina-wasm-cache-');
  });

  tearDown(() {
    home.deleteSync(recursive: true);
  });

  test('the cache directory is global under the user cache root', () {
    expect(wasmComponentCacheDir(environment: {'HOME': '/home/u'}),
        '/home/u/.cache/tina/wasm-components');
    expect(wasmComponentCacheDir(environment: {'HOME': '/home/u'}),
        isNot(contains('workspace')),
        reason: 'components are workspace-independent: one global cache');
  });

  test('a clean preflight creates the directory and stays quiet', () {
    final result = prepareWasmComponentCache(environment: {'HOME': home.path});
    expect(result.dir, '${home.path}/.cache/tina/wasm-components');
    expect(result.notice, isNull);
    expect(Directory(result.dir!).existsSync(), isTrue,
        reason: 'the directory is created on first use');
    expect(Directory('${result.dir}${Platform.pathSeparator}..')
        .listSync()
        .whereType<File>(), isEmpty,
        reason: 'the write probe cleans up after itself');

    // A second preflight is idempotent.
    final again = prepareWasmComponentCache(environment: {'HOME': home.path});
    expect(again.dir, result.dir);
    expect(again.notice, isNull);
  });

  test('an unusable directory keeps the cache off with one notice', () {
    // A FILE where the cache directory should be: creation fails.
    File('${home.path}/.cache').writeAsStringSync('in the way');
    final result = prepareWasmComponentCache(environment: {'HOME': home.path});

    expect(result.dir, isNull, reason: 'the flag stays off');
    expect(result.notice, isNotNull);
    expect(result.notice, contains('launching without it'));
    expect(result.notice, contains('wasm-components'),
        reason: 'the notice names the unusable directory');
  });

  test('the flag rides the wasm-host argv exactly when a dir is given', () {
    final base = wasmEngineArgv(
      hostPath: 'tina-wasm-host',
      workingDirectory: '/ws',
      configPath: '/cfg/config',
      yolo: true,
    );
    expect(base, isNot(contains(startsWith('--component-cache'))),
        reason: 'no cache dir: the flag is absent, the launch unchanged');

    final withCache = wasmEngineArgv(
      hostPath: 'tina-wasm-host',
      workingDirectory: '/ws',
      configPath: '/cfg/config',
      yolo: true,
      componentCache: '/home/u/.cache/tina/wasm-components',
    );
    expect(
        withCache,
        contains(
            '--component-cache=/home/u/.cache/tina/wasm-components'));
    // And it does not disturb the surrounding convention.
    expect(withCache.first, 'tina-wasm-host');
    expect(withCache.contains('--preopen=.=/ws'), isTrue,
        reason: 'the preopen convention is unchanged around the new flag');
  });
}
