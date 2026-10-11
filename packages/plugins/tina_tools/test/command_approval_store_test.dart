import 'dart:io';
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
  test('malformed persisted data cannot authorize a request', () {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{broken');
    expect(store().covers(request(), permissions), false);
  });
}
