import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:tina_tools/src/command_workflow.dart';
import 'package:tina_tools/src/read_only_commands.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_settings/tina_settings.dart';

void main() {
  late Directory root, workspace, nested, other;
  late File executable, grants;
  setUp(() {
    root = Directory.systemTemp.createTempSync('tina-workflow-');
    workspace = Directory('${root.path}/work')..createSync();
    nested = Directory('${workspace.path}/packages/core')
      ..createSync(recursive: true);
    other = Directory('${root.path}/other')..createSync();
    executable = File('${root.path}/sdk/bin/dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('fixture');
    grants = File('${root.path}/trusted/commands.json');
  });
  tearDown(() => root.deleteSync(recursive: true));
  ProcessRequest request(List<String> arguments,
          {String? cwd, Map<String, String>? environment, String? input}) =>
      (
        command: executable.path,
        arguments: arguments,
        workingDirectory: cwd ?? workspace.path,
        environment: environment,
        stdin: input,
        timeout: null,
      );
  CommandApprovalStore store({String? cwd}) =>
      CommandApprovalStore(workspace: cwd ?? workspace.path, file: grants);
  const execution = {ProcessPermission.execution};

  test('workspace tests cover selected files and packages after restart', () {
    store().remember(request(['test', 'test/first_test.dart']), execution,
        CommandApprovalScope.workspace,
        workflow: true);
    expect(
        store().covers(
            request(['test', '--reporter', 'expanded', 'test/second_test.dart'],
                cwd: nested.path),
            execution),
        isTrue);
    expect(
        store().covers(request(['run', 'bin/main.dart']), execution), isFalse);
    expect(store().covers(request(['test', other.path]), execution), isFalse);
    expect(
        store().covers(request(['test'], cwd: other.path), execution), isFalse);
    expect(
        store().covers(
            request(['test']), {...execution, ProcessPermission.network}),
        isFalse);
    expect(
        store().covers(
            request(['test']), {...execution, ProcessPermission.unconfined}),
        isFalse);
  });

  test('global workflows apply to other workspaces and revoke immediately', () {
    store().remember(request(['test']), execution, CommandApprovalScope.global,
        workflow: true);
    final second = store(cwd: other.path);
    expect(
        second.covers(request(['test'], cwd: other.path), execution), isTrue);
    store().revoke(store().entries.single['id'] as String);
    expect(
        second.covers(request(['test'], cwd: other.path), execution), isFalse);
  });

  test('network approval never generalizes into a workflow', () {
    store().remember(
        request(['test', 'first.dart']),
        {...execution, ProcessPermission.network},
        CommandApprovalScope.workspace,
        workflow: true);
    expect(store().entries.single.containsKey('workflow'), isFalse);
    expect(
        store().covers(request(['test', 'second.dart']),
            {...execution, ProcessPermission.network}),
        isFalse);
  });

  test('one review covers SDK access and reusable sandboxed tests', () async {
    final sdk = Directory('${root.path}/home/flutter');
    Directory('${sdk.path}/packages/flutter_tools').createSync(recursive: true);
    final cache = Directory('${sdk.path}/bin/cache')
      ..createSync(recursive: true);
    final dart = File('${cache.path}/dart-sdk/bin/dart')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\nprintf "workflow works"\n');
    Process.runSync('/bin/chmod', ['+x', dart.path]);
    final settings = ScopedSettings(
        catalog: SettingCatalog()
          ..register(readOnlyDirectoriesSetting)
          ..register(writeDirectoriesSetting),
        backend: MemorySettingsBackend());
    final tools = ToolsPlugin(
        workspaceRoot: workspace.path,
        tinaDir: Directory('${workspace.path}/.tina'),
        settings: settings,
        approvalStore: store(),
        sandboxState: Directory('${root.path}/state'),
        hostEnvironment: {
          'HOME': sdk.parent.path,
          'PATH': '/usr/bin:/bin',
          'TMPDIR': workspace.path
        });
    addTearDown(tools.closeSession);
    final channel = StreamApprovalChannel();
    final approvals = ApprovalsPlugin(channel: channel);
    tools.modePolicy.approvals = approvals;
    addTearDown(approvals.closeSession);
    addTearDown(channel.closeSession);
    final requests = <ApprovalRequest>[];
    final subscription = channel.requests.listen((ask) {
      requests.add(ask);
      if (requests.length != 1) {
        channel.respond(ask.id, ApprovalDecision.deny);
        return;
      }
      expect(
          ask.details['permission_scope_label'], 'dart test in this project');
      expect(ask.details['recommended_scope'], 'workspace');
      final offers = ask.details['directory_accesses'] as List;
      expect(offers,
          contains(containsPair('path', sdk.resolveSymbolicLinksSync())));
      expect(offers,
          contains(containsPair('path', cache.resolveSymbolicLinksSync())));
      channel
          .respond(ask.id, ApprovalDecision.allowWorkspace, directoryGrants: [
        DirectoryAccessGrant(sdk.resolveSymbolicLinksSync(),
            DirectoryAccess.read, DirectoryGrantScope.global),
        DirectoryAccessGrant(cache.resolveSymbolicLinksSync(),
            DirectoryAccess.write, DirectoryGrantScope.global),
      ]);
    });
    addTearDown(subscription.cancel);
    final exec =
        tools.toolList.singleWhere((tool) => tool.schema.name == 'exec');
    for (final input in [
      {
        'program': dart.path,
        'args': ['test', 'first.dart']
      },
      {
        'program': dart.path,
        'args': ['test', '--reporter=expanded', 'second.dart'],
        'working_directory': nested.path
      },
    ]) {
      final result = await exec.execute(input);
      expect(result.isError, isFalse, reason: result.content);
      expect(result.content, contains('workflow works'));
    }
    expect(requests, hasLength(1));
    expect(settings.override(readOnlyDirectoriesSetting, SettingScope.global),
        [sdk.resolveSymbolicLinksSync()]);
    final denied = await exec.execute({
      'program': dart.path,
      'args': ['test'],
      'network': true,
      'network_reason': 'separate permission'
    });
    expect(denied.isError, isTrue);
    expect(requests, hasLength(2));
  }, skip: Platform.isWindows);

  test('stdin, environments, unknown flags, escapes and host grants stay exact',
      () {
    for (final command in [
      request(['test'], environment: {}),
      request(['test'], input: 'input'),
      request(['test', '--packages=/outside/package_config.json']),
      request(['format', '../outside.dart']),
      request(['compile', 'exe', 'bin/main.dart', '-o', other.path]),
    ]) {
      expect(commandWorkflow(command, workspace.path), isNull);
    }
    store().remember(
        request(['test']),
        {...execution, ProcessPermission.unconfined},
        CommandApprovalScope.workspace,
        workflow: true);
    expect(store().entries.single.containsKey('workflow'), isFalse);
    expect(store().covers(request(['test', 'other.dart']), execution), isFalse);
  });

  test('read grants cannot grant execution and broad reader trust pins content',
      () {
    store().replaceSettings(CommandApprovalScope.workspace, {
      'tina/tools/read_only_directories': [other.path]
    });
    expect(store().covers(request(['test']), execution), isFalse);
    expect(
        store().settings(
            CommandApprovalScope.workspace)['tina/tools/read_only_directories'],
        [other.path]);
    final reader = File('${root.path}/rg')..writeAsStringSync('version one');
    Process.runSync('/bin/chmod', ['+x', reader.path]);
    final read = (
      command: reader.path,
      arguments: ['--files'],
      workingDirectory: workspace.path,
      environment: null,
      stdin: null,
      timeout: null
    );
    expect(readOnlyExecutable(read), isNull);
    store().rememberReader(
        reader.resolveSymbolicLinksSync(),
        sha256.convert(reader.readAsBytesSync()).toString(),
        CommandApprovalScope.global);
    expect(
        readOnlyExecutable(read, trustedExecutables: store().readerExecutables),
        reader.resolveSymbolicLinksSync());
    reader.writeAsStringSync('version two');
    expect(
        readOnlyExecutable(read, trustedExecutables: store().readerExecutables),
        isNull);
  });

  test(
      'structured builds validate output paths and stay inside their workspace',
      () {
    expect(
        commandWorkflow(
            request(['compile', 'exe', 'bin/main.dart', '--output=build/main']),
            workspace.path),
        'dart compile exe');
    expect(commandWorkflow(request(['format', 'lib']), workspace.path),
        'dart format');
    expect(
        commandWorkflow(
            request([
              'compile',
              'exe',
              'bin/main.dart',
              '--output=${other.path}/main'
            ]),
            workspace.path),
        isNull);
  });
}
