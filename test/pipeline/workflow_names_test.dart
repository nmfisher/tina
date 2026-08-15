import 'dart:io';

import 'package:test/test.dart';

import '../../lib/pipeline/pipeline_runner.dart';
import '../../lib/pipeline/workflow_names.dart';

/// Workflow names are filesystem paths by construction (`<dir>/<name>.dot`),
/// so an unsafe name is a directory escape. These tests pin the guard at both
/// layers: the pure predicate ([isSafeWorkflowName]/[normalizeWorkflowName],
/// used by the editor's save) and the runner's read seam ([PipelineRunner.readWorkflow]).
void main() {
  group('isSafeWorkflowName', () {
    test('accepts ordinary names, trimming whitespace', () {
      expect(isSafeWorkflowName('default'), isTrue);
      expect(isSafeWorkflowName('my-workflow_2'), isTrue);
      expect(isSafeWorkflowName('  spaced  '), isTrue);
    });

    test('rejects empty and path-escaping names', () {
      expect(isSafeWorkflowName(''), isFalse);
      expect(isSafeWorkflowName('   '), isFalse);
      expect(isSafeWorkflowName('..'), isFalse);
      expect(isSafeWorkflowName('.'), isFalse);
      expect(isSafeWorkflowName('../evil'), isFalse);
      expect(isSafeWorkflowName('a/../b'), isFalse);
      expect(isSafeWorkflowName('sub/evil'), isFalse);
      expect(isSafeWorkflowName(r'sub\evil'), isFalse);
    });

    test('rejects control characters', () {
      expect(isSafeWorkflowName('a\nb'), isFalse);
      expect(isSafeWorkflowName('a\x00b'), isFalse);
      expect(isSafeWorkflowName('a\x7fb'), isFalse);
    });
  });

  group('normalizeWorkflowName', () {
    test('trims and drops a typed .dot suffix', () {
      expect(normalizeWorkflowName('  foo '), 'foo');
      expect(normalizeWorkflowName('foo.dot'), 'foo');
      expect(normalizeWorkflowName('foo.DOT'), 'foo');
    });

    test('null for unsafe input', () {
      expect(normalizeWorkflowName('../evil'), isNull);
      expect(normalizeWorkflowName('a/b'), isNull);
      expect(normalizeWorkflowName(''), isNull);
      expect(normalizeWorkflowName('   '), isNull);
      expect(normalizeWorkflowName('.dot'), isNull); // trims to empty
    });
  });

  group('PipelineRunner.readWorkflow name guard', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_wf_names_');
      File('${tmp.path}${Platform.pathSeparator}default.dot')
          .writeAsStringSync('digraph default {}');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a safe name reads the file', () async {
      final source = await PipelineRunner.readWorkflow(tmp, 'default');
      expect(source, contains('digraph default'));
    });

    test('a missing workflow reports not-found', () {
      expect(() => PipelineRunner.readWorkflow(tmp, 'nope'),
          throwsA(isA<FileSystemException>()
              .having((e) => e.message, 'message', contains('not found'))));
    });

    test('an escaping name is rejected before touching the filesystem', () {
      for (final evil in ['../default', 'sub/default', r'..\default', '..']) {
        expect(() => PipelineRunner.readWorkflow(tmp, evil),
            throwsA(isA<FileSystemException>().having(
                (e) => e.message, 'message', contains('workflow names'))),
            reason: evil);
      }
    });
  });
}
