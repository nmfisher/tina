import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina_tools/src/access_review.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_tools/src/read_only_commands.dart';

void main() {
  late Directory root, workspace, external, hidden;
  late SandboxPlan plan;
  setUp(() {
    root = Directory(Directory.systemTemp
        .createTempSync('tina-access-review-')
        .resolveSymbolicLinksSync());
    workspace = Directory('${root.path}/workspace')..createSync();
    external = Directory('${root.path}/library')..createSync();
    hidden = Directory('${root.path}/secret')..createSync();
    plan = SandboxPlan(
        workspaceRoot: workspace.path, protectedPaths: [hidden.path]);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('reader summaries include every file operand and omit stdin consumers',
      () {
    final file = File('${external.path}/one')..writeAsStringSync('needle');
    final other = File('${external.path}/two')..writeAsStringSync('needle');
    ProcessRequest request(String program, List<String> args) => (
          command: program,
          arguments: args,
          workingDirectory: workspace.path,
          environment: null,
          stdin: null,
          timeout: null,
        );
    expect(
        verifiedReaderAccesses(request('/bin/cat', [file.path, other.path]))
            .map((access) => access.path),
        [file.path, other.path]);
    expect(
        verifiedReaderAccesses(request('/bin/sh', [
          '-c',
          '/usr/bin/grep needle ${file.path} | /usr/bin/head -30'
        ])).map((access) => access.path),
        [file.path]);
    expect(verifiedReaderAccesses(request('/usr/bin/grep', ['-e', 'word'])),
        isEmpty);
  }, skip: Platform.isWindows);

  test('an offered directory replaced by a symlink cannot be saved', () {
    final details = permissionAccessReview(
        plan: plan,
        cwd: workspace.path,
        verified: [
          PermissionAccess(PermissionAccessOperation.read, external.path,
              PermissionTargetKind.directory)
        ],
        judgment: const PermissionJudgment(null));
    final grant = DirectoryAccessGrant(
        external.path, DirectoryAccess.read, DirectoryGrantScope.workspace);
    expect(validateDirectoryGrants(plan, [grant], details), true);
    external.renameSync('${root.path}/parked');
    Link(external.path).createSync(hidden.path);
    expect(validateDirectoryGrants(plan, [grant], details), false);
  }, skip: Platform.isWindows);

  test(
      'resolve relative inferred paths, preserve operations and exclude unsafe grants',
      () {
    final link = Link('${external.path}/escape')..createSync(hidden.path);
    final result = permissionAccessReview(
        plan: plan,
        cwd: workspace.path,
        verified: [],
        judgment: PermissionJudgment.denied('Review mixed accesses.',
            assessment: PermissionAccessAssessment(
              accesses: [
                const PermissionAccess(PermissionAccessOperation.read,
                    '../library', PermissionTargetKind.directory),
                PermissionAccess(PermissionAccessOperation.delete,
                    '${external.path}/old', PermissionTargetKind.file),
                PermissionAccess(PermissionAccessOperation.write, link.path,
                    PermissionTargetKind.directory),
                const PermissionAccess(PermissionAccessOperation.read, '/',
                    PermissionTargetKind.directory),
                PermissionAccess(PermissionAccessOperation.read,
                    '${external.path}/*.txt', PermissionTargetKind.file),
                PermissionAccess(PermissionAccessOperation.read,
                    '${root.path}/missing/dir', PermissionTargetKind.directory),
              ],
              coverage: PermissionAccessCoverage.partial,
              unresolved: const ['Subprocesses are unresolved.'],
            )));
    final accesses = result['accesses'] as List;
    expect(accesses.first['path'], external.path);
    expect(accesses.every((item) => item['source'] == 'inferred'), true);
    expect(accesses[1]['operation'], 'delete');
    expect(accesses[2]['path'], hidden.path);
    expect(result['directory_accesses'], [
      {'path': external.path, 'access': 'read', 'source': 'inferred'},
      {'path': external.path, 'access': 'write', 'source': 'inferred'},
    ]);
  }, skip: Platform.isWindows);

  test(
      'exact file effects survive timeouts and exclude atomic implementation details',
      () {
    final verified = [
      PermissionAccess(PermissionAccessOperation.write,
          '${external.path}/report', PermissionTargetKind.file)
    ];
    for (final judgment in [
      const PermissionJudgment(null, 'timed out'),
      PermissionJudgment.denied('Review',
          assessment: PermissionAccessAssessment(accesses: [
            PermissionAccess(PermissionAccessOperation.delete,
                '${external.path}/temp', PermissionTargetKind.file),
          ])),
    ]) {
      final result = permissionAccessReview(
          plan: plan,
          cwd: workspace.path,
          verified: verified,
          judgment: judgment,
          complete: true);
      expect((result['accesses'] as List).single,
          {...verified.single.toJson(), 'source': 'verified'});
      expect(result['access_coverage'], 'complete');
    }
  });
}
