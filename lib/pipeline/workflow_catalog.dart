// The workflow graph catalog: name → DOT-source resolution in one place.
//
// This is the graph registry of the extension-seam refactor
// (docs/proposals/plugin_architecture.md §4.3): `launch_workflow`, the
// `/workflow` command, and the runner's read seam all resolve workflow names
// through this type instead of each reaching for the filesystem. The built-in
// seed graph (kDefaultWorkflowDotSource) is registered here as the catalog's
// `default` entry — one owner for that constant — while first-run seeding
// still writes default.dot to disk (bin/tina.dart): the FILE is the override
// mechanism, and the catalog never shadows it.
//
// Resolution semantics (pinned by test/pipeline/workflow_catalog_test.dart):
//
//   * A workflow FILE on disk always wins over a registered entry of the same
//     name — a user's default.dot overrides the built-in seed entry, and
//     arbitrary .dot files launch by filename exactly as before.
//   * The default graph SELECTION (which name the agent launches by default,
//     what `/workflow list` marks `← default`) stays file-based only:
//     [defaultWorkflowName] delegates to [resolveDefaultWorkflowName], whose
//     "conventional default.dot when present" contract is untouched. A
//     registered entry never becomes the default name.
//   * [list] is the on-disk scan — byte-identical to what
//     `PipelineRunner.listWorkflows` has always returned, including the
//     empty-dir state when the user deletes default.dot. Entries are a
//     resolution fallback, not list items.
//   * Names resolve through [isSafeWorkflowName]; its rejections (and error
//     wording) are unchanged.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'default_workflow.dart';
import 'workflow_names.dart';

/// Owns workflow-name → DOT-source resolution over one workflows dir.
///
/// Backed by two sources, in precedence order:
///
/// 1. the workflows-dir scan — every `*.dot` file under [workflowsDir] (the
///    launchable set [list] has always returned); and
/// 2. programmatic entries registered with [register] (the built-in seed
///    graph arrives this way via [WorkflowCatalog.standard]).
///
/// Files shadow same-named entries. Entries answer only while the workflows
/// dir exists — a missing dir is today's "no workflows" state (nothing
/// listed, every read fails) and first-run seeding creates the dir before any
/// consumer resolves a name.
class WorkflowCatalog {
  /// The name the built-in seed graph ([kDefaultWorkflowDotSource]) is
  /// registered under — the launch name of the default graph.
  static const String defaultEntryName = 'default';

  /// The workflows dir this catalog scans.
  final Directory workflowsDir;

  final Map<String, String> _entries;

  /// A catalog over [workflowsDir] with no built-in entries: purely the
  /// on-disk scan. (`PipelineRunner.listWorkflows`/`readWorkflow` are thin
  /// delegates over exactly this.)
  WorkflowCatalog(
      {required this.workflowsDir, Map<String, String> entries = const {}})
      : _entries = Map.of(entries);

  /// The app's catalog: the on-disk scan plus the built-in seed graph
  /// registered under [defaultEntryName], with any [entries] layered on top
  /// (a same-named file still wins over every entry).
  factory WorkflowCatalog.standard(
      {required Directory workflowsDir,
      Map<String, String> entries = const {}}) {
    return WorkflowCatalog(workflowsDir: workflowsDir, entries: {
      ...entries,
      defaultEntryName: kDefaultWorkflowDotSource,
    });
  }

  /// Register a programmatic workflow entry. Registration never overrides a
  /// file on disk — files win by construction ([read]).
  void register(String name, String dotSource) => _entries[name] = dotSource;

  /// Every launchable workflow name — the `*.dot` files in the workflows dir,
  /// extensionless, sorted. Empty when the dir is absent or holds no
  /// workflows. Registered entries are deliberately NOT listed: the list is
  /// the on-disk scan (the seeded default.dot is the user-visible artifact,
  /// and deleting it must return to the empty list, not expose the built-in
  /// entry).
  List<String> list() {
    if (!workflowsDir.existsSync()) return const [];
    return workflowsDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dot'))
        .map((f) => p.basenameWithoutExtension(f.path))
        .toList()
      ..sort();
  }

  /// Resolve [name] to its DOT source: the on-disk `<name>.dot` when present,
  /// else a registered entry (only while the workflows dir exists — see the
  /// class doc).
  ///
  /// Throws the same errors the read seam has always thrown: a
  /// [FileSystemException] carrying [nameRejection] for a name that fails
  /// [isSafeWorkflowName], and one carrying `'workflow not found'` when
  /// neither a file nor an entry answers the name.
  Future<String> read(String name) async {
    if (!isSafeWorkflowName(name)) {
      throw FileSystemException(
          nameRejection, p.join(workflowsDir.path, '<name>.dot'));
    }
    final file = File(p.join(workflowsDir.path, '$name.dot'));
    if (await file.exists()) return file.readAsString();
    if (workflowsDir.existsSync()) {
      final entry = _entries[name];
      if (entry != null) return entry;
    }
    throw FileSystemException('workflow not found', file.path);
  }

  /// The name of the conventional default graph — the one the main agent
  /// launches via `launch_workflow` and `/workflow list` marks with
  /// `← default`.
  ///
  /// FILE-based only (delegates to [resolveDefaultWorkflowName]): a
  /// registered entry never becomes the default name, so this is
  /// `default.dot` (or the `[default] workflow` config name) when that file
  /// exists, and null otherwise — the documented override story, unchanged.
  String? defaultWorkflowName({String? configured}) =>
      resolveDefaultWorkflowName(
          configured: configured, workflowsDir: workflowsDir);
}
