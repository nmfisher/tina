import 'dart:convert';
import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as p;

/// A filesystem-backed [RunStore] at a given run directory:
/// ```
/// <runDir>/
///   manifest.json
///   checkpoint.json
///   <nodeId>/{status.json, prompt.md, response.md}
/// ```
///
/// Writes are best-effort and single-threaded (the engine traverses one node
/// at a time), so plain [File.writeAsString] is sufficient for the audit
/// trail. The manifest is rewritten (temp + rename) on finalize.
class FileRunStore implements RunStore {
  final Directory runDir;

  FileRunStore(this.runDir);

  File get _manifest => File(p.join(runDir.path, 'manifest.json'));

  @override
  Future<void> init({
    required String runId,
    required String workflowName,
    String? goal,
    String? input,
  }) async {
    await runDir.create(recursive: true);
    await _writeJson(_manifest, {
      'run_id': runId,
      'workflow': workflowName,
      'goal': goal ?? '',
      'input': input ?? '',
      'started_at': DateTime.now().toUtc().toIso8601String(),
      'status': 'running',
    });
  }

  @override
  Future<void> writeNode({
    required String nodeId,
    required Outcome outcome,
    required String prompt,
    required String response,
  }) async {
    final nodeDir = Directory(p.join(runDir.path, nodeId));
    await nodeDir.create(recursive: true);
    await File(p.join(nodeDir.path, 'prompt.md')).writeAsString(prompt);
    await File(p.join(nodeDir.path, 'response.md')).writeAsString(response);
    await _writeJson(File(p.join(nodeDir.path, 'status.json')),
        {'node': nodeId, ...outcome.toJson()});
  }

  @override
  Future<void> writeCheckpoint({
    required String currentNode,
    required Iterable<String> completedNodes,
    required Context context,
  }) async {
    await _writeJson(File(p.join(runDir.path, 'checkpoint.json')), {
      'current_node': currentNode,
      'completed_nodes': completedNodes.toList(),
      'context': context.snapshot(),
    });
  }

  @override
  Future<void> finalize({required StageStatus status, String? failureReason}) async {
    // Rewrite the manifest with the final status, atomically.
    final tmp = File('${_manifest.path}.tmp');
    var existing = <String, dynamic>{};
    try {
      existing =
          jsonDecode(await _manifest.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      // No manifest yet (shouldn't happen) — start empty.
    }
    existing['status'] = status.wire;
    existing['finished_at'] = DateTime.now().toUtc().toIso8601String();
    if (failureReason != null) existing['failure_reason'] = failureReason;
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(existing));
    await tmp.rename(_manifest.path);
  }

  Future<void> _writeJson(File f, Map<String, dynamic> json) =>
      f.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
}
