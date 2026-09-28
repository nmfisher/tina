import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:tina_self_update/tina_self_update.dart';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_approvals/tina_approvals.dart';

/// Drives [installRelease] against real on-disk fixtures: a tarball built
/// with the system `tar` (exactly what users install with) and a fake
/// installed bundle. Skips when `tar` isn't on PATH.
void main() {
  final hasTar = Process.runSync('tar', ['--version']).exitCode == 0;
  Directory? scratch;

  setUp(() {
    scratch = Directory(Directory.systemTemp
        .createTempSync('tina_updater_')
        .resolveSymbolicLinksSync());
  });

  tearDown(() {
    if (scratch?.existsSync() ?? false) scratch!.deleteSync(recursive: true);
  });

  /// Builds a tarball containing `bundle/bin/tina` with [marker] inside,
  /// plus an optional correct `.sha256` sidecar; returns both paths.
  ({File archive, File checksum}) buildArchive(
    String marker, {
    bool withChecksum = true,
    void Function(Directory)? alter,
  }) {
    final s = scratch!;
    final src = Directory(p.join(s.path, 'src'))..createSync(recursive: true);
    final bundle = Directory(p.join(src.path, 'bundle'));
    Directory(p.join(bundle.path, 'bin')).createSync(recursive: true);
    Directory(p.join(bundle.path, 'lib')).createSync(recursive: true);
    File(p.join(bundle.path, 'bin', 'tina')).writeAsStringSync(marker);
    File(
      p.join(bundle.path, 'lib', 'libnotcurses_merged.so'),
    ).writeAsStringSync('lib');
    for (final name in ['libsqlite3.so', 'libsqlite3.dylib']) {
      File(p.join(bundle.path, 'lib', name)).writeAsStringSync('sqlite');
    }

    alter?.call(bundle);
    final archive = File(p.join(s.path, 'tina-v9.9.9-test.tar.gz'));
    final r = Process.runSync('tar', [
      'czf',
      archive.path,
      '-C',
      src.path,
      'bundle',
    ]);
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

  /// A fake installed bundle: `<root>/bin/tina` with [marker] inside,
  /// stamped with [bundleMarkerName] unless [marked] is false (legacy
  /// pre-marker layouts).
  Directory buildInstalledBundle(String marker, {bool marked = true}) {
    final root = Directory(p.join(scratch!.path, 'installed', 'bundle'));
    Directory(p.join(root.path, 'bin')).createSync(recursive: true);
    File(p.join(root.path, 'bin', 'tina')).writeAsStringSync(marker);
    if (marked) {
      File(
        p.join(root.path, bundleMarkerName),
      ).writeAsStringSync('tina bundle root\n');
    }
    return root;
  }

  ReleaseInfo releaseFor(String assetUrl, {String? checksumUrl}) => ReleaseInfo(
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
    test(
      'resolves a launcher in a shared bin directory to the private bundle',
      () {
        final root = buildInstalledBundle('x');
        final bin = Directory(p.join(scratch!.path, 'shared', 'bin'))
          ..createSync(recursive: true);
        File(p.join(bin.path, 'other')).writeAsStringSync('keep');
        final launcher = Link(p.join(bin.path, 'tina'))
          ..createSync(
            p.relative(p.join(root.path, 'bin', 'tina'), from: bin.path),
          );
        expect(
          bundleRootForCurrentProcess(resolvedExecutable: launcher.path),
          root.path,
        );
      },
    );

    test('broken and cyclic launchers have no bundle root', () {
      final launcher = Link(p.join(scratch!.path, 'tina'))
        ..createSync('missing');
      expect(
        bundleRootForCurrentProcess(resolvedExecutable: launcher.path),
        isNull,
      );
      launcher.updateSync('tina');
      expect(
        bundleRootForCurrentProcess(resolvedExecutable: launcher.path),
        isNull,
      );
    });

    test('rejects linked bundle directories and hidden directories', () {
      final root = buildInstalledBundle('x');
      final alias = Link(p.join(scratch!.path, 'alias'))..createSync(root.path);
      expect(isOwnedBundleRoot(alias.path), isFalse);
      final foreign = Directory(p.join(scratch!.path, 'foreign'))..createSync();
      final lib = Link(p.join(root.path, 'lib'))..createSync(foreign.path);
      expect(isOwnedBundleRoot(root.path), isFalse);
      lib.deleteSync();
      Directory(p.join(root.path, '.data')).createSync();
      expect(isOwnedBundleRoot(root.path), isFalse);
    });

    test('recognizes a <root>/bin/tina layout', () {
      final root = buildInstalledBundle('x');
      final exe = p.join(root.path, 'bin', 'tina');
      expect(bundleRootForCurrentProcess(resolvedExecutable: exe), root.path);
    });

    test('rejects an unmarked (legacy) layout', () {
      final root = buildInstalledBundle('x', marked: false);
      final exe = p.join(root.path, 'bin', 'tina');
      expect(bundleRootForCurrentProcess(resolvedExecutable: exe), isNull);
    });

    test('rejects a root shared with other tools (foreign bin entry)', () {
      final root = buildInstalledBundle('x');
      File(p.join(root.path, 'bin', 'hermes')).writeAsStringSync('#!/bin/sh');
      final exe = p.join(root.path, 'bin', 'tina');
      expect(bundleRootForCurrentProcess(resolvedExecutable: exe), isNull);
    });

    test('rejects a root shared with other tools (foreign lib entry)', () {
      final root = buildInstalledBundle('x');
      Directory(p.join(root.path, 'lib')).createSync();
      File(p.join(root.path, 'lib', 'libforeign.so')).writeAsStringSync('x');
      final exe = p.join(root.path, 'bin', 'tina');
      expect(bundleRootForCurrentProcess(resolvedExecutable: exe), isNull);
    });

    test('rejects a root shared with other tools (foreign top-level dir)', () {
      final root = buildInstalledBundle('x');
      Directory(p.join(root.path, 'share')).createSync();
      final exe = p.join(root.path, 'bin', 'tina');
      expect(bundleRootForCurrentProcess(resolvedExecutable: exe), isNull);
    });

    test('ignores dotfiles when judging ownership', () {
      final root = buildInstalledBundle('x');
      File(p.join(root.path, '.DS_Store')).writeAsStringSync('');
      final exe = p.join(root.path, 'bin', 'tina');
      expect(bundleRootForCurrentProcess(resolvedExecutable: exe), root.path);
    });

    test('rejects non-tina binaries and missing files', () {
      final s = scratch!;
      File(p.join(s.path, 'bin', 'other')).createSync(recursive: true);
      expect(
        bundleRootForCurrentProcess(
          resolvedExecutable: p.join(s.path, 'bin', 'other'),
        ),
        isNull,
      );
      // Right name, but the file doesn't exist on disk.
      expect(
        bundleRootForCurrentProcess(
          resolvedExecutable: p.join(s.path, 'bin', 'tina'),
        ),
        isNull,
      );
    });

    test('dart-run process (VM as resolvedExecutable) has no bundle root', () {
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
        releaseFor('https://example.com/asset', checksumUrl: 'checksum'),
        client: _UrlClient({'checksum': fixture.checksum.readAsStringSync()}),
        notice: lines.add,
        bundleRootOverride: installed.path,
        workDirOverride: p.join(scratch!.path, 'work'),
        archiveSupplier: () async => fixture.archive,
      );

      expect(result, UpdateResult.success);
      expect(
        File(p.join(installed.path, 'bin', 'tina')).readAsStringSync(),
        'new-tina',
      );
      expect(
        Directory('${installed.path}.old').existsSync(),
        isTrue,
        reason: 'the old bundle is renamed aside for a later-launch sweep',
      );
      expect(
        File(p.join('${installed.path}.old', 'bin', 'tina')).readAsStringSync(),
        'old',
      );
      expect(
        File(p.join(installed.path, bundleMarkerName)).existsSync(),
        isTrue,
        reason: 'the installed root carries the ownership marker',
      );
      expect(lines.any((l) => l.contains('restart')), isTrue);
    }, skip: !hasTar);

    test('verifies a matching sha256 and proceeds', () async {
      final installed = buildInstalledBundle('old');
      final fixture = buildArchive('new-tina');
      final client = _UrlClient({
        'checksum': fixture.checksum.readAsStringSync(),
      });

      final result = await installRelease(
        releaseFor('https://example.com/asset', checksumUrl: 'checksum'),
        notice: (_) {},
        client: client,
        bundleRootOverride: installed.path,
        workDirOverride: p.join(scratch!.path, 'work'),
        archiveSupplier: () async => fixture.archive,
      );

      expect(result, UpdateResult.success);
      expect(
        File(p.join(installed.path, 'bin', 'tina')).readAsStringSync(),
        'new-tina',
      );
    }, skip: !hasTar);

    test('a wrong sha256 fails without touching the install', () async {
      final installed = buildInstalledBundle('old');
      final fixture = buildArchive('new-tina');
      final bad = File(p.join(scratch!.path, 'bad.sha256'))
        ..writeAsStringSync('${'0' * 64}  archive.tar.gz');
      final client = _UrlClient({'checksum': bad.readAsStringSync()});

      final result = await installRelease(
        releaseFor('https://example.com/asset', checksumUrl: 'checksum'),
        notice: (_) {},
        client: client,
        bundleRootOverride: installed.path,
        workDirOverride: p.join(scratch!.path, 'work'),
        archiveSupplier: () async => fixture.archive,
      );

      expect(result, UpdateResult.failed);
      expect(
        File(p.join(installed.path, 'bin', 'tina')).readAsStringSync(),
        'old',
      );
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
      final result = await installRelease(
        release,
        notice: (_) {},
        bundleRootOverride: '/tmp/whatever',
        workDirOverride: p.join(scratch!.path, 'work'),
      );
      expect(result, UpdateResult.unsupported);
    });

    test('no bundle root (running from source) needs manual update', () async {
      final fixture = buildArchive('new-tina');
      final result = await installRelease(
        releaseFor('https://example.com/asset', checksumUrl: 'checksum'),
        client: _UrlClient({'checksum': fixture.checksum.readAsStringSync()}),
        notice: (_) {},
        // No override: under `dart test` there is no bundle install.
        workDirOverride: p.join(scratch!.path, 'work'),
        archiveSupplier: () async => fixture.archive,
      );
      expect(result, UpdateResult.manualRequired);
    }, skip: !hasTar);

    test('refuses to swap a root that is not exclusively tina\'s', () async {
      final installed = buildInstalledBundle('old', marked: false);
      Directory(
        p.join(installed.path, 'share', 'signal-cli'),
      ).createSync(recursive: true);
      File(
        p.join(installed.path, 'share', 'signal-cli', 'account.db'),
      ).writeAsStringSync('store');
      final fixture = buildArchive('new-tina');
      final lines = <String>[];

      final result = await installRelease(
        releaseFor('https://example.com/asset', checksumUrl: 'checksum'),
        client: _UrlClient({'checksum': fixture.checksum.readAsStringSync()}),
        notice: lines.add,
        bundleRootOverride: installed.path,
        workDirOverride: p.join(scratch!.path, 'work'),
        archiveSupplier: () async => fixture.archive,
      );

      expect(result, UpdateResult.manualRequired);
      expect(lines.join(), contains('install.sh'));
      expect(
        File(p.join(installed.path, 'bin', 'tina')).readAsStringSync(),
        'old',
      );
      expect(
        Directory('${installed.path}.old').existsSync(),
        isFalse,
        reason: 'an unowned root must never be renamed aside',
      );
    }, skip: !hasTar);

    test('refuses to delete a foreign <root>.old', () async {
      final installed = buildInstalledBundle('old');
      // Something else's backup directory, sitting where the swap would
      // want to sweep it.
      final foreign = Directory('${installed.path}.old')..createSync();
      File(p.join(foreign.path, 'keep.txt')).writeAsStringSync('not tina\'s');
      final fixture = buildArchive('new-tina');
      final lines = <String>[];

      final result = await installRelease(
        releaseFor('https://example.com/asset', checksumUrl: 'checksum'),
        client: _UrlClient({'checksum': fixture.checksum.readAsStringSync()}),
        notice: lines.add,
        bundleRootOverride: installed.path,
        workDirOverride: p.join(scratch!.path, 'work'),
        archiveSupplier: () async => fixture.archive,
      );

      expect(result, UpdateResult.failed);
      expect(lines.join(), contains('refusing to delete'));
      expect(
        foreign.existsSync(),
        isTrue,
        reason: 'a foreign .old is never ours to delete',
      );
      expect(
        File(p.join(installed.path, 'bin', 'tina')).readAsStringSync(),
        'old',
        reason: 'the swap aborted before touching the install',
      );
    }, skip: !hasTar);

    test(
      'a non-bundle archive (no bundle/bin/tina) fails and rolls back',
      () async {
        final installed = buildInstalledBundle('old');
        final s = scratch!;
        final src = Directory(p.join(s.path, 'badsrc'))
          ..createSync(recursive: true);
        File(p.join(src.path, 'readme.txt')).writeAsStringSync('not a bundle');
        final archive = File(p.join(s.path, 'bad.tar.gz'));
        expect(
          Process.runSync('tar', [
            'czf',
            archive.path,
            '-C',
            src.path,
            'readme.txt',
          ]).exitCode,
          0,
        );

        final result = await installRelease(
          releaseFor('https://example.com/asset', checksumUrl: 'checksum'),
          client: _UrlClient({
            'checksum': (Process.runSync('shasum', ['-a', '256', archive.path])
                .stdout as String)
          }),
          notice: (_) {},
          bundleRootOverride: installed.path,
          workDirOverride: p.join(s.path, 'work'),
          archiveSupplier: () async => archive,
        );

        expect(result, UpdateResult.failed);
        expect(
          File(p.join(installed.path, 'bin', 'tina')).readAsStringSync(),
          'old',
        );
        expect(
          Directory('${installed.path}.old').existsSync(),
          isFalse,
          reason: 'the swap must roll back on a bad archive',
        );
      },
      skip: !hasTar,
    );
  });

  for (final missing in [true, false]) {
    test(
        'refuses ${missing ? "missing" : "unreachable"} checksum and removes scratch',
        () async {
      final installed = buildInstalledBundle('old');
      final fixture = buildArchive('new');
      final work = p.join(scratch!.path, 'work');
      final result = await prepareUpdate(
          releaseFor('asset', checksumUrl: missing ? null : 'checksum'),
          client: _UrlClient({}),
          notice: (_) {},
          bundleRootOverride: installed.path,
          workDirOverride: work,
          archiveSupplier: () async => fixture.archive);
      expect(result, isA<UpdatePrepareFailure>());
      expect(Directory(work).existsSync(), false);
      expect(File(p.join(installed.path, 'bin', 'tina')).readAsStringSync(),
          'old');
    });
  }
  test('verified archive containing a symlink is rejected before extraction',
      () async {
    final installed = buildInstalledBundle('old');
    final outside = File(p.join(scratch!.path, 'outside'))
      ..writeAsStringSync('keep');
    final fixture = buildArchive('new', alter: (bundle) {
      Link(p.join(bundle.path, '.escape')).createSync(outside.path);
    });
    final lines = <String>[];
    final result = await prepareUpdate(
        releaseFor('asset', checksumUrl: 'checksum'),
        client: _UrlClient({'checksum': fixture.checksum.readAsStringSync()}),
        notice: lines.add,
        bundleRootOverride: installed.path,
        workDirOverride: p.join(scratch!.path, 'work'),
        archiveSupplier: () async => fixture.archive);
    expect(result, isA<UpdatePrepareFailure>());
    expect(lines.join(), contains('unsafe path or entry type'));
    expect(outside.readAsStringSync(), 'keep');
  });
  for (final decision in [ApprovalDecision.allow, ApprovalDecision.deny]) {
    test('update plugin prepares before approval and cleans up after $decision',
        () async {
      final installed = buildInstalledBundle('old');
      final fixture = buildArchive('new');
      final work = p.join(scratch!.path, 'work');
      final terminal = _Terminal();
      var asked = false;
      final release = releaseFor('asset', checksumUrl: 'checksum');
      final plugin = UpdatePlugin(
          currentVersion: '1.0.0',
          terminal: terminal,
          checker: _Checker(release),
          prepare: (release, notice) => prepareUpdate(release,
              client:
                  _UrlClient({'checksum': fixture.checksum.readAsStringSync()}),
              notice: notice,
              bundleRootOverride: installed.path,
              workDirOverride: work,
              archiveSupplier: () async => fixture.archive),
          approvals: _Approvals((operation, target) {
            asked = true;
            expect(operation, 'install update');
            expect(target, installed.path);
            expect(
                File(p.join(work, 'x', 'bundle', 'bin', 'tina'))
                    .readAsStringSync(),
                'new');
            expect(
                File(p.join(installed.path, 'bin', 'tina')).readAsStringSync(),
                'old');
            return decision;
          }));
      addTearDown(plugin.closeSession);
      await plugin.commands.single.handler('check');
      expect(asked, false);
      expect(Directory(work).existsSync(), false);
      await plugin.commands.single.handler('install');
      expect(asked, true);
      expect(Directory(work).existsSync(), false);
      expect(File(p.join(installed.path, 'bin', 'tina')).readAsStringSync(),
          decision == ApprovalDecision.allow ? 'new' : 'old');
    });
  }
  test('cleanupStaleOldBundle removes the .old sibling', () {
    final installed = buildInstalledBundle('old');
    // What a previous tina update leaves: a marked bundle, renamed aside.
    Directory(
      p.join('${installed.path}.old', 'bin'),
    ).createSync(recursive: true);
    File(p.join('${installed.path}.old', 'bin', 'tina')).writeAsStringSync('x');
    File(
      p.join('${installed.path}.old', bundleMarkerName),
    ).writeAsStringSync('tina bundle root\n');

    cleanupStaleOldBundle(bundleRootOverride: installed.path);
    expect(Directory('${installed.path}.old').existsSync(), isFalse);
    expect(installed.existsSync(), isTrue);
  });

  test('cleanupStaleOldBundle leaves a .old that is not a tina bundle', () {
    final installed = buildInstalledBundle('old');
    final foreign = Directory('${installed.path}.old')..createSync();
    File(p.join(foreign.path, 'keep.txt')).writeAsStringSync('not tina\'s');

    cleanupStaleOldBundle(bundleRootOverride: installed.path);
    expect(foreign.existsSync(), isTrue);
  });

  test('cleanupStaleOldBundle leaves .old of an unowned root', () {
    final installed = buildInstalledBundle('old', marked: false);
    Directory(p.join(installed.path, 'share')).createSync();
    final old = Directory('${installed.path}.old')..createSync();

    cleanupStaleOldBundle(bundleRootOverride: installed.path);
    expect(
      old.existsSync(),
      isTrue,
      reason: 'an unowned root is never swept, whatever sits beside it',
    );
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

class _Terminal implements Terminal {
  final lines = <String>[];
  @override
  void writeln([String? line]) => lines.add(line ?? '');
  @override
  Future<String> ask(String prompt) =>
      throw StateError('normal input is not an approval channel');
}

class _Approvals implements ApprovalRequester {
  _Approvals(this.answer);
  final ApprovalDecision Function(String, String) answer;
  @override
  Future<ApprovalDecision> request(
          {required String operation,
          required String target,
          required String reason,
          ApprovalKind kind = ApprovalKind.permission}) async =>
      answer(operation, target);
}

class _Checker extends ReleaseChecker {
  _Checker(this.release) : super(env: const {});
  final ReleaseInfo release;
  @override
  Future<ReleaseInfo?> fetchLatest() async => release;
}
