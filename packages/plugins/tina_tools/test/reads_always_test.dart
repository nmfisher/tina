import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_tools/tina_tools.dart';

/// The "always permit reads" standing grant: one answer on a read-only-mode
/// directory-access ask sets a session or workspace setting; later read-only
/// certified-reader asks then run without asking. Headless: no OS backend is
/// required — the behavior under test is the approver's, not the kernel's.
void main() {
  late Directory root, workspace, library, scratch, home;
  setUp(() {
    root = Directory.systemTemp.createTempSync('tina-reads-always-');
    workspace = Directory('${root.path}/work')..createSync();
    // The session home and tina's temp space must be disjoint, as on a real
    // host (~/. vs /var/folders): the plan reads its TMPDIR freely, so a
    // library placed there is never "outside". The library lives inside the
    // home (~/datasets shape) but outside every writable/readable root —
    // the case that actually asks.
    scratch = Directory('${root.path}/scratch')..createSync();
    home = Directory('${root.path}/home')..createSync();
    library = Directory('${home.path}/library')..createSync();
    File('${library.path}/notes.txt').writeAsStringSync('library content\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  ToolsPlugin plugin(_RecordingApprovals approvals) {
    final catalog = SettingCatalog()
      ..register(readOnlyDirectoriesSetting)
      ..register(allowReadsOutsideWorkspaceSetting);
    final tools = ToolsPlugin(
        workspaceRoot: workspace.path,
        tinaDir: Directory('${workspace.path}/.tina'),
        hostEnvironment: {
          'HOME': home.path,
          'PATH': '/usr/bin:/bin',
          'TMPDIR': scratch.path
        },
        settings: ScopedSettings(catalog: catalog, backend: backend()));
    tools.modePolicy.approvals = approvals;
    tools.modePolicy.mode = PermissionMode.readOnly;
    addTearDown(tools.closeSession);
    return tools;
  }

  // A bare `cat` of an existing file is a certified reader; only its read
  // directory access outside the workspace can be missing. `tee` writes, so
  // it is never certified and never covered by a standing reads grant.
  ProcessRequest cat() => (
        command: '/bin/cat',
        arguments: ['${library.path}/notes.txt'],
        workingDirectory: workspace.path,
        environment: null,
        stdin: null,
        timeout: null,
      );
  ProcessRequest tee() => (
        command: '/usr/bin/tee',
        arguments: ['${library.path}/notes.txt'],
        workingDirectory: workspace.path,
        environment: null,
        stdin: null,
        timeout: null,
      );

  test('allowReadsAlways sets the session setting and later reads ask no more',
      () async {
    final approvals = _RecordingApprovals(ApprovalDecision.allowReadsAlways);
    final tools = plugin(approvals);
    final first = await tools.processRunner.run(cat());
    expect(first, isA<CommandCompleted>(), reason: '$first');
    expect((first as CommandCompleted).stdout, 'library content\n');
    expect(approvals.calls, 1);
    expect(approvals.offeredReadsAlways, isTrue,
        reason: 'the ask carries the all-read shape the dialog keys on');
    final second = await tools.processRunner.run(cat());
    expect(second, isA<CommandCompleted>());
    expect(approvals.calls, 1, reason: 'the standing grant answers quietly');
    expect(
        tools.settings!.read(allowReadsOutsideWorkspaceSetting).value, isTrue);
    expect(tools.settings!.read(allowReadsOutsideWorkspaceSetting).source,
        SettingScope.session);
  });

  test('the standing grant never answers a write-shaped ask', () async {
    final approvals = _RecordingApprovals(ApprovalDecision.deny);
    final tools = plugin(approvals);
    tools.settings!
        .set(allowReadsOutsideWorkspaceSetting, true, SettingScope.session);
    final outcome = await tools.processRunner.run(tee());
    expect(outcome, isA<CommandBlocked>());
    expect(File('${library.path}/notes.txt').readAsStringSync(),
        'library content\n');
    expect(approvals.calls, 0,
        reason: 'the read-only OS profile blocks writes');
  });

  test('the standing grant answers certified reads in other modes', () async {
    final approvals = _RecordingApprovals(ApprovalDecision.deny);
    final tools = plugin(approvals);
    tools.modePolicy.mode = PermissionMode.ask;
    tools.settings!
        .set(allowReadsOutsideWorkspaceSetting, true, SettingScope.session);
    final outcome = await tools.processRunner.run(cat());
    expect(outcome, isA<CommandCompleted>());
    expect(approvals.calls, 0);
  });

  test('a reads-always answer cannot authorize a network or write request',
      () async {
    final approvals = _RecordingApprovals(ApprovalDecision.allowReadsAlways);
    final tools = plugin(approvals);
    expect(
        await tools.processRunner.run(cat(),
            control: const ProcessControl(
                networkRequested: true,
                networkReason: 'separate network permission')),
        isA<CommandRefused>());
    expect(await tools.processRunner.run(tee()), isA<CommandBlocked>());
    expect(File('${library.path}/notes.txt').readAsStringSync(),
        'library content\n');
    expect(
        tools.settings!.read(allowReadsOutsideWorkspaceSetting).value, isFalse);
  });

  test('workspace scope survives a restart-shaped plugin; revocation stops it',
      () async {
    final approvals = _RecordingApprovals(ApprovalDecision.deny);
    final tools = plugin(approvals);
    tools.settings!
        .set(allowReadsOutsideWorkspaceSetting, true, SettingScope.workspace);
    final granted = await tools.processRunner.run(cat());
    expect(granted, isA<CommandCompleted>());
    expect(approvals.calls, 0);
    tools.settings!.removeOverride(
        allowReadsOutsideWorkspaceSetting, SettingScope.workspace);
    final revoked = await tools.processRunner.run(cat());
    expect(revoked, isA<CommandRefused>());
    expect(approvals.calls, 1);
  });
}

SettingsBackend backend() => MemorySettingsBackend();

final class _RecordingApprovals implements ApprovalRequester {
  _RecordingApprovals(this.decision);
  ApprovalDecision decision;
  int calls = 0;
  bool offeredReadsAlways = false;
  @override
  Future<ApprovalDecision> request(
      {required String operation,
      required String target,
      required String reason,
      ApprovalKind kind = ApprovalKind.permission,
      Future<void>? whenCancelled,
      Map<String, Object?> details = const {},
      void Function(String pattern)? onCommandPattern,
      void Function(List<DirectoryAccessGrant> grants)?
          onDirectoryGrants}) async {
    calls++;
    final scopes = details['directory_grant_scopes'];
    offeredReadsAlways = details['mode'] == 'readOnly' &&
        details['directory_accesses'] is List &&
        (details['directory_accesses'] as List)
            .every((offer) => offer is Map && offer['access'] == 'read') &&
        scopes is List &&
        scopes.contains('workspace');
    return decision;
  }
}
