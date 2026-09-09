import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../permissions/policy.dart';
import '../platform/paths.dart';
import '../tools/atomic_write.dart';
import '../tools/bash_tool.dart';
import '../tools/file_system.dart';
import '../tools/process_runner.dart';
import '../tools/brave_search.dart';
import '../tools/edit_tool.dart';
import '../tools/fetch_tool.dart';
import '../tools/tavily_search.dart';
import '../tools/glob_tool.dart';
import '../tools/grep_tool.dart';
import '../tools/git_tool.dart';
import '../tools/ls_tool.dart';
import '../tools/mutation_lock.dart';
import '../tools/read_tool.dart';
import '../tools/sandbox.dart';
import '../tools/sandbox_runner.dart';
import '../tools/search_tool.dart';
import '../tools/stat_tool.dart';
import '../tools/tool.dart';
import '../tools/which_tool.dart';
import '../tools/web_search.dart';
import '../tools/write_summary_tool.dart';
import '../tools/write_tool.dart';

import 'tool_profile.dart';

final _log = Logger('tina.sandbox');

/// Project-owned tools and write coordination. Main agents, delegates and
/// same-project background runs borrow this scope. Creating another scope never
/// changes these tool instances or their sandbox configuration.
class ProjectToolScope {
  final String projectRoot;
  final Map<String, String> environment;
  final FileMutationLock mutationLock = FileMutationLock();

  ProjectToolScope({
    required String projectRoot,
    required Map<String, String> env,
    bool sandboxEnabled = true,
    bool sandboxNet = false,
    bool sandboxReadOnly = false,
  }) : this._(
          projectRoot: projectRoot,
          env: env,
          confineFiles: true,
          sandboxEnabled: sandboxEnabled,
          sandboxNet: sandboxNet,
          sandboxReadOnly: sandboxReadOnly,
        );

  /// Standalone tool assembly for engine consumers without application setup.
  /// Production composition uses the confined constructor above.
  ProjectToolScope.unconfined({String? projectRoot, Map<String, String>? env})
      : this._(
          projectRoot: projectRoot ?? Directory.current.path,
          env: env ?? Platform.environment,
          confineFiles: false,
          sandboxEnabled: false,
          sandboxNet: false,
          sandboxReadOnly: false,
        );

  ProjectToolScope._({
    required String projectRoot,
    required Map<String, String> env,
    required bool confineFiles,
    required bool sandboxEnabled,
    required bool sandboxNet,
    required bool sandboxReadOnly,
  })  : projectRoot = p.normalize(p.absolute(projectRoot)),
        environment = Map.unmodifiable(env) {
    _search = SearchTool(repoRoot: this.projectRoot);
    _which = WhichTool(environment: environment);
    _git = GitTool(workingDirectory: this.projectRoot);
    _write.mutationLock = mutationLock;
    _edit.mutationLock = mutationLock;
    if (!confineFiles) return;
    _read.projectRoot = this.projectRoot;
    _write.projectRoot = this.projectRoot;
    _edit.projectRoot = this.projectRoot;
    _grep.projectRoot = this.projectRoot;
    _glob.projectRoot = this.projectRoot;
    _ls.projectRoot = this.projectRoot;
    _stat.projectRoot = this.projectRoot;

    final io = const IoFileSystem();
    final sandbox = SandboxedFileSystem(
      io,
      projectRoot: this.projectRoot,
      tinaDir: tinaDirFromEnv(env),
    );
    final backups = BackupStore(
      fs: io,
      storeDir: Directory(p.join(tinaDirFromEnv(env).path, 'backups')),
    );
    // One shared per-file lock so concurrent agents editing/writing the same file
    // serialize (AgentQuota allows several to run at once). Owned by this scope so
    // every agent/sub-agent shares it.
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
    _bash.projectRoot = this.projectRoot;
    // Confine bash subprocess writes to the project root + temp via
    // sandbox-exec (macOS) or bwrap (Linux) — the structural guard against a
    // destructive command reaching outside the project. Pass-through with a
    // one-time warning where no backend exists. Extra write-roots come from the
    // TINA_SANDBOX_ALLOW env var (colon-separated), then explicit runtime
    // approvals. The runner owns their access policy for all borrowers of this
    // scope; an allow-once invocation uses a separate snapshot.
    if (sandboxEnabled) {
      final extra = (env['TINA_SANDBOX_ALLOW'] ?? '')
          .split(':')
          .where((s) => s.isNotEmpty)
          .toList();
      final runner = SandboxedProcessRunner(
        projectRoot: this.projectRoot,
        extraAllowPaths: extra,
        sandboxNet: sandboxNet,
        sandboxReadOnly: sandboxReadOnly,
      );
      _bash.processRunner = runner;
      // Startup diagnostic: name the active backend (or the pass-through
      // reason) once per scope, so a session's log says how bash is boxed.
      _log.info('bash sandbox: ${runner.backendDescription}');
    } else {
      _bash.processRunner = const IoProcessRunner();
      _log.info(
          'bash sandbox: pass-through (explicitly disabled via --no-sandbox)');
    }
    // The per-directory summaries sidecar: `<projectRoot>/.tina/summaries` —
    // project-local (so it tracks this repo, under the gitignored `.tina/`),
    // and distinct from the global `~/.tina` data tree the sandbox denies.
    // Summaries reflect committed main-repo HEAD, so the sidecar is pinned to
    // the project, not the user's home.
    _writeSummary.sidecarRoot =
        Directory(p.join(this.projectRoot, '.tina', 'summaries'));
    _writeSummary.projectRoot = this.projectRoot;
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
  /// `--prompt` path (main as a direct worker), by [ToolProfile.full], and by the
  /// node run (attractor seam).
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
