import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_tools/tina_tools.dart';

class _CommandRecorder implements ConfinedProcessRunner {
  @override
  bool get confinesFilesystem => true;

  @override
  Future<RunOutcome> run(ProcessRequest request,
          {ProcessControl? control}) async =>
      const CommandCompleted(exitCode: 0, stdout: '', stderr: '');
}

/// End-to-end regression coverage: a real approval dialog (the kind a user
/// actually sees) driving the tools plugin. Guards against reports of repeated
/// prompts after a directory grant is granted: one checkbox must silence every
/// later request under that subtree while a sibling root still asks.
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

  late Directory root, workspace, external, other;
  setUp(() {
    root = Directory.systemTemp.createTempSync('tina-grant-e2e-');
    workspace = Directory('${root.path}/workspace')..createSync();
    external = Directory('${root.path}/external')..createSync();
    // The plugin's tinaDir must exist: a missing protected leaf makes its
    // parent a protected-parent on Linux, where write grants into that
    // parent are deliberately refused (sandbox mount masking).
    Directory('${external.path}/.tina').createSync();
    other = Directory('${root.path}/external-other')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  ApprovalDialog dialogFor(ApprovalRequest request) => ApprovalDialog(null,
      ask: ApprovalAskContext(request.operation, request.target, request.reason,
          details: request.details));

  test('Remember reloads checked directories on later command approvals',
      () async {
    final paths = [external, other]
        .map((directory) => directory.resolveSymbolicLinksSync())
        .toList();
    final files = [
      for (final directory in paths)
        (File('$directory/input.txt')..writeAsStringSync('input')).path
    ];
    final channel = StreamApprovalChannel();
    final approvals = ApprovalsPlugin(channel: channel);
    final requests = StreamIterator(channel.requests);
    addTearDown(() async {
      await requests.cancel();
      approvals.closeSession();
      channel.closeSession();
    });

    ToolsPlugin newPlugin() {
      final plugin = ToolsPlugin(
          workspaceRoot: workspace.path,
          tinaDir: Directory('${workspace.path}/.tina'));
      plugin.modePolicy.approvals = approvals;
      addTearDown(plugin.closeSession);
      return plugin;
    }

    var plugin = newPlugin();
    for (var attempt = 0; attempt < 4; attempt++) {
      // The third approval uses a fresh store, as after restarting Tina.
      if (attempt == 2) plugin = newPlugin();
      if (attempt == 3) {
        plugin.pathGrants.revoke(paths.last, write: false, recursive: true);
      }
      final runner = SandboxedProcessRunner(
          inner: _CommandRecorder(),
          workspaceRoot: workspace.path,
          commandApprover: plugin.processRunner.commandApprover);
      final nextRequest = requests.moveNext();
      final pending = runner.run((
        command: '/bin/cat',
        arguments: files,
        workingDirectory: workspace.path,
        environment: null,
        stdin: null,
        timeout: null,
      ));
      expect(await nextRequest.timeout(const Duration(seconds: 5)), isTrue);
      final request = requests.current;
      final dialog = dialogFor(request);
      final offers =
          (request.details['directory_accesses'] as List).cast<Map>();
      if (offers.every((offer) => offer['granted'] == true)) {
        // The remaining ask is execution, not filesystem access. Do not offer
        // a directory-only Remember menu when there is nothing left to grant.
        final shown = dialog
            .rows(width: 500)
            .map((row) => row.runs.map((run) => run.text).join())
            .join('\n');
        channel.respond(request.id, ApprovalDecision.allow);
        expect(await pending.timeout(const Duration(seconds: 5)),
            isA<CommandCompleted>());
        expect(shown, isNot(contains('Remember file or directory access')));
        for (final directory in paths) {
          expect(plugin.pathGrants.allows('$directory/another.txt'), true);
        }
        expect(plugin.pathGrants.grants, hasLength(3));
        continue;
      }
      if (request.details['command_prefixes'] is List) {
        // Prefix choices are now direct actions. Open the separate folder menu.
        final actionsBeforeRemember = 4 +
            (request.details['exact_command_approval'] == true ? 1 : 0) +
            (request.details['persistent_exact_command'] == true ? 1 : 0);
        for (var i = 0; i < actionsBeforeRemember; i++) {
          dialog.handleKey(ApprovalKey.down);
        }
        dialog.handleKey(ApprovalKey.confirm);
      } else {
        dialog.handleKey(ApprovalKey.always);
      }
      if (attempt == 0) {
        for (final offer in offers) {
          dialog.handleKey(ApprovalKey.down);
          if (paths.contains(offer['path'])) {
            dialog.handleKey(ApprovalKey.toggleDirectory);
          }
        }
      }
      final shown = dialog
          .rows(width: 500, height: 1000)
          .map((row) => row.runs.map((run) => run.text).join())
          .join('\n');
      // Answer before asserting so a regression cannot leave a pending run.
      final outcome = await dialog
          .awaitDecision(ScriptedKeySource([ApprovalKey.workspace]));
      channel.respond(request.id, outcome.decision,
          directoryGrants: outcome.directoryGrants);
      final result = await pending.timeout(const Duration(seconds: 5));
      expect(result, isA<CommandCompleted>(),
          reason: result is CommandRefused ? result.reason : null);
      for (final directory in paths) {
        final granted = attempt != 3 || directory != paths.last;
        expect(
            shown,
            contains(
                '[${granted ? 'x' : ' '}] Allow all reads in $directory (Space)'),
            reason: 'attempt $attempt should show the saved directory');
        expect(plugin.pathGrants.allows('$directory/another.txt'), granted);
      }
      // Reopening Remember must not create narrower redundant grants for
      // files covered by the saved directories, even across a restart.
      expect(plugin.pathGrants.grants, hasLength(attempt == 3 ? 2 : 3));
    }
  });

  // Grants the first request through the real dialog (with the "Allow all
  // writes" box checked), denies everything after.
  List<DirectoryAccessGrant> wire(
      StreamApprovalChannel channel, List<int> asks) {
    channel.requests.listen((request) {
      asks[0]++;
      if (asks[0] > 1) {
        channel.respond(request.id, ApprovalDecision.deny);
        return;
      }
      final dialog = dialogFor(request)
        ..handleKey(ApprovalKey.always)
        ..handleKey(ApprovalKey.toggleWriteDirectory);
      final outcome = dialog.current;
      channel.respond(request.id, outcome.decision,
          directoryGrants: outcome.directoryGrants);
    });
    return const [];
  }

  test('real dialog checkbox suppresses prompts under the subtree', () async {
    final settings = newSettings();
    final plugin = ToolsPlugin(
        workspaceRoot: workspace.path,
        tinaDir: Directory('${external.path}/.tina'),
        settings: settings,
        osSandbox: false);
    final channel = StreamApprovalChannel();
    final approvals = ApprovalsPlugin(channel: channel);
    plugin.modePolicy.approvals = approvals;
    final asks = [0];
    wire(channel, asks);
    addTearDown(() async {
      plugin.closeSession();
      approvals.closeSession();
      channel.closeSession();
    });

    final write = plugin.toolList.singleWhere((t) => t.schema.name == 'write');
    final edit = plugin.toolList.singleWhere((t) => t.schema.name == 'edit');

    final firstPath = '${external.path}/report.txt';
    final first =
        await write.execute({'filePath': firstPath, 'content': 'one'});
    expect(first.isError, isFalse, reason: first.content);
    expect(asks[0], 1);

    // A nested subdirectory (created on the fly) and an atomic edit are
    // covered by the same grant — no second prompt.
    final nested = await write.execute(
        {'filePath': '${external.path}/nested/data.txt', 'content': 'two'});
    expect(nested.isError, isFalse, reason: nested.content);
    final edited = await edit.execute(
        {'filePath': firstPath, 'oldString': 'one', 'newString': 'ONE'});
    expect(edited.isError, isFalse, reason: edited.content);
    expect(File(firstPath).readAsStringSync(), 'ONE');
    expect(asks[0], 1);

    // A sibling root is NOT covered — it still asks (and is denied).
    final sibling = await write.execute(
        {'filePath': '${other.path}/outside.txt', 'content': 'blocked'});
    expect(sibling.isError, isTrue);
    expect(asks[0], 2);
    expect(plugin.writeDirectories.paths,
        contains(external.resolveSymbolicLinksSync()));
  });

  test('no settings: dialog write grant is session-scoped and covers retry',
      () async {
    final plugin = ToolsPlugin(
        workspaceRoot: workspace.path,
        tinaDir: Directory('${external.path}/.tina'),
        osSandbox: false); // no settings backend, so grants live in session
    final channel = StreamApprovalChannel();
    final approvals = ApprovalsPlugin(channel: channel);
    plugin.modePolicy.approvals = approvals;
    final asks = [0];
    wire(channel, asks);
    addTearDown(() async {
      plugin.closeSession();
      approvals.closeSession();
      channel.closeSession();
    });

    final write = plugin.toolList.singleWhere((t) => t.schema.name == 'write');
    final first = await write
        .execute({'filePath': '${external.path}/a.txt', 'content': 'one'});
    expect(first.isError, isFalse, reason: first.content);
    expect(asks[0], 1);
    expect(plugin.writeDirectories.paths,
        contains(external.resolveSymbolicLinksSync()));

    // A second write in the granted directory is still silent.
    final second = await write
        .execute({'filePath': '${external.path}/b.txt', 'content': 'two'});
    expect(second.isError, isFalse, reason: second.content);
    expect(asks[0], 1);
  });
}
