import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina/self_update/release_checker.dart';
import 'package:tina/self_update/updater.dart';

void main() {
  final installer = p.absolute('install.sh');
  late Directory temp;
  late String launchDir;
  late String bundleDir;
  late String downloads;
  late String commands;
  late File archive;

  void write(String path, String text) {
    File(path).createSync(recursive: true);
    File(path).writeAsStringSync(text);
  }

  void executable(String path, String text) {
    write(path, text);
    expect(Process.runSync('chmod', ['+x', path]).exitCode, 0);
  }

  void release(String version) {
    final source = p.join(temp.path, 'source');
    executable(
      p.join(source, 'bundle', 'bin', 'tina'),
      '#!/bin/sh\necho "$version"\n',
    );
    write(p.join(source, 'bundle', 'lib', 'libnotcurses_merged.so'), version);
    final name = 'tina-v9.9.9-${targetForCurrentPlatform()}.tar.gz';
    archive = File(p.join(downloads, name));
    expect(
      Process.runSync('tar', [
        'czf',
        archive.path,
        '-C',
        source,
        'bundle',
      ]).exitCode,
      0,
    );
    final sum = Process.runSync('shasum', ['-a', '256', archive.path]);
    expect(sum.exitCode, 0);
    write('${archive.path}.sha256', sum.stdout as String);
  }

  Future<ProcessResult> install({
    List<String> args = const [],
    Map<String, String> env = const {},
  }) => Process.run(
    'sh',
    [installer, '--version', 'v9.9.9', '--insecure-checksum-only', ...args],
    environment: {
      'PATH': '$commands:${Platform.environment['PATH']}',
      'TINA_INSTALL_DIR': launchDir,
      'TINA_BUNDLE_DIR': bundleDir,
      'TINA_TEST_DOWNLOADS': downloads,
      ...env,
    },
  );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tina-install-test-');
    launchDir = p.join(temp.path, 'shared prefix', 'bin');
    bundleDir = p.join(temp.path, 'private data', 'tina');
    downloads = p.join(temp.path, 'downloads');
    commands = p.join(temp.path, 'commands');
    Directory(downloads).createSync();
    // Real archives and checksums, served locally without network or API keys.
    executable(p.join(commands, 'curl'), r'''#!/bin/sh
url=''
out=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
cp "$TINA_TEST_DOWNLOADS/${url##*/}" "$out"
''');
    release('old');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test(
    'installer migrates a shared prefix and updater replaces only its private bundle',
    () async {
      final launcher = p.join(launchDir, 'tina');
      write(launcher, 'legacy binary');
      final other = p.join(launchDir, 'other');
      final legacyLib = p.join(
        p.dirname(launchDir),
        'lib',
        'libnotcurses_merged.so',
      );
      final data = p.join(p.dirname(launchDir), 'share', 'other', 'data');
      write(other, 'other program');
      write(legacyLib, 'keep old library');
      write(data, 'other data');
      final result = await install();
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(Link(launcher).targetSync(), p.join(bundleDir, 'bin', 'tina'));
      expect(
        bundleRootForCurrentProcess(resolvedExecutable: launcher),
        bundleDir,
      );
      expect((await Process.run(launcher, ['--version'])).stdout, 'old\n');
      release('new');
      final updated = await installRelease(
        ReleaseInfo(
          tag: 'v9.9.9',
          releaseUrl: 'https://example.test/release',
          assetUrls: {
            'tina-v9.9.9-${targetForCurrentPlatform()}.tar.gz':
                'https://example.test/archive',
          },
        ),
        notice: (_) {},
        bundleRootOverride: bundleRootForCurrentProcess(
          resolvedExecutable: launcher,
        ),
        archiveSupplier: () async => archive,
        workDirOverride: p.join(temp.path, 'update'),
      );
      expect(updated, UpdateResult.success);
      expect((await Process.run(launcher, ['--version'])).stdout, 'new\n');
      expect(isOwnedBundleRoot(bundleDir), isTrue);
      cleanupStaleOldBundle(bundleRootOverride: bundleDir);
      expect(Directory('$bundleDir.old').existsSync(), isFalse);
      expect(File(other).readAsStringSync(), 'other program');
      expect(File(legacyLib).readAsStringSync(), 'keep old library');
      expect(File(data).readAsStringSync(), 'other data');
      // The installer can also upgrade an already migrated installation.
      release('newer');
      expect((await install()).exitCode, 0);
      expect((await Process.run(launcher, ['--version'])).stdout, 'newer\n');
    },
  );

  test(
    'XDG default and explicit launcher/bundle locations remain updateable',
    () async {
      final data = p.join(temp.path, 'xdg');
      final first = await install(
        env: {'TINA_BUNDLE_DIR': '', 'XDG_DATA_HOME': data},
      );
      expect(first.exitCode, 0, reason: '${first.stderr}');
      expect(
        bundleRootForCurrentProcess(
          resolvedExecutable: p.join(launchDir, 'tina'),
        ),
        p.join(data, 'tina'),
      );
      final custom = p.join(temp.path, 'custom launcher');
      final second = await install(
        args: ['--dir', custom, '--bundle-dir', bundleDir],
      );
      expect(second.exitCode, 0, reason: '${second.stderr}');
      expect(
        bundleRootForCurrentProcess(resolvedExecutable: p.join(custom, 'tina')),
        bundleDir,
      );
    },
  );

  test(
    'foreign bundle or backup is never replaced, including hidden files in bin',
    () async {
      write(p.join(bundleDir, 'keep'), 'foreign');
      expect((await install()).exitCode, isNot(0));
      expect(File(p.join(bundleDir, 'keep')).readAsStringSync(), 'foreign');
      Directory(bundleDir).deleteSync(recursive: true);
      expect((await install()).exitCode, 0);
      write(p.join(bundleDir, 'bin', '.foreign'), 'keep');
      expect(isOwnedBundleRoot(bundleDir), isFalse);
      expect((await install()).exitCode, isNot(0));
      File(p.join(bundleDir, 'bin', '.foreign')).deleteSync();
      write(p.join('$bundleDir.old', 'keep'), 'foreign backup');
      expect((await install()).exitCode, isNot(0));
      expect(
        File(p.join('$bundleDir.old', 'keep')).readAsStringSync(),
        'foreign backup',
      );
      expect(
        (await Process.run(p.join(launchDir, 'tina'), [])).stdout,
        'old\n',
      );
    },
  );

  test('failed launcher replacement rolls back the bundle', () async {
    expect((await install()).exitCode, 0);
    release('new');
    final realMv = (Process.runSync('which', ['mv']).stdout as String).trim();
    executable(
      p.join(commands, 'mv'),
      '#!/bin/sh\nif [ "\$1" = "-f" ]; then exit 1; fi\nexec "$realMv" "\$@"\n',
    );
    expect((await install()).exitCode, isNot(0));
    expect((await Process.run(p.join(launchDir, 'tina'), [])).stdout, 'old\n');
    expect(isOwnedBundleRoot(bundleDir), isTrue);
  });

  test(
    'installer and updater reject a bundle containing unrelated files',
    () async {
      expect((await install()).exitCode, 0);
      release('new');
      final source = p.join(temp.path, 'source');
      write(p.join(source, 'bundle', 'unrelated'), 'keep');
      expect(
        Process.runSync('tar', [
          'czf',
          archive.path,
          '-C',
          source,
          'bundle',
        ]).exitCode,
        0,
      );
      final sum = Process.runSync('shasum', ['-a', '256', archive.path]);
      write('${archive.path}.sha256', sum.stdout as String);
      expect((await install()).exitCode, isNot(0));
      final result = await installRelease(
        ReleaseInfo(
          tag: 'v9.9.9',
          releaseUrl: 'https://example.test/release',
          assetUrls: {
            'tina-v9.9.9-${targetForCurrentPlatform()}.tar.gz':
                'https://example.test/archive',
          },
        ),
        notice: (_) {},
        bundleRootOverride: bundleDir,
        archiveSupplier: () async => archive,
        workDirOverride: p.join(temp.path, 'update'),
      );
      expect(result, UpdateResult.failed);
      expect(
        (await Process.run(p.join(launchDir, 'tina'), [])).stdout,
        'old\n',
      );
      expect(Directory('$bundleDir.old').existsSync(), isFalse);
    },
  );
}
