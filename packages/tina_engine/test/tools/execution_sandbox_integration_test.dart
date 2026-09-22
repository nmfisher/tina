import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

void main() {
  test('macOS profile preserves explicit network and write policy', () {
    final profile = buildMacSandboxProfile(
        writablePaths: ['/tmp', '/project'],
        root: '/project',
        readOnlyProject: false,
        isolateNetwork: true);
    expect(profile, contains('(deny network*)'));
    expect(profile, contains('(deny file-write*)'));
    expect(profile, contains('(allow file-write* (subpath "/project"))'));
  });
  test('resolver layout exposes only the resolved file, not all of /run', () {
    final args = buildLinuxSandboxArguments(
      host: SandboxHostLayout(
          readOnlyDirectories: ['/usr', '/etc'],
          temporaryDirectories: ['/tmp'],
          resolverTarget: '/run/systemd/resolve/stub-resolv.conf'),
      workspaceRoot: '/project',
      writablePaths: [],
      readOnlyProject: false,
      isolateNetwork: false,
    );
    expect(
        args,
        containsAllInOrder([
          '--ro-bind',
          '/run/systemd/resolve/stub-resolv.conf',
          '/run/systemd/resolve/stub-resolv.conf'
        ]));
    expect(args, isNot(contains('/run')));
    expect(args, isNot(contains('--unshare-net')));
  });

  final required = Platform.environment['TINA_REQUIRE_SANDBOX_TESTS'] == '1';
  final available = Platform.isLinux && bwrapAvailable;
  test(
      'real namespace preserves a resolver symlink into /run and confines writes',
      () async {
    expect(available, true,
        reason: 'CI requires bubblewrap with user namespaces');
    final temp = Directory.systemTemp.createTempSync('tina-resolver-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final etc = Directory('${temp.path}/etc')..createSync();
    final resolver = File('${temp.path}/resolver')
      ..writeAsStringSync('nameserver 127.0.0.53\n');
    Link('${etc.path}/resolv.conf')
        .createSync('/run/tina-resolver/resolv.conf');
    // A deterministic Fedora-style symlink, even on CI hosts with a regular
    // resolv.conf. No external network dependency or host configuration edits.
    final args = buildLinuxSandboxArguments(
      host: SandboxHostLayout(
          readOnlyDirectories: ['/usr', '/bin', '/lib', '/lib64']
              .where((d) => Directory(d).existsSync()),
          temporaryDirectories: [],
          resolverTarget: null),
      workspaceRoot: null,
      writablePaths: [],
      readOnlyProject: false,
      isolateNetwork: false,
    )..removeLast();
    args.addAll([
      '--ro-bind',
      etc.path,
      '/etc',
      '--ro-bind',
      resolver.path,
      '/run/tina-resolver/resolv.conf',
      '--',
      '/bin/sh',
      '-c',
      'cat /etc/resolv.conf && ! test -e /run/systemd && ! test -w /etc/resolv.conf'
    ]);
    final result = await const IoProcessRunner().run('bwrap', args);
    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.stdout, 'nameserver 127.0.0.53\n');

    // Also exercise the production host inspector and runner on this host.
    final hostResolver = File('/etc/resolv.conf');
    if (hostResolver.existsSync()) {
      final actual = await SandboxedProcessRunner(workspaceRoot: temp.path)
          .run('/bin/cat', ['/etc/resolv.conf']);
      expect(actual.exitCode, 0, reason: actual.stderr);
      expect(actual.stdout, hostResolver.readAsStringSync());
    }
  }, skip: !available && !required ? 'Linux bubblewrap is unavailable' : false);
}
