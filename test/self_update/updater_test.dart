import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:tina/self_update/release_checker.dart';
import 'package:tina/self_update/updater.dart';
import 'package:test/test.dart';

/// Drives [installRelease] against real on-disk fixtures: a tarball built
/// with the system `tar` (exactly what users install with) and a fake
/// installed bundle. Skips when `tar` isn't on PATH.
void main() {
  final hasTar = Process.runSync('tar', ['--version']).exitCode == 0;
  Directory? scratch;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('tina_updater_');
  });

  tearDown(() {
    if (scratch?.existsSync() ?? false) scratch!.deleteSync(recursive: true);
  });

  /// Builds a tarball containing `bundle/bin/tina` with [marker] inside,
  /// plus an optional correct `.sha256` sidecar; returns both paths.
  ({File archive, File checksum}) buildArchive(String marker,
      {bool withChecksum = true}) {
    final s = scratch!;
    final src = Directory(p.join(s.path, 'src'))..createSync(recursive: true);
    final bundle = Directory(p.join(src.path, 'bundle'));
    Directory(p.join(bundle.path, 'bin')).createSync(recursive: true);
    Directory(p.join(bundle.path, 'lib')).createSync(recursive: true);
    File(p.join(bundle.path, 'bin', 'tina')).writeAsStringSync(marker);
    File(p.join(bundle.path, 'lib', 'libfake.so')).writeAsStringSync('lib');

    final archive = File(p.join(s.path, 'tina-v9.9.9-test.tar.gz'));
    final r = Process.runSync(
        'tar', ['czf', archive.path, '-C', src.path, 'bundle']);
    expect(r.exitCode, 0, reason: 'fixture tar build failed: ${r.stderr}');

    var checksum = File(p.join(s.path, 'unused.sha256'));
    if (withChecksum) {
      final sum = Process.runSync('shasum', ['-a', '256', archive.path]);
      final hex = ((sum.stdout as String).trim().split(' ').first);
      checksum = File(p.join(s.path, 'archive.tar.gz.sha256'))
        ..writeAsStringSync('$hex  archive.tar.gz');
    }
    return (archive: archive, checksum: checksum);
  }

  /// A fake installed bundle: `<root>/bin/tina` with [marker] inside.
  Directory buildInstalledBundle(String marker) {
    final root = Directory(p.join(scratch!.path, 'installed', 'bundle'));
    Directory(p.join(root.path, 'bin')).createSync(recursive: true);
    File(p.join(root.path, 'bin', 'tina')).writeAsStringSync(marker);
    return root;
  }

  ReleaseInfo releaseFor(String assetUrl, {String? checksumUrl}) =>
      ReleaseInfo(
        tag: 'v9.9.9',
        releaseUrl: 'https://example.com/rel',
        assetUrls: {
          'tina-v9.9.9-${targetForCurrentPlatform()}.tar.gz': assetUrl,
          if (checksumUrl != null)
            'tina-v9.9.9-${targetForCurrentPlatform()}.tar.gz.sha256':
                checksumUrl,
        },
      );

  group('bundleRootForCurrentProcess', () {
    test('recognizes a <root>/bin/tina layout', () {
      final root = buildInstalledBundle('x');
      final exe = p.join(root.path, 'bin', 'tina');
      expect(bundleRootForCurrentProcess(resolvedExecutable: exe), root.path);
    });

    test('rejects non-tina binaries and missing files', () {
      final s = scratch!;
      File(p.join(s.path, 'bin', 'other')).createSync(recursive: true);
      expect(
          bundleRootForCurrentProcess(
              resolvedExecutable: p.join(s.path, 'bin', 'other')),
          isNull);
      // Right name, but the file doesn't exist on disk.
      expect(
          bundleRootForCurrentProcess(
              resolvedExecutable: p.join(s.path, 'bin', 'tina')),
          isNull);
    });

    test('dart-run process (VM as resolvedExecutable) has no bundle root',
        () {
      // Under `dart test` the resolved executable is the VM, never a bundle.
      expect(bundleRootForCurrentProcess(), isNull);
    });
  });

  group('installRelease', () {
    test('swaps the bundle and leaves <root>.old behind', () async {
      final installed = buildInstalledBundle('old');
      final fixture = buildArchive('new-tina');
      final lines = <String>[];

      final result = await installRelease(
        releaseFor('https://example.com/asset'),
        notice: lines.add,
        bundleRootOverride: installed.path,
        workDirOverride: p.join(scratch!.path, 'work'),
        archiveSupplier: () async => fixture.archive,
      );

      expect(result, UpdateResult.success);
      expect(
          File(p.join(installed.path, 'bin', 'tina')).readAsStringSync(),
          'new-tina');
      expect(
          Directory('${installed.path}.old').existsSync(), isTrue,
          reason: 'the old bundle is renamed aside for a later-launch sweep');
      expect(
          File(p.join('${installed.path}.old', 'bin', 'tina'))
              .readAsStringSync(),
          'old');
      expect(lines.any((l) => l.contains('restart')), isTrue);
    }, skip: !hasTar);

    test('verifies a matching sha256 and proceeds', () async {
      final installed = buildInstalledBundle('old');
      final fixture = buildArchive('new-tina');
      final client = _UrlClient({
        'checksum': fixture.checksum.readAsStringSync(),
      });

      final result = await installRelease(
        releaseFor('https://example.com/asset',
            checksumUrl: 'checksum'),
        notice: (_) {},
        client: client,
        bundleRootOverride: installed.path,
        workDirOverride: p.join(scratch!.path, 'work'),
        archiveSupplier: () async => fixture.archive,
      );

      expect(result, UpdateResult.success);
      expect(File(p.join(installed.path, 'bin', 'tina')).readAsStringSync(),
          'new-tina');
    }, skip: !hasTar);

    test('a wrong sha256 fails without touching the install', () async {
      final installed = buildInstalledBundle('old');
      final fixture = buildArchive('new-tina');
      final bad = File(p.join(scratch!.path, 'bad.sha256'))
        ..writeAsStringSync('${'0' * 64}  archive.tar.gz');
      final client = _UrlClient({'checksum': bad.readAsStringSync()});

      final result = await installRelease(
        releaseFor('https://example.com/asset',
            checksumUrl: 'checksum'),
        notice: (_) {},
        client: client,
        bundleRootOverride: installed.path,
        workDirOverride: p.join(scratch!.path, 'work'),
        archiveSupplier: () async => fixture.archive,
      );

      expect(result, UpdateResult.failed);
      expect(File(p.join(installed.path, 'bin', 'tina')).readAsStringSync(),
          'old');
      expect(Directory('${installed.path}.old').existsSync(), isFalse);
    }, skip: !hasTar);

    test('no asset for this platform is unsupported', () async {
      final release = ReleaseInfo(
        tag: 'v9.9.9',
        releaseUrl: 'https://example.com/rel',
        assetUrls: const {
          'tina-v9.9.9-windows-x64.tar.gz': 'https://example.com/win',
        },
      );
      final result = await installRelease(release,
          notice: (_) {},
          bundleRootOverride: '/tmp/whatever',
          workDirOverride: p.join(scratch!.path, 'work'));
      expect(result, UpdateResult.unsupported);
    });

    test('no bundle root (running from source) needs manual update', () async {
      final fixture = buildArchive('new-tina');
      final result = await installRelease(
        releaseFor('https://example.com/asset'),
        notice: (_) {},
        // No override: under `dart test` there is no bundle install.
        workDirOverride: p.join(scratch!.path, 'work'),
        archiveSupplier: () async => fixture.archive,
      );
      expect(result, UpdateResult.manualRequired);
    }, skip: !hasTar);

    test('a non-bundle archive (no bundle/bin/tina) fails and rolls back',
        () async {
      final installed = buildInstalledBundle('old');
      final s = scratch!;
      final src = Directory(p.join(s.path, 'badsrc'))
        ..createSync(recursive: true);
      File(p.join(src.path, 'readme.txt')).writeAsStringSync('not a bundle');
      final archive = File(p.join(s.path, 'bad.tar.gz'));
      expect(
          Process.runSync(
                  'tar', ['czf', archive.path, '-C', src.path, 'readme.txt'])
              .exitCode,
          0);

      final result = await installRelease(
        releaseFor('https://example.com/asset'),
        notice: (_) {},
        bundleRootOverride: installed.path,
        workDirOverride: p.join(s.path, 'work'),
        archiveSupplier: () async => archive,
      );

      expect(result, UpdateResult.failed);
      expect(File(p.join(installed.path, 'bin', 'tina')).readAsStringSync(),
          'old');
      expect(Directory('${installed.path}.old').existsSync(), isFalse,
          reason: 'the swap must roll back on a bad archive');
    }, skip: !hasTar);
  });

  test('cleanupStaleOldBundle removes the .old sibling', () {
    final installed = buildInstalledBundle('old');
    Directory('${installed.path}.old').createSync(recursive: true);

    cleanupStaleOldBundle(bundleRootOverride: installed.path);
    expect(Directory('${installed.path}.old').existsSync(), isFalse);
    expect(installed.existsSync(), isTrue);
  });
}

/// Serves canned bodies keyed by full URL string, for the checksum fetch.
class _UrlClient extends http.BaseClient {
  _UrlClient(this.bodies);
  final Map<String, String> bodies;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = bodies[request.url.toString()];
    return http.StreamedResponse(
      Stream.value(body?.codeUnits ?? const <int>[]),
      body == null ? 404 : 200,
    );
  }
}
