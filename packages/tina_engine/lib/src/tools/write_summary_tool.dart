import 'dart:io';

import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import 'file_system.dart';
import 'tool.dart';

/// Writes one directory summary file into the sidecar summaries repo
/// (`.tina/summaries/`), the per-directory summary store that tracks the main
/// repo from outside its tracked tree.
///
/// This is the capture seam for the summarizer sub-agent: rather than parse a
/// merged orchestrator answer, each summarizer writes its own summary through
/// this constrained tool. The tool owns the sidecar layout — the child only
/// supplies `dir` (which codebase directory it summarized) and `content` (the
/// prose). It is **read-only w.r.t. the main repo**: it can touch only the
/// sidecar path, never source files.
///
/// The markdown header is stamped by this tool — not the child — so it always
/// reflects the real main-repo `HEAD` + the dir's tree hash at execute time.
/// That makes the tracking header unforgeable: a summarizer cannot claim a
/// commit or tree it didn't summarize against.
///
/// Like the other shared tool singletons ([WriteTool], [ReadTool]), the sidecar
/// root is injected at composition (a mutable [sidecarRoot] field, set once);
/// tests construct the tool with a temp directory directly.
class WriteSummaryTool implements Tool {
  WriteSummaryTool({this.sidecarRoot, this.projectRoot});

  /// The sidecar summaries repo root (`<projectRoot>/.tina/summaries`).
  /// Injected at app composition (see `configureToolSandbox`); a test passes a
  /// temp directory via the constructor. Must be set before [execute] runs
  /// against the live path.
  Directory? sidecarRoot;

  /// The main repo root, so the header's `git rev-parse` runs against the
  /// right repo regardless of the process cwd (tests + concurrent runs change
  /// cwd). Injected at composition alongside [sidecarRoot].
  String? projectRoot;

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'write_summary',
        description: 'Write the prose summary for one codebase directory into '
            'the sidecar summaries store. Pass the directory you summarized '
            '(e.g. "lib", "packages/tina_engine/lib") and the markdown '
            'content. The tracking header (commit + tree hash) is stamped for '
            'you — do not include it. Read-only with respect to the source repo.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'dir': {
              'type': 'string',
              'description': 'The summarized directory, repo-relative '
                  '(e.g. "lib", "packages/tina_index/lib").',
            },
            'content': {
              'type': 'string',
              'description': 'The full markdown summary to write.',
            },
          },
          'required': ['dir', 'content'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final dir = input['dir'] as String?;
    final content = input['content'] as String?;
    if (dir == null || dir.isEmpty) {
      return ToolResult.error('dir is required');
    }
    if (content == null) {
      return ToolResult.error('content is required');
    }
    final root = sidecarRoot;
    if (root == null) {
      return ToolResult.error(
          'write_summary is not configured (no sidecar root)');
    }

    final slug = _slug(dir);
    final dest = p.join(root.path, '$slug.md');
    final rootAbs = p.canonicalize(root.path);
    final destAbs = p.canonicalize(dest);
    // Containment check: the slug must resolve *under* the sidecar root. A
    // crafted dir that escapes via ".." or absolute paths is rejected before
    // any write — the tool can only touch the sidecar.
    if (!_isUnder(destAbs, rootAbs)) {
      return ToolResult.error(
          'write_summary: directory "$dir" resolves outside the sidecar store');
    }

    // Stamp the tracking header from the real main-repo HEAD + the dir's tree
    // hash, so the header is unforgeable by the summarizer child. Run git with
    // `-C <projectRoot>` so this is independent of the process cwd (tests and
    // concurrent runs change cwd).
    final String commit;
    final String tree;
    try {
      commit = _git(projectRoot, ['rev-parse', 'HEAD']);
      tree = _git(projectRoot, ['rev-parse', 'HEAD:$dir']);
    } on ProcessException catch (e) {
      return ToolResult.error(
          'write_summary: could not read git HEAD/tree for "$dir": '
          '${e.message}');
    } on _GitFailure catch (e) {
      return ToolResult.error(
          'write_summary: git failed for "$dir": ${e.message}');
    }

    final generated = DateTime.now().toUtc().toIso8601String();
    final header = '<!-- tina-summary dir="$dir" commit="$commit" '
        'tree="$tree" generated="$generated" -->\n';
    final body = content.endsWith('\n') ? content : '$content\n';

    await atomicWriteFile(const IoFileSystem(), dest, '$header\n$body');

    return ToolResult('wrote summary for $dir '
        '(commit ${commit.substring(0, 7)}, tree ${tree.substring(0, 7)})');
  }
}

/// Run `git -C [workingDir]` with [args] and return trimmed stdout. When
/// [workingDir] is null, runs in the process cwd (kept for completeness; the
/// live path always sets it via [WriteSummaryTool.projectRoot]). Throws
/// [_GitFailure] on a non-zero exit (with the trimmed stderr) and lets
/// [ProcessException] propagate (git not found / not a repo at all).
String _git(String? workingDir, List<String> args) {
  final gitArgs = workingDir == null
      ? args
      : ['-C', workingDir, ...args];
  final result = Process.runSync('git', gitArgs, runInShell: false);
  if (result.exitCode != 0) {
    throw _GitFailure(
        (result.stderr as String).trim().isEmpty
            ? 'git ${args.join(" ")} exited ${result.exitCode}'
            : (result.stderr as String).trim());
  }
  return (result.stdout as String).trim();
}

class _GitFailure {
  final String message;
  const _GitFailure(this.message);
}

/// Slug a repo-relative dir path into a flat filename: `lib` → `lib`,
/// `packages/tina_index/lib` → `packages__tina_index__lib`. Path
/// separators become `__` (two underscores so a single-`_` segment name like
/// `tina_index` is never ambiguous with a path boundary).
String _slug(String dir) {
  final normalized = p.normalize(dir).replaceAll(RegExp(r'/+'), '__');
  return normalized;
}

/// True when [child] is [parent] or lies under it, using normalized paths with
/// a trailing separator so `/foo` is not falsely "under" `/fo`. Mirrors the
/// helper in `sandbox.dart` (kept local so this tool has no dependency on the
/// sandbox's process-canonicalization path — the sidecar root is already
/// absolute and canonical by construction).
bool _isUnder(String child, String parent) {
  final c = _withTrailing(p.normalize(child));
  final par = _withTrailing(p.normalize(parent));
  return c == par || c.startsWith(par);
}

String _withTrailing(String path) =>
    path.endsWith(p.separator) ? path : '$path${p.separator}';
