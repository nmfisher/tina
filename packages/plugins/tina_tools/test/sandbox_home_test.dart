import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

void main() {
  late Directory root, host, workspace, state;
  setUp(() {
    root = Directory(Directory.systemTemp
        .createTempSync('tina-home-test-')
        .resolveSymbolicLinksSync());
    host = Directory('${root.path}/host')..createSync();
    workspace = Directory('${root.path}/work')..createSync();
    state = Directory('${root.path}/state')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('temp environment and layout use the same validated parent value', () {
    final env = {
      'TMPDIR': root.path,
      'HOME': host.path,
      'PROVIDER_KEY': 'secret'
    };
    final plan =
        SandboxPlan(workspaceRoot: workspace.path, parentEnvironment: env);
    expect(plan.childEnvironment['TMPDIR'], root.path);
    expect(plan.writableLayout(), contains(root.path));
    expect(plan.childEnvironment, isNot(contains('PROVIDER_KEY')));
    for (final value in ['', 'relative', '${root.path}/missing']) {
      expect(sandboxTempDirectory({'TMPDIR': value}), '/tmp');
    }
    expect(defaultSandboxTempDirs({}), ['/tmp', '/var/tmp']);
  });

  test(
      'home exposes selected caches, creates local fallbacks and cleans links safely',
      () {
    final cache = Directory('${host.path}/.cargo/registry')
      ..createSync(recursive: true);
    final data = File('${cache.path}/package')..writeAsStringSync('cached');
    File('${host.path}/.cargo/credentials.toml')
        .writeAsStringSync('fixture secret');
    final home = SandboxHome(
        realHome: host.path,
        stateRoot: state.path,
        caches: ['.cargo/registry', '.npm/_cacache']);
    final first = home.ensure();
    expect(Link('$first/.cargo/registry').targetSync(), cache.path);
    expect(File('$first/.cargo/credentials.toml').existsSync(), false);
    expect(Directory('$first/.npm/_cacache').existsSync(), true);
    expect(Link('$first/.npm/_cacache').existsSync(), false);
    home.replace(['.npm/_cacache']);
    final second = home.ensure();
    expect(second, isNot(first));
    expect(Directory(first).existsSync(), true,
        reason: 'running commands retain the generation');
    expect(Directory('$second/.cargo').existsSync(), false);
    home.close();
    expect(Directory(first).existsSync(), false);
    expect(Directory(second).existsSync(), false);
    expect(data.readAsStringSync(), 'cached');
  });

  test(
      'invalid and overlapping cache entries and credential aliases fail closed',
      () {
    for (final paths in [
      ['../escape'],
      ['/absolute'],
      ['.'],
      ['.pub-cache', '.pub-cache'],
      ['.cargo', '.cargo/registry']
    ]) {
      expect(() => validateHomeCaches(paths), throwsFormatException);
    }
    Directory('${host.path}/.ssh').createSync();
    Link('${host.path}/innocent-cache').createSync('${host.path}/.ssh');
    final home = SandboxHome(
        realHome: host.path, stateRoot: state.path, caches: ['innocent-cache']);
    addTearDown(home.close);
    expect(home.ensure, throwsA(isA<FileSystemException>()));
  });

  test('protected paths stay denied beneath broad grants and through aliases',
      () {
    final key = File('${host.path}/.ssh/key')
      ..parent.createSync(recursive: true);
    key.writeAsStringSync('fixture secret');
    Link('${workspace.path}/key-alias').createSync(key.path);
    final ordinary = Directory('${host.path}/ordinary')..createSync();
    final plan = SandboxPlan(
        workspaceRoot: workspace.path,
        realHome: host.path,
        writablePaths: [host.path]);
    for (final linux in [false, true]) {
      expect(plan.canWrite('${ordinary.path}/new-file', linux: linux), true);
      expect(plan.canWrite(key.path, linux: linux), false);
    }
    expect(plan.canGrant('${workspace.path}/key-alias'), false);
  });

  test(
      'approved host execution restores HOME and ssh agent but filters provider variables',
      () async {
    final recorder = _Recorder();
    final plan = SandboxPlan(workspaceRoot: workspace.path, parentEnvironment: {
      'HOME': host.path,
      'TMPDIR': root.path,
      'PATH': '/usr/bin:/bin',
      'SSH_AUTH_SOCK': '/fixture/socket',
      'ANTHROPIC_API_KEY': 'fixture-secret',
    });
    final runner = OsSandboxRunner(
        inner: recorder, plan: plan, backend: SandboxBackend.sandboxExec);
    final request = _request('/usr/bin/env', [], workspace.path);
    await runner.run(request,
        control: const ProcessControl(
            outsideSandboxRequested: true,
            outsideSandboxAllowed: true,
            networkAllowed: true));
    final env = recorder.calls.single.environment!;
    expect(env['HOME'], host.path);
    expect(env['TMPDIR'], root.path);
    expect(env['SSH_AUTH_SOCK'], '/fixture/socket');
    expect(env.containsKey('ANTHROPIC_API_KEY'), false);
  });

  test(
      'live backend reads cache but cannot read config or credentials via aliases',
      () async {
    final backend = resolveSandboxBackend();
    if (backend == SandboxBackend.passThrough) {
      markTestSkipped('requires an OS sandbox');
      return;
    }
    final cache = Directory('${host.path}/.pub-cache')..createSync();
    File('${cache.path}/cached').writeAsStringSync('cache works');
    final secret = File('${cache.path}/credentials.json')
      ..writeAsStringSync('fixture-secret');
    final config = File('${workspace.path}/custom-config')
      ..writeAsStringSync('config-secret');
    Link('${workspace.path}/credential-alias').createSync(secret.path);
    final home = SandboxHome(
        realHome: host.path, stateRoot: state.path, caches: ['.pub-cache']);
    addTearDown(home.close);
    final plan = SandboxPlan(
        workspaceRoot: workspace.path,
        home: home,
        realHome: host.path,
        protectedPaths: [config.path],
        writablePaths: [host.path]);
    final runner = OsSandboxRunner(inner: const IoProcessRunner(), plan: plan);
    final result = await runner.run(_request(
        '/bin/cat', ['${home.ensure()}/.pub-cache/cached'], workspace.path));
    expect(result, isA<CommandCompleted>());
    expect((result as CommandCompleted).stdout, 'cache works',
        reason: result.stderr);
    for (final filename in [
      secret.path,
      config.path,
      '${workspace.path}/credential-alias',
      '${home.ensure()}/.pub-cache/credentials.json'
    ]) {
      final result =
          await runner.run(_request('/bin/cat', [filename], workspace.path));
      if (result is CommandCompleted) {
        expect(result.stdout, isNot(contains('secret')),
            reason: '$filename: ${result.stderr}');
      } else {
        expect(result, isA<CommandBlocked>());
      }
      final write = await runner.run(_request(
          '/bin/sh',
          ['-c', r'printf overwritten > "$1"', 'sh', filename],
          workspace.path));
      expect(
          write is CommandBlocked ||
              write is CommandCompleted && write.exitCode != 0,
          true);
    }
    expect(secret.readAsStringSync(), 'fixture-secret');
    expect(config.readAsStringSync(), 'config-secret');
  }, tags: 'live-os-sandbox');

  test('prompt requests host credentials proactively and explains all scopes',
      () {
    final prompt = HostPromptSection(workspace.path, () => PermissionMode.ask)
        .sectionFor(PermissionMode.ask);
    expect(prompt, contains('Do not first attempt'));
    expect(prompt, contains('git push over SSH'));
    expect(prompt, contains('session, workspace or globally'));
  });

  test(
      'Linux masks secrets through bind aliases and never creates host placeholders',
      () {
    final cache = Directory('${host.path}/cache')..createSync();
    final existing = File('${cache.path}/token')
      ..writeAsStringSync('fixture-secret');
    final missing = '${cache.path}/missing-token';
    final alias = Link('${root.path}/cache-alias')..createSync(cache.path);
    final before = cache.listSync().map((e) => e.path).toList();
    final args = buildBwrapArguments(
      host:
          SandboxHostLayout(readOnlyDirectories: [], temporaryDirectories: []),
      workspaceRoot: workspace.path,
      writablePaths: [alias.path],
      deniedPaths: [existing.path, missing],
      isolateNetwork: true,
      childEnvironment: const {},
    );
    expect(
        args.join('\n'), contains('--ro-bind\n/dev/null\n${alias.path}/token'));
    expect(
        args.join('\n'), contains('--ro-bind\n${alias.path}\n${alias.path}'));
    expect(cache.listSync().map((e) => e.path).toList(), before);
    expect(existing.readAsStringSync(), 'fixture-secret');
    final plan = SandboxPlan(
        workspaceRoot: workspace.path,
        realHome: host.path,
        writablePaths: [cache.path],
        protectedPaths: [missing]);
    expect(plan.canWrite('${cache.path}/new-file', linux: true), false);
    final safe = Directory('${cache.path}/packages')..createSync();
    expect(plan.canWrite('${safe.path}/new-file', linux: true), true);
  });

  test('replaced read-grant targets cannot redirect a persistent mount', () {
    final granted = Directory('${root.path}/granted')..createSync();
    final reads = ReadOnlyDirectories()..replace([granted.path]);
    granted.deleteSync();
    Link(granted.path).createSync(host.path);
    expect(reads.existingPaths, isEmpty);
  });

  test('live home hides unlisted host files and neighboring session state',
      () async {
    if (resolveSandboxBackend() == SandboxBackend.passThrough) {
      markTestSkipped('requires an OS sandbox');
      return;
    }
    // Deliberately outside shared host temp roots: a temp fixture would be
    // reachable under the separately accepted temp-directory grant.
    final fixture = Directory(Directory.current
        .createTempSync('.tina-home-live-')
        .resolveSymbolicLinksSync());
    addTearDown(() => fixture.deleteSync(recursive: true));
    final real = Directory('${fixture.path}/host')..createSync();
    final work = Directory('${fixture.path}/workspace')..createSync();
    final private = File('${real.path}/private-note')
      ..writeAsStringSync('private-fixture');
    final cache = Directory('${real.path}/.pub-cache/hosted')
      ..createSync(recursive: true);
    File('${cache.path}/cached').writeAsStringSync('cached-fixture');
    File('${real.path}/.pub-cache/credentials.json')
        .writeAsStringSync('credential-fixture');
    final home = SandboxHome(
        realHome: real.path,
        stateRoot: '${real.path}/.tina/sandbox-homes',
        caches: ['.pub-cache']);
    final childHome = home.ensure();
    addTearDown(home.close);
    File('${home.stateRoot}/neighbor').writeAsStringSync('neighbor-fixture');
    final runner = OsSandboxRunner(
        inner: const IoProcessRunner(),
        plan: SandboxPlan(
            workspaceRoot: work.path, realHome: real.path, home: home));
    for (final denied in [
      private.path,
      '$childHome/../neighbor',
      '$childHome/.pub-cache/credentials.json',
    ]) {
      final result =
          await runner.run(_request('/bin/cat', [denied], work.path));
      if (result is CommandCompleted) {
        expect(result.stdout, isNot(contains('fixture')),
            reason: 'Linux masks files with empty read-only content');
      } else {
        expect(result, isA<CommandBlocked>());
      }
    }
    final shared = await runner.run(_request(
        '/bin/sh',
        [
          '-c',
          r'cat "$HOME/.pub-cache/hosted/cached"; printf updated > "$HOME/.pub-cache/hosted/written"',
        ],
        work.path)) as CommandCompleted;
    expect(shared.exitCode, 0, reason: shared.stderr);
    expect(shared.stdout, 'cached-fixture');
    expect(File('${cache.path}/written').readAsStringSync(), 'updated');
    final local = await runner.run(_request('/bin/sh',
        ['-c', r'printf local > "$HOME/note"; cat "$HOME/note"'], work.path));
    expect(local, isA<CommandCompleted>());
    expect((local as CommandCompleted).stdout, 'local', reason: local.stderr);
  }, tags: 'live-os-sandbox');
}

ProcessRequest _request(String command, List<String> arguments, String cwd) => (
      command: command,
      arguments: arguments,
      workingDirectory: cwd,
      environment: null,
      stdin: null,
      timeout: const Duration(seconds: 10)
    );

class _Recorder implements ProcessRunner {
  final calls = <ProcessRequest>[];
  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    calls.add(request);
    return const CommandCompleted(exitCode: 0, stdout: '', stderr: '');
  }
}
