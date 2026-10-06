import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_tools/tina_tools.dart';

void main() {
  ScopedSettings newSettings() {
    final catalog = SettingCatalog()
      ..register(readOnlyDirectoriesSetting)
      ..register(writeDirectoriesSetting);
    final settings =
        ScopedSettings(catalog: catalog, backend: MemorySettingsBackend());
    addTearDown(settings.close);
    return settings;
  }

  late Directory root, workspace, external, other, tina;
  setUp(() {
    root = Directory.systemTemp.createTempSync('tina-write-dirs-');
    workspace = Directory('${root.path}/workspace')..createSync();
    external = Directory('${root.path}/external')..createSync();
    other = Directory('${root.path}/external-other')..createSync();
    tina = Directory('${external.path}/.tina')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('checkbox saves directory writes, including atomic edits, in every mode',
      () async {
    for (final mode in PermissionMode.values) {
      final settings = newSettings();
      final plugin = ToolsPlugin(
          workspaceRoot: workspace.path,
          tinaDir: tina,
          mode: mode,
          settings: settings,
          osSandbox: false);
      final channel = StreamApprovalChannel();
      final service = ApprovalsPlugin(channel: channel);
      final requests = <ApprovalRequest>[];
      final sub = channel.requests.listen((request) {
        requests.add(request);
        channel.respond(
            request.id,
            requests.length == 1
                ? ApprovalDecision.allowWritesInDirectory
                : ApprovalDecision.deny);
      });
      plugin.modePolicy.approvals = service;
      addTearDown(() async {
        plugin.closeSession();
        service.closeSession();
        await sub.cancel();
        channel.closeSession();
      });
      final write =
          plugin.toolList.singleWhere((t) => t.schema.name == 'write');
      final firstPath = '${external.path}/${mode.name}.txt';
      final first =
          await write.execute({'filePath': firstPath, 'content': 'before'});
      expect(first.isError, isFalse, reason: first.content);
      expect(requests, hasLength(1));
      expect(requests.single.details['write_directory'],
          external.resolveSymbolicLinksSync());
      expect(
          settings.read(writeDirectoriesSetting).source, SettingScope.global);
      expect(plugin.sandbox.grants.isEmpty, isTrue);
      final sibling = await write.execute({
        'filePath': '${external.path}/nested/${mode.name}.txt',
        'content': 'sibling'
      });
      expect(sibling.isError, isFalse, reason: sibling.content);
      final edit = plugin.toolList.singleWhere((t) => t.schema.name == 'edit');
      final edited = await edit.execute(
          {'filePath': firstPath, 'oldString': 'before', 'newString': 'after'});
      expect(edited.isError, isFalse, reason: edited.content);
      expect(File(firstPath).readAsStringSync(), 'after');
      expect(requests, hasLength(1));
      expect(
          (await write.execute(
                  {'filePath': '${other.path}/outside', 'content': 'blocked'}))
              .isError,
          isTrue);
      expect(requests, hasLength(2));
      settings.set(writeDirectoriesSetting, <String>[], SettingScope.global);
      expect(
          (await write.execute({'filePath': firstPath, 'content': 'blocked'}))
              .isError,
          isTrue);
      expect(requests, hasLength(3));
      expect(plugin.processRunner.writableDirectories.roots,
          isNot(contains(external.resolveSymbolicLinksSync())));
    }
  });

  test('grants reject sibling prefixes, symlink escapes and Tina data',
      () async {
    final plugin = ToolsPlugin(workspaceRoot: workspace.path, tinaDir: tina);
    addTearDown(plugin.closeSession);
    plugin.rememberWriteDirectory(external.path);
    final alias = Link('${external.path}/escape')..createSync(other.path);
    for (final path in [
      '${other.path}/file',
      '${alias.path}/new-file',
      '${tina.path}/data'
    ]) {
      await expectLater(plugin.sandbox.writeFile(path, 'blocked'),
          throwsA(isA<SandboxViolation>()),
          reason: path);
      expect(File(path).existsSync(), isFalse);
    }
    final aliasToExternal = Link('${root.path}/alias')
      ..createSync(external.path);
    plugin.rememberWriteDirectory('${aliasToExternal.path}/new/nested');
    expect(plugin.writeDirectories.paths,
        contains('${external.resolveSymbolicLinksSync()}/new/nested'));
  }, skip: Platform.isWindows);

  test('denial and cancellation do not save write access', () async {
    for (final cancel in [true, false]) {
      final plugin = ToolsPlugin(workspaceRoot: workspace.path, tinaDir: tina);
      final channel = StreamApprovalChannel();
      final service = ApprovalsPlugin(channel: channel);
      plugin.modePolicy.approvals = service;
      final sub = channel.requests.listen((request) {
        if (cancel) {
          service.closeSession();
        } else {
          channel.respond(request.id, ApprovalDecision.deny);
        }
      });
      addTearDown(() async {
        plugin.closeSession();
        service.closeSession();
        await sub.cancel();
        channel.closeSession();
      });
      final result = await plugin.toolList
          .singleWhere((t) => t.schema.name == 'write')
          .execute({'filePath': '${external.path}/blocked', 'content': 'no'});
      expect(result.isError, isTrue);
      expect(plugin.writeDirectories.paths, isEmpty);
    }
  });

  test('OS layouts upgrade read mounts and protect Tina after writable parents',
      () async {
    final writes = WriteDirectories()..replace([external.path]);
    final reads = ReadOnlyDirectories()..replace([external.path]);
    final plan = SandboxPlan(
        workspaceRoot: workspace.path,
        tinaDir: tina.path,
        readDirectories: reads,
        writeDirectories: writes);
    final runner = _Recorder();
    final os = OsSandboxRunner(
        inner: runner,
        plan: plan,
        backend: SandboxBackend.bwrap,
        hostLayout: () => SandboxHostLayout(
            readOnlyDirectories: [], temporaryDirectories: []));
    final call = (
      command: 'touch',
      arguments: ['${external.path}/file'],
      workingDirectory: workspace.path,
      environment: null,
      stdin: null,
      timeout: null
    );
    await os.run(call);
    final args = runner.calls.single.arguments;
    final rootPath = external.resolveSymbolicLinksSync();
    final writeIndex = args.indexOf(rootPath);
    expect(args[writeIndex - 1], '--bind');
    final tinaIndex = args.indexOf(tina.path);
    expect(args[tinaIndex - 1], '--ro-bind');
    expect(tinaIndex, greaterThan(writeIndex));
    final seatbelt = OsSandboxRunner(
        inner: runner, plan: plan, backend: SandboxBackend.sandboxExec);
    await seatbelt.run(call);
    final profile = runner.calls.last.arguments[1];
    expect(profile, contains('(allow file-write* (subpath "$rootPath"))'));
    expect(profile, endsWith('(deny file-write* (subpath "${tina.path}"))\n'));
    writes.replace([]);
    expect(plan.extraWritablePaths, isEmpty);
  });

  test('settings validate paths and preserve existing workspace scope', () {
    final settings = newSettings();
    expect(
        () => settings.set(
            writeDirectoriesSetting, ['relative'], SettingScope.global),
        throwsFormatException);
    expect(() => writeDirectoriesSetting.checked(['/bad\u0000']),
        throwsFormatException);
    settings.set(writeDirectoriesSetting, <String>[], SettingScope.workspace);
    final plugin = ToolsPlugin(
        workspaceRoot: workspace.path, tinaDir: tina, settings: settings);
    addTearDown(plugin.closeSession);
    plugin.rememberWriteDirectory(external.path);
    expect(
        settings.read(writeDirectoriesSetting).source, SettingScope.workspace);
  });
}

final class _Recorder implements ProcessRunner {
  final calls = <ProcessRequest>[];
  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    calls.add(request);
    return const CommandCompleted(exitCode: 0, stdout: '', stderr: '');
  }
}
