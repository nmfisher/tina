/// The local plugin build path: stub-compiler builds write cache
/// artifacts with a LOCAL origin marker; a missing toolchain and a
/// failing compiler surface clean errors (never stack traces); consent
/// is keyed by artifact hash and re-prompts on change.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:tina_plugin_registry/tina_plugin_registry.dart';

void main() {
  late Directory root;
  late Directory source;
  late PluginCache cache;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tina-build-');
    source = Directory('${root.path}/my-plugin')..createSync();
    Directory('${source.path}/bin').createSync();
    File('${source.path}/bin/main.dart').writeAsStringSync('void main() {}');
    File('${source.path}/pubspec.yaml')
        .writeAsStringSync('name: my-plugin\n');
    cache = PluginCache(root: Directory('${root.path}/plugins'));
  });

  tearDown(() => root.deleteSync(recursive: true));

  PluginCompiler succeed(List<int> bytes) =>
      (dir, output) async => PluginCompileOutcome(
            exitCode: 0,
            outputBytes: bytes,
          );

  test('a successful build installs into the cache with a local origin',
      () async {
    final bytes = List.generate(4096, (i) => i % 251);
    final service = PluginBuildService(
        cache: cache,
        compiler: succeed(bytes),
        now: () => DateTime.utc(2026, 12, 1, 10));

    final build = await service.build(source, 'my-plugin');

    final expectedHash = crypto.sha256.convert(bytes).toString();
    expect(build.version, 'local-${expectedHash.substring(0, 12)}');
    expect(build.hash, expectedHash);
    expect(build.componentPath, cache.componentFile('my-plugin', build.version).path);
    // The artifact is real bytes in the cache layout.
    expect(File(build.componentPath).readAsBytesSync(), bytes);
    // The install record carries the origin marker, the hash (the
    // consent key) and the build timestamp.
    final record = File(
            '${cache.pluginDir('my-plugin', build.version).path}/install.json')
        .readAsStringSync();
    final decoded = jsonDecode(record) as Map<String, Object?>;
    expect(decoded['origin'], 'local');
    expect(decoded['artifactHash'], expectedHash);
    expect(decoded['builtAt'], startsWith('2026-12-01T10'));
    // And the listing reads it back.
    final listed = await cache.list();
    expect(listed.single.origin, 'local');
    expect(listed.single.artifactHash, expectedHash);
    expect(listed.single.builtAt, startsWith('2026-12-01'));
  });

  test('a missing toolchain is a clean error naming the fix', () async {
    final compiler = sdkWasmCompiler(environment: {'PATH': ''});
    await expectLater(
      compiler(source, File('${root.path}/out.wasm')),
      throwsA(isA<PluginBuildException>().having(
          (e) => e.message,
          'message',
          allOf(contains('no Dart SDK'), contains('PATH')))),
    );
  });

  test('locateDart finds nothing on an empty PATH', () {
    expect(locateDart(environment: {}), isNull);
    expect(locateDart(environment: {'PATH': ''}), isNull);
  });

  test('a source dir without an entry point is a clean error', () async {
    Directory('${source.path}/bin').deleteSync(recursive: true);
    final service =
        PluginBuildService(cache: cache, compiler: succeed([1, 2, 3]));
    await expectLater(
      service.build(source, 'my-plugin'),
      throwsA(isA<PluginBuildException>()
          .having((e) => e.message, 'message', contains('entry point'))),
    );
  });

  test('a compiler failure surfaces the compiler stderr cleanly', () async {
    final service = PluginBuildService(
        cache: cache,
        compiler: (dir, output) async => const PluginCompileOutcome(
              exitCode: 1,
              stderr: 'Error: cannot resolve import wit:xyz',
            ));
    await expectLater(
      service.build(source, 'my-plugin'),
      throwsA(isA<PluginBuildException>()
          .having((e) => e.stderr, 'stderr', contains('cannot resolve import'))
          .having((e) => e.toString(), 'toString',
              contains('compilation failed'))),
    );
    // Nothing was installed.
    expect(await cache.list(), isEmpty);
  });

  test('a missing source directory is a clean error', () async {
    final service =
        PluginBuildService(cache: cache, compiler: succeed([1]));
    await expectLater(
      service.build(Directory('${root.path}/nope'), 'x'),
      throwsA(isA<PluginBuildException>()
          .having((e) => e.message, 'message', contains('not found'))),
    );
  });

  group('LocalPluginConsent', () {
    test('consent is keyed by hash, persists, and re-prompts on change',
        () async {
      final file = File('${root.path}/local-consent.json');
      final consent = LocalPluginConsent(file: file);
      final hashA = 'a' * 64;
      final hashB = 'b' * 64;
      expect(consent.needsConsent(hashA), isTrue);
      consent.remember(hashA);
      expect(consent.needsConsent(hashA), isFalse,
          reason: 'consent once per build');
      expect(consent.needsConsent(hashB), isTrue,
          reason: 'a changed hash re-prompts');
      // A fresh instance over the same file keeps the consent book
      // (it survives sessions).
      expect(LocalPluginConsent(file: file).needsConsent(hashA), isFalse);
    });

    test('a damaged consent book reads as empty (safe direction)', () {
      final file = File('${root.path}/broken-consent.json')
        ..writeAsStringSync('not json');
      final consent = LocalPluginConsent(file: file);
      expect(consent.needsConsent('a' * 64), isTrue);
    });
  });
}
