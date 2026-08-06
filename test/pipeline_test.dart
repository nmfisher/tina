import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../lib/pipeline/file_run_store.dart';
import '../lib/pipeline/tina_codergen_backend.dart';

void main() {
  group('TinaCodergenBackend.parseVerdict', () {
    test('extracts a trailing VERDICT label, lowercased', () {
      expect(TinaCodergenBackend.parseVerdict('review text\n\nVERDICT: approve'),
          'approve');
      expect(TinaCodergenBackend.parseVerdict('notes\nverdict: Revise'),
          'revise');
    });

    test('ignores a VERDICT that is not on the last non-empty line', () {
      // A mid-text mention shouldn't route.
      expect(
          TinaCodergenBackend.parseVerdict('VERDICT: approve\nmore thoughts\n'),
          isNull);
    });

    test('returns null when there is no verdict line', () {
      expect(TinaCodergenBackend.parseVerdict('just a normal response'), isNull);
    });
  });

  group('FileRunStore', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('tina_run_'));

    tearDown(() => tmp.deleteSync(recursive: true));

    test('writes manifest, per-node files, and a checkpoint', () async {
      final runDir = Directory(p.join(tmp.path, 'run1'));
      final store = FileRunStore(runDir);

      await store.init(runId: 'run1', workflowName: 'wf', goal: 'g', input: 'in');
      await store.writeNode(
        nodeId: 'plan',
        outcome: const Outcome.success(),
        prompt: 'do it',
        response: 'a plan',
      );
      await store.writeCheckpoint(
          currentNode: 'plan', completedNodes: ['plan'], context: Context());
      await store.finalize(status: StageStatus.success);

      expect(File(p.join(runDir.path, 'manifest.json')).existsSync(), isTrue);
      expect(File(p.join(runDir.path, 'plan', 'prompt.md')).readAsStringSync(),
          'do it');
      expect(File(p.join(runDir.path, 'plan', 'response.md')).readAsStringSync(),
          'a plan');
      expect(File(p.join(runDir.path, 'plan', 'status.json')).existsSync(),
          isTrue);
      expect(File(p.join(runDir.path, 'checkpoint.json')).existsSync(), isTrue);
    });
  });
}
