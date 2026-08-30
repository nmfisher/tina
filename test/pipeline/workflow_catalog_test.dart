import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../lib/pipeline/default_workflow.dart';
import '../../lib/pipeline/pipeline_runner.dart';
import '../../lib/pipeline/workflow_catalog.dart';
import '../../lib/pipeline/workflow_names.dart';

/// The WorkflowCatalog seam (plugin_architecture.md §4.3): name → DOT-source
/// resolution in one place, backed by the on-disk *.dot scan plus registered
/// programmatic entries (the built-in seed graph is one).
///
/// These tests pin the refactor's contract — byte-identical user-visible
/// behavior:
///   * a FILE always wins over a same-named entry (default.dot overrides the
///     built-in seed; the file is the override mechanism, never shadowed);
///   * the default-graph SELECTION stays file-based only
///     (resolveDefaultWorkflowName's contract, verbatim);
///   * [WorkflowCatalog.list] is the on-disk scan — identical to what
///     PipelineRunner.listWorkflows returned before the refactor, with and
///     without the seed file present;
///   * unsafe names are rejected with the same error wording.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('tina_wf_catalog_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  WorkflowCatalog standardCatalog() =>
      WorkflowCatalog.standard(workflowsDir: tmp);

  void writeWorkflow(String name, String source) =>
      File(p.join(tmp.path, '$name.dot')).writeAsStringSync(source);

  group('list (on-disk scan — identical to the pre-refactor listWorkflows)', () {
    test('missing dir -> empty, even with entries registered', () {
      final catalog = standardCatalog();
      expect(catalog.list(), isEmpty);
    });

    test('lists *.dot files sorted, extensionless, no dirs or non-dot files',
        () {
      writeWorkflow('zeta', 'digraph Z {}');
      writeWorkflow('alpha', 'digraph A {}');
      writeWorkflow('mid', 'digraph M {}');
      File(p.join(tmp.path, 'notes.txt')).writeAsStringSync('not a workflow');
      Directory(p.join(tmp.path, 'sub.dot')).createSync(); // a dir, not a file

      expect(standardCatalog().list(), ['alpha', 'mid', 'zeta']);
    });

    test('seed file present: exactly the on-disk set (no built-in ghost)',
        () async {
      final seeded = await seedDefaultWorkflow(tmp);
      expect(seeded, isTrue);
      writeWorkflow('custom', 'digraph C {}');

      expect(standardCatalog().list(), ['custom', 'default']);
    });

    test('seed file deleted: empty list (the built-in entry is not listed)',
        () async {
      expect(await seedDefaultWorkflow(tmp), isTrue);
      File(p.join(tmp.path, 'default.dot')).deleteSync();

      // Deleting the file returns to today's empty-list state — the seed
      // message tells users deleting default.dot removes the default
      // workflow, so listing the built-in entry here would be a visible
      // change.
      expect(standardCatalog().list(), isEmpty);
    });

    test('entry-less catalog (PipelineRunner.listWorkflows) matches exactly',
        () {
      writeWorkflow('b', 'digraph B {}');
      writeWorkflow('a', 'digraph A {}');

      expect(PipelineRunner.listWorkflows(tmp),
          WorkflowCatalog(workflowsDir: tmp).list());
      expect(PipelineRunner.listWorkflows(tmp), ['a', 'b']);
    });
  });

  group('read (file wins over entries; rejections unchanged)', () {
    test('missing dir + registered entry: not found (today\'s behavior)', () {
      final catalog = WorkflowCatalog.standard(
          workflowsDir: Directory(p.join(tmp.path, 'nope')));
      expect(() => catalog.read('default'),
          throwsA(isA<FileSystemException>().having(
              (e) => e.message, 'message', contains('workflow not found'))));
    });

    test('unsafe names are rejected before touching the filesystem', () async {
      final catalog = standardCatalog();
      for (final evil in ['../default', 'sub/default', r'..\default', '..']) {
        await expectLater(catalog.read(evil),
            throwsA(isA<FileSystemException>().having(
                (e) => e.message, 'message', contains(nameRejection))),
            reason: evil);
      }
      // Identical wording to the pre-refactor read seam.
      expect(nameRejection, contains('workflow names'));
    });

    test('a file shadows a same-named entry (default.dot overrides the seed)',
        () async {
      writeWorkflow('default', 'digraph USER { user_edit [shape=box] }');
      final source = await standardCatalog().read('default');
      expect(source, contains('USER'));
      expect(source, isNot(contains('review')));
    });

    test('the built-in seed entry resolves when its file is absent', () async {
      expect(await seedDefaultWorkflow(tmp), isTrue);
      File(p.join(tmp.path, 'default.dot')).deleteSync();

      final source = await standardCatalog().read('default');
      expect(source, kDefaultWorkflowDotSource);
    });

    test('an arbitrary custom .dot file is launchable by name', () async {
      writeWorkflow('my-flow_2', 'digraph MyFlow { a -> b }');
      expect(await standardCatalog().read('my-flow_2'), contains('MyFlow'));
    });

    test('unknown name: same not-found error as before', () {
      expect(
          () => standardCatalog().read('nope'),
          throwsA(isA<FileSystemException>()
              .having((e) => e.message, 'message', contains('not found'))));
    });

    test('custom entries layered over the standard catalog resolve too', () {
      final catalog = WorkflowCatalog.standard(
          workflowsDir: tmp, entries: {'extra': 'digraph EXTRA {}'});
      catalog.register('late', 'digraph LATE {}');
      expect(catalog.read('extra'), completion(contains('EXTRA')));
      expect(catalog.read('late'), completion(contains('LATE')));
    });

    test('the entry-less static readWorkflow keeps its exact semantics',
        () async {
      writeWorkflow('default', 'digraph D {}');
      expect(await PipelineRunner.readWorkflow(tmp, 'default'),
          'digraph D {}');
    });
  });

  group('default-graph selection (file-based only — unchanged contract)', () {
    test('default.dot present -> "default" (file wins over the seed entry)',
        () async {
      expect(await seedDefaultWorkflow(tmp), isTrue);
      expect(standardCatalog().defaultWorkflowName(), 'default');
    });

    test('no default.dot file -> null, even though the seed entry exists', () {
      // The built-in entry must never become the default name: the default
      // graph is the FILE (the override mechanism first-run seeding writes).
      expect(standardCatalog().defaultWorkflowName(), isNull);
    });

    test('configured name honored when its file exists', () async {
      writeWorkflow('review-loop', 'digraph R {}');
      expect(standardCatalog().defaultWorkflowName(configured: 'review-loop'),
          'review-loop');
    });

    test('configured name without a file -> null (not the seed entry)',
        () async {
      expect(await seedDefaultWorkflow(tmp), isTrue);
      File(p.join(tmp.path, 'default.dot')).deleteSync();
      expect(standardCatalog().defaultWorkflowName(configured: 'review-loop'),
          isNull);
    });

    test('configured "none" disables even when default.dot exists', () async {
      expect(await seedDefaultWorkflow(tmp), isTrue);
      expect(standardCatalog().defaultWorkflowName(configured: 'none'), isNull);
    });

    test('missing workflows dir -> null', () {
      final catalog = WorkflowCatalog.standard(
          workflowsDir: Directory(p.join(tmp.path, 'nope')));
      expect(catalog.defaultWorkflowName(), isNull);
    });

    test('matches resolveDefaultWorkflowName exactly in every state', () async {
      // File present, file absent, dir absent — selection must be byte
      // identical to the pre-refactor resolver.
      expect(standardCatalog().defaultWorkflowName(configured: 'none'), isNull);
      expect(await seedDefaultWorkflow(tmp), isTrue);
      expect(
          standardCatalog().defaultWorkflowName(),
          resolveDefaultWorkflowName(
              configured: null, workflowsDir: tmp));
      File(p.join(tmp.path, 'default.dot')).deleteSync();
      expect(
          standardCatalog().defaultWorkflowName(),
          resolveDefaultWorkflowName(
              configured: null, workflowsDir: tmp));
    });
  });
}
