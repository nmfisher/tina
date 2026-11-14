import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_tools/tina_tools.dart';

class _Recorder implements ConfinedProcessRunner {
  @override
  bool get confinesFilesystem => true;
  final requests = <ProcessRequest>[];
  final controls = <ProcessControl?>[];
  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    requests.add(request);
    controls.add(control);
    return const CommandCompleted(exitCode: 0, stdout: '', stderr: '');
  }
}

void main() {
  late Directory root, workspace, bin, home;
  late ToolsPlugin tools;
  late StreamApprovalChannel channel;
  late ApprovalsPlugin approvals;
  late ScopedSettings settings;
  final asks = <ApprovalRequest>[];
  var decision = ApprovalDecision.allowPrefixInSession;
  FutureOr<ApprovalDecision> Function(ApprovalRequest)? answer;

  ScopedSettings freshSettings() {
    final catalog = SettingCatalog();
    for (final definition in executionSettings) {
      catalog.register(definition);
    }
    return ScopedSettings(catalog: catalog, backend: MemorySettingsBackend());
  }

  ToolsPlugin create({String? project, ScopedSettings? configuration}) {
    final result = ToolsPlugin(
        workspaceRoot: project ?? workspace.path,
        tinaDir: Directory('${project ?? workspace.path}/.tina'),
        settings: configuration ?? freshSettings(),
        hostEnvironment: {
          'HOME': home.path,
          'PATH': '/usr/bin:/bin',
          'PRIVATE_TOKEN': 'must-not-leak'
        });
    result.modePolicy.approvals = approvals;
    addTearDown(result.closeSession);
    return result;
  }

  SandboxedProcessRunner runner(_Recorder recorder, [ToolsPlugin? owner]) {
    final selected = owner ?? tools;
    final gate = SandboxedProcessRunner(
        inner: recorder,
        workspaceRoot: workspace.path,
        plan: selected.osPlan,
        approvalStore: selected.commandApprovals,
        executableSearchPath: selected.osPlan.searchPath,
        commandApprover: selected.processRunner.commandApprover);
    gate.workspaceWriteGranted =
        () => selected.modePolicy.hasWorkspaceWriteGrant(workspace.path);
    gate.requestWorkspaceWrite =
        () => selected.modePolicy.ensureWorkspaceWrite(workspace.path);
    return gate;
  }

  ProcessRequest request(String name, List<String> args,
          {String? cwd, String? stdin}) =>
      (
        command: name.startsWith('/') ? name : '${bin.path}/$name',
        arguments: args,
        workingDirectory: cwd ?? workspace.path,
        environment: null,
        stdin: stdin,
        timeout: null,
      );
  CommandPrefixPlan plan(ProcessRequest value) => CommandPrefixPlan.parse(value,
      workspace: workspace.path, searchPath: '${bin.path}:/usr/bin:/bin')!;

  setUp(() {
    root = Directory(Directory.systemTemp
        .createTempSync('command-prefix-')
        .resolveSymbolicLinksSync());
    workspace = Directory('${root.path}/project')..createSync();
    bin = Directory('${root.path}/bin')..createSync();
    home = Directory('${root.path}/home')..createSync();
    for (final name in [
      'gh',
      'head',
      'grep',
      'otool',
      'sed',
      'enable',
      'node',
      'readonly'
    ]) {
      final file = File('${bin.path}/$name')
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      expect(Process.runSync('/bin/chmod', ['+x', file.path]).exitCode, 0);
    }
    asks.clear();
    answer = null;
    decision = ApprovalDecision.allowPrefixInSession;
    channel = StreamApprovalChannel();
    approvals = ApprovalsPlugin(channel: channel);
    final subscription = channel.requests.listen((ask) async {
      asks.add(ask);
      channel.respond(ask.id, answer == null ? decision : await answer!(ask));
    });
    addTearDown(() => root.deleteSync(recursive: true));
    addTearDown(channel.closeSession);
    addTearDown(approvals.closeSession);
    addTearDown(subscription.cancel);
    settings = freshSettings();
    tools = create(configuration: settings);
  });

  test(
      'exact Node grants cover only the same invocation and approved capabilities',
      () async {
    decision = ApprovalDecision.allowExactInSession;
    final recorder = _Recorder();
    final gate = runner(recorder);
    const control =
        ProcessControl(networkRequested: true, networkReason: 'Run QA');
    final command = request('node', ['scripts/.qa-diag2.cjs']);
    expect(await gate.run(command, control: control), isA<CommandCompleted>());
    expect(asks.single.details['exact_command_approval'], true);
    expect(asks.single.details['command_prefixes'], isNull);
    expect(tools.commandApprovals.entries.single['kind'], 'command_exact');
    decision = ApprovalDecision.deny;
    expect(await gate.run(command, control: control), isA<CommandCompleted>());
    expect(asks, hasLength(1));
    final sub = Directory('${workspace.path}/sub')..createSync();
    for (final changed in [
      request('node', ['scripts/.qa-diag3.cjs']),
      request('node', ['scripts/.qa-diag2.cjs', '--extra']),
      request('node', ['scripts/.qa-diag2.cjs'], cwd: sub.path),
      request('node', ['scripts/.qa-diag2.cjs'], stdin: 'new stdin'),
    ]) {
      expect(await gate.run(changed, control: control), isA<CommandRefused>());
    }
    final extraRead = Directory('${root.path}/outside')..createSync();
    expect(
        await gate.run(command,
            control: ProcessControl(readDirectories: [extraRead.path])),
        isA<CommandRefused>());
    expect(
        await gate.run(command,
            control: const ProcessControl(outsideSandboxRequested: true)),
        isA<CommandRefused>());
    settings.set(
        commandEnvironmentSetting, {'BUILD_MODE': 'new'}, SettingScope.session);
    expect(await gate.run(command, control: control), isA<CommandRefused>());
    expect(recorder.requests, hasLength(2));
  });

  test(
      'exact shell grants compare the entire script without parsing or prefixes',
      () async {
    decision = ApprovalDecision.allowExactInSession;
    final gate = runner(_Recorder());
    ProcessRequest script(String body) => request('/bin/sh', ['-c', body]);
    expect(await gate.run(script(r'X=1; echo "$X"')), isA<CommandCompleted>());
    decision = ApprovalDecision.deny;
    expect(await gate.run(script(r'X=1; echo "$X"')), isA<CommandCompleted>());
    expect(await gate.run(script(r'X=2; echo "$X"')), isA<CommandRefused>());
    expect(asks, hasLength(2));
  });

  for (final scope in [
    ApprovalDecision.allowExactInSession,
    ApprovalDecision.allowExactInWorkspace
  ]) {
    test('exact $scope grants survive resume/storage and remain revocable',
        () async {
      decision = scope;
      final loop = AgentLoop(provider: ScriptedProvider([]), plugins: [tools]);
      loop.mountPlugin(tools);
      final command = request('node', ['scripts/.qa-diag2.cjs']);
      expect(await runner(_Recorder()).run(command), isA<CommandCompleted>());
      final fresh = create();
      if (scope == ApprovalDecision.allowExactInSession) {
        final restored = AgentLoop(
            provider: ScriptedProvider([]),
            plugins: [fresh],
            seedLog: loop.log);
        restored.mountPlugin(fresh);
        final unrelated = create();
        decision = ApprovalDecision.deny;
        expect(await runner(_Recorder(), unrelated).run(command),
            isA<CommandRefused>());
      }
      decision = ApprovalDecision.deny;
      expect(await runner(_Recorder(), fresh).run(command),
          isA<CommandCompleted>());
      fresh.commandApprovals
          .revoke(fresh.commandApprovals.entries.single['id'] as String);
      expect(
          await runner(_Recorder(), fresh).run(command), isA<CommandRefused>());
    });
  }

  test('exact grants are revalidated after a pending approval', () async {
    final alias = Link('${bin.path}/node-alias')
      ..createSync('${bin.path}/node');
    final entered = Completer<void>();
    final release = Completer<ApprovalDecision>();
    answer = (_) {
      entered.complete();
      return release.future;
    };
    final recorder = _Recorder();
    final pending = runner(recorder).run(request(alias.path, ['script.cjs']));
    await entered.future;
    alias.deleteSync();
    alias.createSync('${bin.path}/head');
    release.complete(ApprovalDecision.allowExactInWorkspace);
    expect(await pending, isA<CommandRefused>());
    expect(tools.commandApprovals.entries, isEmpty);
    expect(recorder.requests, isEmpty);
  });

  test(
      'revoking an exact grant during a new access approval prevents execution',
      () async {
    decision = ApprovalDecision.allowExactInSession;
    final recorder = _Recorder();
    final gate = runner(recorder);
    final command = request('node', ['script.cjs']);
    expect(await gate.run(command), isA<CommandCompleted>());
    final entered = Completer<void>();
    final release = Completer<ApprovalDecision>();
    answer = (_) {
      entered.complete();
      return release.future;
    };
    final pending = gate.run(command,
        control: const ProcessControl(
            networkRequested: true, networkReason: 'New access'));
    await entered.future;
    tools.commandApprovals
        .revoke(tools.commandApprovals.entries.single['id'] as String);
    release.complete(ApprovalDecision.allow);
    expect(await pending, isA<CommandRefused>());
    expect(recorder.requests, hasLength(1));
  });

  test('cancelled exact answers do not save session or workspace grants',
      () async {
    final entered = Completer<void>();
    final release = Completer<ApprovalDecision>();
    answer = (_) {
      entered.complete();
      return release.future;
    };
    final cancel = Completer<void>();
    var cancelled = false;
    final recorder = _Recorder();
    final pending = runner(recorder).run(request('node', ['script.cjs']),
        control: ProcessControl(
            isCancelled: () => cancelled, whenCancelled: cancel.future));
    await entered.future;
    cancelled = true;
    cancel.complete();
    expect(await pending, isA<CommandRefused>());
    release.complete(ApprovalDecision.allowExactInWorkspace);
    await Future<void>.delayed(Duration.zero);
    expect(tools.commandApprovals.entries, isEmpty);
    expect(recorder.requests, isEmpty);
  });

  test('gh pr view matches argv tokens; other subcommands and contexts do not',
      () {
    final initial = plan(request('gh', ['pr', 'view', '429']));
    expect(initial.labels, ['gh pr view']);
    tools.commandApprovals.rememberPrefixes(
        initial, {'execute', 'network'}, CommandApprovalScope.session);
    expect(
        tools.commandApprovals.coversPrefixes(
            plan(request('gh', ['pr', 'view', '430'])), 'network'),
        true);
    for (final args in [
      ['pr', 'viewevil'],
      ['pr', 'checkout', '429'],
      ['pr', 'view 429']
    ]) {
      expect(
          tools.commandApprovals
              .coversPrefixes(plan(request('gh', args)), 'execute'),
          false);
    }
    expect(
        tools.commandApprovals.coversPrefixes(
            plan(request('gh', ['pr', 'view'], cwd: home.path)), 'execute'),
        false);
    expect(
        tools.commandApprovals.coversPrefixes(
            plan(request('gh', ['pr', 'view'], stdin: 'other input')),
            'execute'),
        false);
    expect(tools.commandApprovals.coversPrefixes(initial, 'host'), false);
    expect(tools.commandApprovals.coversPrefixes(initial, 'read'), false);
    expect(tools.commandApprovals.coversPrefixes(initial, 'write'), false);
    expect(tools.commandApprovals.coversPrefixes(initial, 'delete'), false);
  });

  test('one human prefix answer handles future arguments without new approvals',
      () async {
    final recorder = _Recorder();
    final gate = runner(recorder);
    const control =
        ProcessControl(networkRequested: true, networkReason: 'Inspect PR');
    expect(
        await gate.run(request('gh', ['pr', 'view', '429']), control: control),
        isA<CommandCompleted>());
    expect(asks.single.details['command_prefixes'], ['gh pr view']);
    expect(
        await gate.run(request('gh', ['pr', 'view', '430']), control: control),
        isA<CommandCompleted>());
    expect(asks, hasLength(1));
    expect(recorder.requests, hasLength(2));
    expect(recorder.controls.last!.networkAllowed, true);
    expect(recorder.controls.last!.workspaceWriteAllowed, false);
    decision = ApprovalDecision.deny;
    expect(
        await gate.run(request('gh', ['pr', 'checkout', '429']),
            control: control),
        isA<CommandRefused>());
    expect(recorder.requests, hasLength(2));
  });

  test('new network and filesystem access require independent approvals',
      () async {
    final recorder = _Recorder();
    final gate = runner(recorder);
    expect(await gate.run(request('gh', ['pr', 'view', '429'])),
        isA<CommandCompleted>());
    expect(await gate.run(request('gh', ['pr', 'view', '430'])),
        isA<CommandCompleted>());
    expect(asks, hasLength(1));
    decision = ApprovalDecision.deny;
    expect(
        await gate.run(request('gh', ['pr', 'view', '430']),
            control: const ProcessControl(
                networkRequested: true, networkReason: 'New network access')),
        isA<CommandRefused>());
    final outside = Directory('${root.path}/data')..createSync();
    expect(
        await gate.run(request('gh', ['pr', 'view', '430']),
            control: ProcessControl(readDirectories: [outside.path])),
        isA<CommandRefused>());
    expect(asks, hasLength(3));
    expect(recorder.requests, hasLength(2));
  });

  test('head does not approve earlier pipeline stages; every stage must match',
      () async {
    final recorder = _Recorder();
    final gate = runner(recorder);
    ProcessRequest shell(String script) => request('/bin/sh', ['-c', script]);
    expect(await gate.run(shell('${bin.path}/head -n 35')),
        isA<CommandCompleted>());
    final script =
        '${bin.path}/otool -tvV library.a | ${bin.path}/grep -A 30 "symbol with spaces" | ${bin.path}/head -n 35';
    decision = ApprovalDecision.deny;
    expect(await gate.run(shell(script)), isA<CommandRefused>());
    expect(asks.last.details['command_prefixes'], ['otool', 'grep', 'head']);
    expect(recorder.requests, hasLength(1));
    decision = ApprovalDecision.allowPrefixInSession;
    expect(await gate.run(shell(script)), isA<CommandCompleted>());
    expect(await gate.run(shell(script.replaceFirst('-n 35', '-n 40'))),
        isA<CommandCompleted>());
    expect(asks, hasLength(3));
    decision = ApprovalDecision.deny;
    expect(await gate.run(shell(script.replaceFirst('/grep', '/sed'))),
        isA<CommandRefused>());
    expect(recorder.requests, hasLength(3));
  });

  test(
      'shell expansion, state changes and file redirects cannot acquire prefix grants',
      () {
    for (final script in [
      r'X=1; gh pr view 429',
      r'gh pr view $(cat file)',
      r'gh pr view 429 > result',
      r'gh pr view $PR',
      r'gh pr view *',
      r'cd other; head file',
      r'export PATH=/tmp; head file',
      r'printf -v PATH /tmp; head file',
      r'printf -vPATH /tmp; head file',
      r"printf '%n' PATH; head file",
      r'enable -n echo; head file',
      r'readonly PATH=/tmp; head file',
      r'eval "head file"',
      r'gh pr view 429 || head file',
      r'echo hi; sh -c "head file"',
      r'echo hi; rm file > result',
    ]) {
      expect(
          CommandPrefixPlan.parse(request('/bin/sh', ['-c', script]),
              workspace: workspace.path,
              searchPath: '${bin.path}:/usr/bin:/bin'),
          isNull,
          reason: script);
    }
    final quoted = plan(request('/bin/sh',
        ['-c', '${bin.path}/grep "a | b" | ${bin.path}/head -n 35']));
    expect(quoted.stages.first.arguments, ['a | b']);
  });

  test('literal command lists offer every prefix and require every rule',
      () async {
    final recorder = _Recorder();
    final gate = runner(recorder);
    ProcessRequest shell(String script) => request('/bin/sh', ['-c', script]);
    // Saving just the heading must not authorize the commands that follow it.
    expect(await gate.run(shell("echo 'heading'")), isA<CommandCompleted>());
    final script = "echo '=== run.sh (what platforms)'; "
        '${bin.path}/head -40 run.sh; '
        "echo '=== engine selection'; "
        "${bin.path}/grep -n 'hooks\\|user_defines' pubspec.yaml && "
        '${bin.path}/grep -rn Backend lib 2>/dev/null | ${bin.path}/head -12';
    decision = ApprovalDecision.deny;
    expect(await gate.run(shell(script)), isA<CommandRefused>());
    expect(asks.last.details['command_prefixes'], ['echo', 'head', 'grep']);
    decision = ApprovalDecision.allowPrefixInSession;
    expect(await gate.run(shell(script)), isA<CommandCompleted>());
    final asksBefore = asks.length;
    decision = ApprovalDecision.deny;
    expect(await gate.run(shell(script.replaceFirst('-40', '-50'))),
        isA<CommandCompleted>());
    expect(asks, hasLength(asksBefore));
    // A new last command is checked even if all earlier stages match.
    expect(await gate.run(shell('$script; ${bin.path}/sed -n 1p file')),
        isA<CommandRefused>());
    expect(asks, hasLength(asksBefore + 1));
    // Context changes and extra access still need approval.
    expect(await gate.run(shell(script.replaceFirst('2>/dev/null', '2>&1'))),
        isA<CommandRefused>());
    expect(
        await gate.run(shell(script),
            control: const ProcessControl(
                networkRequested: true, networkReason: 'New access')),
        isA<CommandRefused>());
    expect(recorder.requests, hasLength(3));
  });

  test('shell builtins and external executables have separate prefix rules',
      () {
    final builtin = plan(request('/bin/sh', ['-c', 'echo hello']));
    final external = plan(request('/bin/sh', ['-c', '/bin/echo hello']));
    expect(builtin.labels, ['echo']);
    expect(builtin.stages.single.executable,
        File('/bin/sh').resolveSymbolicLinksSync());
    expect(builtin.stages.single.executable,
        isNot(external.stages.single.executable));
    tools.commandApprovals
        .rememberPrefixes(builtin, {'execute'}, CommandApprovalScope.session);
    expect(tools.commandApprovals.coversPrefixes(external, 'execute'), false);
    expect(
        tools.commandApprovals.coversPrefixes(
            plan(request('/bin/sh', ['-c', 'echo bye'])), 'execute'),
        true);
  });

  for (final scope in [
    CommandApprovalScope.session,
    CommandApprovalScope.workspace
  ]) {
    test('command lists with builtins survive restoring ${scope.name} grants',
        () {
      final initial = plan(request(
          '/bin/sh', ['-c', "echo heading; ${bin.path}/head -40 run.sh"]));
      tools.commandApprovals.rememberPrefixes(initial, {'execute'}, scope);
      final fresh = create();
      if (scope == CommandApprovalScope.session) {
        fresh.commandApprovals.restoreSessionPrefixes(
            tools.commandApprovals.sessionPrefixEntries);
      }
      expect(
          fresh.commandApprovals.coversPrefixes(
              plan(request('/bin/sh',
                  ['-c', "echo other; ${bin.path}/head -50 other.sh"])),
              'execute'),
          true);
    });
  }

  test('unsupported shell prompts explain why remembering is unavailable',
      () async {
    decision = ApprovalDecision.deny;
    expect(
        await runner(_Recorder())
            .run(request('/bin/sh', ['-c', 'cd other; ${bin.path}/head file'])),
        isA<CommandRefused>());
    expect(asks.single.details['command_prefixes'], isNull);
    expect(asks.single.details['command_prefix_unavailable_reason'],
        contains('state-changing builtins'));
  });

  test('workspace prefixes survive new conversations; revocation is read live',
      () async {
    decision = ApprovalDecision.allowPrefixInWorkspace;
    final first = runner(_Recorder());
    expect(await first.run(request('gh', ['pr', 'view', '429'])),
        isA<CommandCompleted>());
    expect(tools.commandApprovals.sessionPrefixEntries, isEmpty);
    final fresh = create();
    final recorder = _Recorder();
    final next = runner(recorder, fresh);
    decision = ApprovalDecision.deny;
    expect(await next.run(request('gh', ['pr', 'view', '430'])),
        isA<CommandCompleted>());
    expect(asks, hasLength(1),
        reason: 'private HOME/TMPDIR generations do not invalidate rules');
    tools.commandApprovals
        .revoke(tools.commandApprovals.entries.single['id'] as String);
    expect(await next.run(request('gh', ['pr', 'view', '431'])),
        isA<CommandRefused>());
    expect(recorder.requests, hasLength(1));
  });

  test(
      'conversation grants resume with their log and stay out of new conversations',
      () async {
    final loop = AgentLoop(provider: ScriptedProvider([]), plugins: [tools]);
    loop.mountPlugin(tools);
    expect(await runner(_Recorder()).run(request('gh', ['pr', 'view', '429'])),
        isA<CommandCompleted>());
    expect(
        loop.derive().pluginStates[tools.id]?['command-prefixes'], isNotNull);
    final resumed = create();
    final restored = AgentLoop(
        provider: ScriptedProvider([]), plugins: [resumed], seedLog: loop.log);
    restored.mountPlugin(resumed);
    decision = ApprovalDecision.deny;
    expect(
        await runner(_Recorder(), resumed)
            .run(request('gh', ['pr', 'view', '430'])),
        isA<CommandCompleted>());
    expect(
        await runner(_Recorder(), create())
            .run(request('gh', ['pr', 'view', '430'])),
        isA<CommandRefused>());
    final id =
        resumed.commandApprovals.sessionPrefixEntries.single['id'] as String;
    resumed.commandApprovals.revoke(id);
    expect(
        (restored
            .derive()
            .pluginStates[resumed.id]!['command-prefixes']!
            .value!['grants'] as List),
        isEmpty);
  });

  test('environment and PATH changes invalidate grants and remain filtered',
      () async {
    final recorder = _Recorder();
    final gate = runner(recorder);
    expect(await gate.run(request('gh', ['pr', 'view', '429'])),
        isA<CommandCompleted>());
    final original = recorder.requests.single.environment!;
    expect(original.containsKey('PRIVATE_TOKEN'), false);
    expect(original['PATH'], contains('/opt/homebrew/bin'));
    settings.set(commandEnvironmentSetting, {'BUILD_MODE': 'debug'},
        SettingScope.session);
    decision = ApprovalDecision.deny;
    expect(await gate.run(request('gh', ['pr', 'view', '430'])),
        isA<CommandRefused>());
    decision = ApprovalDecision.allowPrefixInSession;
    expect(await gate.run(request('gh', ['pr', 'view', '430'])),
        isA<CommandCompleted>());
    expect(recorder.requests.last.environment!['BUILD_MODE'], 'debug');
    settings.set(
        commandPathSetting, '${bin.path}:/usr/bin:/bin', SettingScope.session);
    decision = ApprovalDecision.deny;
    expect(await gate.run(request('gh', ['pr', 'view', '431'])),
        isA<CommandRefused>());
    expect(original.containsKey('BUILD_MODE'), false);
  });

  test('an approval in progress uses its frozen environment', () async {
    final entered = Completer<void>();
    final release = Completer<ApprovalDecision>();
    answer = (_) {
      entered.complete();
      return release.future;
    };
    final recorder = _Recorder();
    final gate = runner(recorder);
    final running = gate.run(request('gh', ['pr', 'view', '429']));
    await entered.future;
    settings.set(commandEnvironmentSetting, {'BUILD_MODE': 'changed'},
        SettingScope.session);
    release.complete(ApprovalDecision.allow);
    expect(await running, isA<CommandCompleted>());
    expect(
        recorder.requests.single.environment!.containsKey('BUILD_MODE'), false);
    expect(recorder.controls.single!.approvedEnvironment,
        recorder.requests.single.environment);
  });

  test(
      'revoking a prefix while another access approval is pending refuses execution',
      () async {
    final recorder = _Recorder();
    final gate = runner(recorder);
    expect(await gate.run(request('gh', ['pr', 'view', '429'])),
        isA<CommandCompleted>());
    final entered = Completer<void>();
    final release = Completer<ApprovalDecision>();
    answer = (_) {
      entered.complete();
      return release.future;
    };
    final pending = gate.run(request('gh', ['pr', 'view', '430']),
        control: const ProcessControl(
            networkRequested: true, networkReason: 'New access'));
    await entered.future;
    tools.commandApprovals
        .revoke(tools.commandApprovals.entries.single['id'] as String);
    release.complete(ApprovalDecision.allow);
    expect(await pending, isA<CommandRefused>());
    expect(recorder.requests, hasLength(1));
  });

  test('cancelled prefix answers cannot create a late grant', () async {
    final entered = Completer<void>();
    final release = Completer<ApprovalDecision>();
    answer = (_) {
      entered.complete();
      return release.future;
    };
    final cancel = Completer<void>();
    var cancelled = false;
    final recorder = _Recorder();
    final gate = runner(recorder);
    final pending = gate.run(request('gh', ['pr', 'view', '429']),
        control: ProcessControl(
            isCancelled: () => cancelled, whenCancelled: cancel.future));
    await entered.future;
    cancelled = true;
    cancel.complete();
    expect(await pending, isA<CommandRefused>());
    release.complete(ApprovalDecision.allowPrefixInWorkspace);
    await Future<void>.delayed(Duration.zero);
    expect(tools.commandApprovals.entries, isEmpty);
    expect(recorder.requests, isEmpty);
  });

  test(
      'changing an executable symlink during approval refuses execution and storage',
      () async {
    final alias = Link('${bin.path}/gh-link')..createSync('${bin.path}/gh');
    final entered = Completer<void>();
    final release = Completer<ApprovalDecision>();
    answer = (_) {
      entered.complete();
      return release.future;
    };
    final recorder = _Recorder();
    final gate = runner(recorder);
    final pending = gate.run(request(alias.path, ['pr', 'view', '429']));
    await entered.future;
    alias.deleteSync();
    alias.createSync('${bin.path}/head');
    release.complete(ApprovalDecision.allowPrefixInWorkspace);
    expect(await pending, isA<CommandRefused>());
    expect(tools.commandApprovals.entries, isEmpty);
    expect(recorder.requests, isEmpty);
  });

  test(
      'working directory defaults apply to exec and bash, with explicit overrides',
      () async {
    final sub = Directory('${workspace.path}/sub')..createSync();
    settings.set(commandWorkingDirectorySetting, 'sub', SettingScope.session);
    final context = TurnContext(CancelToken(),
        input: const Input('go', id: 'prompt'),
        messages: [],
        promptSections: [],
        pinnedTools: []);
    tools.onPrompt(context);
    settings.set(commandWorkingDirectorySetting, '', SettingScope.session);
    tools.beforeModelCall(context);
    final commandContexts = context.promptSections
        .where((p) => p.startsWith('Default command working_directory:'));
    expect(commandContexts, hasLength(1));
    expect(commandContexts.single,
        contains('working_directory: ${workspace.path}'));
    settings.set(commandWorkingDirectorySetting, 'sub', SettingScope.session);
    final recorder = _Recorder();
    final exec = ExecTool(
        runner: recorder,
        readWorkingDirectory: () => tools.commandWorkingDirectory);
    final bash = BashTool(
        runner: recorder,
        readWorkingDirectory: () => tools.commandWorkingDirectory);
    await exec.execute({
      'program': 'gh',
      'args': ['pr', 'view', '429']
    });
    await bash.execute({'command': 'gh pr view 429'});
    await exec.execute({'program': 'gh', 'working_directory': workspace.path});
    expect(recorder.requests.map((r) => r.workingDirectory),
        [sub.path, sub.path, workspace.path]);
    expect(recorder.requests.first.arguments, ['pr', 'view', '429']);
    expect(
        () => settings.set(commandEnvironmentSetting, {'BUILD_MODE': 'debug'},
            SettingScope.workspace),
        throwsArgumentError);
    expect(
        () => settings.set(commandEnvironmentSetting, {'BASH_ENV': '/tmp/rc'},
            SettingScope.session),
        throwsFormatException);
  });
}
