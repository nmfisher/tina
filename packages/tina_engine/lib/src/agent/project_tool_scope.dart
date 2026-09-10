import 'dart:io';

import 'package:path/path.dart' as p;

import '../permissions/policy.dart';
import '../tools/bash_tool.dart';
import '../tools/brave_search.dart';
import '../tools/edit_tool.dart';
import '../tools/fetch_tool.dart';
import '../tools/tavily_search.dart';
import '../tools/glob_tool.dart';
import '../tools/grep_tool.dart';
import '../tools/git_tool.dart';
import '../tools/ls_tool.dart';
import '../tools/mutation_lock.dart';
import '../tools/project_capabilities.dart';
import '../tools/read_tool.dart';
import '../tools/search_tool.dart';
import '../tools/stat_tool.dart';
import '../tools/tool.dart';
import '../tools/which_tool.dart';
import '../tools/web_search.dart';
import '../tools/write_summary_tool.dart';
import '../tools/write_tool.dart';

import 'tool_profile.dart';

/// Project-owned tools and write coordination. Main agents, delegates and
/// same-project background runs borrow this scope. Creating another scope never
/// changes these tool instances or their sandbox configuration.
class ProjectToolScope {
  final String projectRoot;
  final Map<String, String> environment;
  final FileMutationLock mutationLock;

  ProjectToolScope({
    required String projectRoot,
    required Map<String, String> env,
    bool sandboxEnabled = true,
    bool sandboxNet = false,
    bool sandboxReadOnly = false,
  }) : this._(
          capabilities: ProjectCapabilities.build(
            projectRoot: projectRoot,
            env: env,
            confineFiles: true,
            sandboxEnabled: sandboxEnabled,
            sandboxNet: sandboxNet,
            sandboxReadOnly: sandboxReadOnly,
          ),
        );

  /// Standalone tool assembly for engine consumers without application setup.
  /// Production composition uses the confined constructor above.
  ProjectToolScope.unconfined({String? projectRoot, Map<String, String>? env})
      : this._(
          capabilities: ProjectCapabilities.build(
            projectRoot: projectRoot ?? Directory.current.path,
            env: env ?? Platform.environment,
            confineFiles: false,
            sandboxEnabled: false,
            sandboxNet: false,
            sandboxReadOnly: false,
          ),
        );

  ProjectToolScope._({required ProjectCapabilities capabilities})
      : projectRoot = capabilities.projectRoot,
        environment = capabilities.environment,
        mutationLock = capabilities.mutationLock {
    _search = SearchTool(repoRoot: projectRoot);
    _which = WhichTool(environment: environment);
    _git = GitTool(workingDirectory: projectRoot);
    _write.mutationLock = mutationLock;
    _edit.mutationLock = mutationLock;
    if (!capabilities.confineFiles) return;
    _read.projectRoot = projectRoot;
    _write.projectRoot = projectRoot;
    _edit.projectRoot = projectRoot;
    _grep.projectRoot = projectRoot;
    _glob.projectRoot = projectRoot;
    _ls.projectRoot = projectRoot;
    _stat.projectRoot = projectRoot;

    final sandbox = capabilities.fileSystem!;
    final backups = capabilities.backups!;
    _read.fs = sandbox;
    _write.fs = sandbox;
    _write.backupStore = backups;
    _edit.fs = sandbox;
    _edit.backupStore = backups;
    _grep.fs = sandbox;
    _grep.sandbox = sandbox;
    _glob.sandbox = sandbox;
    _ls.sandbox = sandbox;
    _stat.sandbox = sandbox;
    _bash.projectRoot = projectRoot;
    _bash.processRunner = capabilities.processRunner;
    // The per-directory summaries sidecar: `<projectRoot>/.tina/summaries` —
    // project-local (so it tracks this repo, under the gitignored `.tina/`),
    // and distinct from the global `~/.tina` data tree the sandbox denies.
    // Summaries reflect committed main-repo HEAD, so the sidecar is pinned to
    // the project, not the user's home.
    _writeSummary.sidecarRoot =
        Directory(p.join(projectRoot, '.tina', 'summaries'));
    _writeSummary.projectRoot = projectRoot;
  }

  final _read = ReadTool();
  final _write = WriteTool();
  final _edit = EditTool();
  final _fetch = FetchTool();
  final _bash = BashTool();
  late final SearchTool _search;
  final _grep = GrepTool();
  final _glob = GlobTool();
  final _ls = LsTool();
  final _stat = StatTool();
  late final WhichTool _which;
  late final GitTool _git;
  final _writeSummary = WriteSummaryTool();

  /// The concrete tool set for [profile]. `read-only` is the read/explore tools
  /// plus the sidecar `write_summary` capture (which never touches source); `full`
  /// is the whole base set ([buildTools]) plus `write_summary`. Under
  /// `--safe-mode` the caller strips the mutating tools from whichever set a
  /// sub-agent received (see [stripForSafeMode]).
  List<Tool> toolSetFor(ToolProfile profile) {
    switch (profile) {
      case ToolProfile.readOnly:
        return [
          _read,
          _fetch,
          _search,
          _grep,
          _glob,
          _ls,
          _stat,
          _which,
          _git,
          _writeSummary
        ];
      case ToolProfile.full:
        return [...buildTools().all, _writeSummary];
    }
  }

  /// Reconstruct a tool set from the names a stored permission policy *allows* —
  /// used when restoring a persisted sub-agent/spawn conversation (its exact
  /// profile isn't stored, but its policy is, and that determines its tools).
  /// Evaluates the full policy (defaults + static rules) for each project-scoped
  /// tool, so it works whether the policy was built from `defaults`
  /// (sub-agents) or `rules` (spawns/branches).
  List<Tool> toolsFromPolicy(PermissionPolicy policy) {
    final candidates = [
      _read,
      _write,
      _edit,
      _fetch,
      _bash,
      _search,
      _grep,
      _glob,
      _ls,
      _stat,
      _which,
      _git,
      _writeSummary
    ];
    return [
      for (final t in candidates)
        if (policy.check(t.schema.name, const {}) == PermissionDecision.allow)
          t,
    ];
  }

  /// The full base tool set — read/write/edit/bash/search/grep/glob — plus
  /// `web_search` when a search API key is configured. Used by the headless
  /// `--prompt` path (main as a direct worker), by [ToolProfile.full], and by
  /// the node run (attractor seam).
  ///
  /// Both Brave and Tavily register under the same `web_search` tool name; a
  /// user only needs one index. [ToolRegistry] is deliberately last-wins, so
  /// when *both* keys are set, Tavily answers `web_search`. The model doesn't
  /// care which backend responds.
  ToolRegistry buildTools({bool safeMode = false}) {
    var tools = [
      _read,
      _write,
      _edit,
      _fetch,
      _bash,
      _search,
      _grep,
      _glob,
      _ls,
      _stat,
      _which,
      _git,
    ];
    if (safeMode) tools = stripForSafeMode(tools);
    final braveKey = environment[_braveKeyEnv];
    if (braveKey != null && braveKey.isNotEmpty) {
      tools.add(WebSearchTool(BraveSearchProvider(braveKey)));
    }
    final tavilyKey = environment[_tavilyKeyEnv];
    if (tavilyKey != null && tavilyKey.isNotEmpty) {
      tools.add(WebSearchTool(TavilySearchProvider(tavilyKey)));
    }
    return ToolRegistry(tools);
  }
}

const _braveKeyEnv = 'BRAVE_API_KEY';
const _tavilyKeyEnv = 'TAVILY_API_KEY';
