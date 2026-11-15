import 'dart:io';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

void main() {
  late Directory root, workspace, other;
  late File file;
  final permissions = ProcessPermission.values.toSet();
  setUp(() {
    root = Directory.systemTemp.createTempSync('tina-command-grants-');
    workspace = Directory('${root.path}/work')..createSync();
    other = Directory('${root.path}/other')..createSync();
    file = File('${root.path}/trusted/commands.json');
  });
  tearDown(() => root.deleteSync(recursive: true));
  ProcessRequest request(
          {String? cwd,
          List<String> args = const ['hello'],
          String input = 'secret-input'}) =>
      (
        command: '/bin/echo',
        arguments: args,
        workingDirectory: cwd ?? workspace.path,
        environment: {'SECRET': 'secret-env'},
        stdin: input,
        timeout: null
      );
  CommandApprovalStore store([String? cwd]) =>
      CommandApprovalStore(workspace: cwd ?? workspace.path, file: file);

  test('session approval stays in memory and can be revoked', () {
    final first = store();
    first.remember(request(), permissions, CommandApprovalScope.session);
    expect(first.covers(request(), permissions), true);
    expect(file.existsSync(), false);
    expect(store().covers(request(), permissions), false);
    first.revoke(first.entries.single['id'] as String);
    expect(first.covers(request(), permissions), false);
  });
  test(
      'workspace grants survive restart but cannot escape the workspace or invocation',
      () {
    store().remember(request(), permissions, CommandApprovalScope.workspace);
    final restarted = store();
    expect(restarted.covers(request(), permissions), true);
    expect(store(other.path).covers(request(), permissions), false);
    expect(restarted.covers(request(cwd: other.path), permissions), false);
    expect(restarted.covers(request(args: ['changed']), permissions), false);
    expect(restarted.covers(request(input: 'changed'), permissions), false);
    expect(file.readAsStringSync(), isNot(contains('secret-input')));
    expect(file.readAsStringSync(), isNot(contains('secret-env')));
  });
  test(
      'global grants allow the same invocation across directories, never broader arguments',
      () {
    store().remember(request(), permissions, CommandApprovalScope.global);
    final elsewhere = store(other.path);
    expect(elsewhere.covers(request(cwd: other.path), permissions), true);
    expect(
        elsewhere.covers(
            request(cwd: other.path, args: ['other']), permissions),
        false);
    final id = elsewhere.entries.single['id'] as String;
    store().revoke(id);
    expect(elsewhere.covers(request(cwd: other.path), permissions), false);
  });
  test(
      'permissions never widen and separate writers retain each other\'s grants',
      () {
    final first = store(), second = store();
    first.remember(request(), {ProcessPermission.execution},
        CommandApprovalScope.workspace);
    second.remember(
        request(args: ['other']), permissions, CommandApprovalScope.workspace);
    expect(first.entries, hasLength(2));
    expect(first.covers(request(), permissions), false);
    expect(first.covers(request(), {ProcessPermission.execution}), true);
  });
  test('read-only execution grants never widen into workspace-write', () {
    final approvals = store();
    approvals.remember(request(), {ProcessPermission.execution},
        CommandApprovalScope.workspace);
    expect(
        store().covers(request(), {ProcessPermission.workspaceWrite}), false);
    final legacy = jsonDecode(file.readAsStringSync()) as Map;
    ((legacy['grants'] as List).single as Map).remove('profile_version');
    file.writeAsStringSync(jsonEncode(legacy));
    expect(store().covers(request(), {ProcessPermission.workspaceWrite}), true,
        reason:
            'legacy execution approval retains its original writable profile');
  });
  test('exact file and MCP access share scopes and live revocation', () {
    final approvals = store();
    approvals.rememberAccess('write', '/file', CommandApprovalScope.workspace);
    approvals.rememberAccess(
        'external', 'server/call', CommandApprovalScope.global);
    expect(store().coversAccess('read', '/file'), true);
    expect(store(other.path).coversAccess('write', '/file'), false);
    expect(store(other.path).coversAccess('external', 'server/call'), true);
    for (final entry in approvals.entries.toList()) {
      approvals.revoke(entry['id'] as String);
    }
    expect(store().coversAccess('read', '/file'), false);
    expect(store().coversAccess('external', 'server/call'), false);
    file.writeAsStringSync('{broken');
    expect(store().coversAccess('read', '/file'), false);
  });
  test('malformed persisted data cannot authorize a request', () {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{broken');
    expect(store().covers(request(), permissions), false);
  });

  ProcessRequest pipeline(String script,
          {String? cwd, Map<String, String>? environment, String? input}) =>
      (
        command: '/bin/sh',
        arguments: ['-c', script],
        workingDirectory: cwd ?? workspace.path,
        environment: environment ?? {'LANG': 'C'},
        stdin: input,
        timeout: null,
      );
  const script = 'printf hello | head -n2';
  const pattern = r'printf hello \| head -n[0-9]+';

  for (final scope in CommandApprovalScope.values) {
    test('regex $scope covers only the reviewed command family and context',
        () {
      final first = store();
      first.remember(pipeline(script), {ProcessPermission.execution}, scope,
          pattern: pattern);
      final effective = scope == CommandApprovalScope.session ? first : store();
      expect(
          effective.covers(pipeline('printf hello | head -n20'),
              {ProcessPermission.execution}),
          true);
      for (final denied in [
        'printf goodbye | head -n2',
        'printf hello | head -n2; echo extra',
        'printf hello | head -n2\necho extra',
        'printf hello | head -n2\n',
      ]) {
        expect(
            effective.covers(pipeline(denied), {ProcessPermission.execution}),
            false);
      }
      expect(effective.covers(pipeline(script), permissions), false,
          reason: 'execution rules never acquire network or host access');
      expect(
          effective.covers(pipeline(script, input: 'different'),
              {ProcessPermission.execution}),
          false);
      expect(
          effective.covers(pipeline(script, environment: {'LANG': 'changed'}),
              {ProcessPermission.execution}),
          false);
      expect(
          effective.covers(
              pipeline(script, cwd: other.path), {ProcessPermission.execution}),
          scope == CommandApprovalScope.global);
      expect(
          store(other.path).covers(
              pipeline(script, cwd: other.path), {ProcessPermission.execution}),
          scope == CommandApprovalScope.global);
      if (scope != CommandApprovalScope.session) {
        first.revoke(first.entries.single['id'] as String);
        expect(
            effective.covers(pipeline(script), {ProcessPermission.execution}),
            false);
      }
    });
  }

  test('regex matching preserves argv boundaries and resolved executables', () {
    final grant = store();
    grant.remember(request(args: ['hello world']), permissions,
        CommandApprovalScope.session,
        pattern: r"/bin/echo 'hello [a-z]+'");
    expect(grant.covers(request(args: ['hello there']), permissions), true);
    expect(grant.covers(request(args: ['hello', 'there']), permissions), false);
    final original = request(args: ['hello world']);
    expect(
        grant.covers((
          command: '/usr/bin/printf',
          arguments: original.arguments,
          workingDirectory: original.workingDirectory,
          environment: original.environment,
          stdin: original.stdin,
          timeout: null
        ), permissions),
        false);
  });

  test('invalid or partial regex rules cannot be remembered', () {
    for (final invalid in ['', '[', r'head -n[0-9]+', 'printf\x1bhello']) {
      expect(
          () => store().remember(
              pipeline(script), permissions, CommandApprovalScope.workspace,
              pattern: invalid),
          throwsFormatException,
          reason: 'pattern=$invalid');
    }
    expect(file.existsSync(), false);
  });

  group('prefix rules', () {
    // Derived like a prefix suggestion from 'git log --oneline': executable
    // and first argument word fixed, tail bounded away from separators.
    const prefixPattern = r'git log[^\n;&|`$()]*';
    const execution = {ProcessPermission.execution};

    test('cover their family, never another executable or permission', () {
      store().remember(pipeline('git log --oneline'), execution,
          CommandApprovalScope.workspace,
          pattern: prefixPattern);
      final effective = store();
      expect(effective.covers(pipeline('git log --oneline'), execution), true);
      expect(
          effective.covers(pipeline('git log -n 5 --stat'), execution), true);
      expect(effective.covers(pipeline('git push'), execution), false);
      expect(effective.covers(pipeline('hg log -n 5'), execution), false,
          reason: 'a different executable is a different command');
      for (final crossing in [
        'git log; rm -rf ~',
        'git log && make',
        'git log | sh',
        'git log\necho extra',
      ]) {
        expect(effective.covers(pipeline(crossing), execution), false,
            reason: crossing);
      }
      expect(
          effective.covers(pipeline('git log --oneline'), permissions), false,
          reason:
              'a prefix rule grants no permission the command did not need');
    });

    test('a revoked prefix rule stops applying without restarting', () {
      store().remember(pipeline('git log --oneline'), execution,
          CommandApprovalScope.workspace,
          pattern: prefixPattern);
      final reader = store();
      expect(reader.covers(pipeline('git log -n 5'), execution), true);
      store().revoke(reader.entries.single['id'] as String);
      expect(store().covers(pipeline('git log -n 5'), execution), false);
      expect(reader.covers(pipeline('git log -n 5'), execution), false);
    });
  });
}
