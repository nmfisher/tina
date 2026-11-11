// The box-3 ask round-trip, end to end: a command no box contains asks
// through the existing approval dialog, the "always allow this pattern"
// answer stores a rule in the NEW allowlist file (not the scopes store),
// and the rule names the box/profile future matches run in.
//
// Run: dart test
library;

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_tools/tina_tools.dart';

void main() {
  test('a pattern answer stores the rule in the box allowlist', () async {
    final fixture = Directory.systemTemp.createTempSync('box-flow-');
    addTearDown(() => fixture.deleteSync(recursive: true));
    final workspace = Directory(path.join(fixture.path, 'project'))
      ..createSync();
    final tinaDir = Directory(path.join(workspace.path, '.tina'))
      ..createSync();
    final plugin = ToolsPlugin(
      workspaceRoot: workspace.path,
      tinaDir: tinaDir,
      mode: PermissionMode.ask,
      permissionBoxes: true,
      hostEnvironment: {
        'HOME': fixture.path,
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
      },
    );
    addTearDown(plugin.closeSession);
    attachModePolicy(plugin);
    final channel = StreamApprovalChannel();
    final approvals = ApprovalsPlugin(channel: channel);
    addTearDown(channel.closeSession);
    addTearDown(approvals.closeSession);
    plugin.modePolicy.approvals = approvals;

    final confined = plugin.processRunner.inner is ConfinedProcessRunner &&
        (plugin.processRunner.inner as ConfinedProcessRunner)
            .confinesFilesystem;
    final asks = <String>[];
    final subscription = channel.requests.listen((request) {
      asks.add(request.target);
      expect(request.details['command_pattern_target'],
          'curl -sI https://example.com');
      expect(request.details['persistent_command_pattern'], isTrue);
      // The dialog speaks regex; the box allowlist stores the glob.
      channel.respond(request.id, ApprovalDecision.allowAlways,
          commandPattern: r'curl .*');
    });
    addTearDown(subscription.cancel);

    final request = (
      command: 'curl',
      arguments: ['-sI', 'https://example.com'],
      workingDirectory: workspace.path,
      environment: null,
      stdin: null,
      timeout: null,
    );
    final first = await plugin.processRunner.run(request,
        control: const ProcessControl(
            networkRequested: true, networkReason: 'fetch a page'));
    expect(first, isA<CommandCompleted>());

    // One list: the pattern landed in the box allowlist as a glob, naming
    // the box and profile the approved run used (network run → packages).
    final allowlistFile = File(boxAllowlistProjectPath(workspace.path));
    expect(allowlistFile.existsSync(), isTrue);
    expect(allowlistFile.readAsStringSync(), contains('version 1'));
    expect(allowlistFile.readAsStringSync(), contains('curl * -> 2/packages'));
    // The scopes store did not gain the pattern.
    expect(
        plugin.commandApprovals.entries.where((entry) =>
            entry['kind'] == null &&
            (entry['pattern'] as String?)?.contains('curl') == true),
        isEmpty);

    // The second run matches the stored rule. With a confinement backend
    // it runs silently in the packages profile; without one no box can
    // hold it, so it correctly asks again (fail closed).
    await plugin.processRunner.run(request);
    if (confined) {
      expect(asks, hasLength(1));
      expect(plugin.boxes.drainReports().single, contains('packages'));
    } else {
      expect(asks, hasLength(2));
      expect(plugin.boxes.drainReports(), isEmpty);
    }
  });
}
