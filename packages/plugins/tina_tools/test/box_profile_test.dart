// Profiles are data: each spec maps onto the bwrap argv the OS sandbox
// runner builds, and that mapping is checked both directly (the argv a
// profile produces) and against the live runner (the same argv
// OsSandboxRunner assembles for the profile's control flags).
//
// Run: dart test
library;

import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

/// Records what it was handed; always succeeds.
class RecordingRunner implements ConfinedProcessRunner {
  @override
  bool get confinesFilesystem => true;
  final requests = <ProcessRequest>[];

  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    requests.add(request);
    return const CommandCompleted(exitCode: 0, stdout: '', stderr: '');
  }
}

final _host = SandboxHostLayout(
  readOnlyDirectories: ['/usr/bin', '/usr/lib'],
  temporaryDirectories: ['/scratch/tmp'],
);

SandboxPlan _plan() => const SandboxPlan(
      workspaceRoot: '/workspace',
      writablePaths: ['/workspace/out'],
      isolateNetwork: true,
    );

List<String> _mounts(List<String> arguments) => [
      for (var index = 0; index + 2 < arguments.length; index++)
        if ({'--bind', '--ro-bind'}.contains(arguments[index]))
          '${arguments[index]}:${arguments[index + 1]}',
    ];

void main() {
  test('scripts and default bind the workspace read-only and isolate net',
      () {
    for (final profile in [boxProfileScripts, boxProfileDefault]) {
      final arguments = boxProfileBwrapArguments(
          plan: _plan(), profile: profile, host: _host);
      expect(arguments, contains('--unshare-net'), reason: profile.name);
      expect(_mounts(arguments),
          contains('--ro-bind:/workspace'), reason: profile.name);
      expect(_mounts(arguments), isNot(contains('--bind:/workspace')),
          reason: profile.name);
    }
  });

  test('build binds the workspace read-write, still offline', () {
    final arguments =
        boxProfileBwrapArguments(plan: _plan(), profile: boxProfileBuild, host: _host);
    expect(arguments, contains('--unshare-net'));
    expect(_mounts(arguments), contains('--bind:/workspace'));
    expect(_mounts(arguments), isNot(contains('--ro-bind:/workspace')));
    // Extra writable grants stay writable.
    expect(_mounts(arguments), contains('--bind:/workspace/out'));
  });

  test('packages is the only profile with network', () {
    final arguments = boxProfileBwrapArguments(
        plan: _plan(), profile: boxProfilePackages, host: _host);
    expect(arguments, isNot(contains('--unshare-net')));
    expect(_mounts(arguments), contains('--bind:/workspace'));
    for (final other in [boxProfileScripts, boxProfileBuild, boxProfileDefault]) {
      expect(
          boxProfileBwrapArguments(plan: _plan(), profile: other, host: _host),
          contains('--unshare-net'),
          reason: other.name);
    }
  });

  test('every profile keeps temp scratch writable', () {
    for (final profile in boxProfiles.values) {
      final arguments =
          boxProfileBwrapArguments(plan: _plan(), profile: profile, host: _host);
      expect(_mounts(arguments), contains('--bind:/scratch/tmp'),
          reason: profile.name);
    }
  });

  test('the mapping equals what OsSandboxRunner builds for the control',
      () async {
    for (final profile in boxProfiles.values) {
      final inner = RecordingRunner();
      final runner = OsSandboxRunner(
        inner: inner,
        plan: _plan(),
        enabled: true,
        backend: SandboxBackend.bwrap,
        hostLayout: () => _host,
      );
      await runner.run(
        (
          command: 'true',
          arguments: const [],
          workingDirectory: '/workspace',
          environment: null,
          stdin: null,
          timeout: null,
        ),
        control: ProcessControl(
          readOnly: profile.control.readOnly,
          networkAllowed: profile.control.networkAllowed,
        ),
      );
      final jailed = inner.requests.single.arguments;
      final mapped = boxProfileBwrapArguments(
          plan: _plan(), profile: profile, host: _host);
      // The jailed argv is [<bwrap args>, 'true'].
      expect(jailed.sublist(0, jailed.length - 1), mapped,
          reason: profile.name);
    }
  });

  test('profile specs are the four named containments', () {
    expect(boxProfiles.keys, {'scripts', 'build', 'packages', 'default'});
    expect(boxProfileByName('build'), boxProfileBuild);
    expect(boxProfileByName('nope'), isNull);
    expect(boxProfileScripts.control,
        (readOnly: true, networkAllowed: false));
    expect(boxProfileBuild.control, (readOnly: false, networkAllowed: false));
    expect(boxProfilePackages.control,
        (readOnly: false, networkAllowed: true));
  });
}
