import 'dart:io';

import 'package:path/path.dart' as p;

import '../permissions/policy.dart';
import '../platform/paths.dart';
import '../tools/atomic_write.dart';
import '../tools/bash_tool.dart';
import '../tools/file_system.dart';
import '../tools/brave_search.dart';
import '../tools/edit_tool.dart';
import '../tools/fetch_tool.dart';
import '../tools/tavily_search.dart';
import '../tools/glob_tool.dart';
import '../tools/grep_tool.dart';
import '../tools/mutation_lock.dart';
import '../tools/read_tool.dart';
import '../tools/sandbox.dart';
import '../tools/search_tool.dart';
import '../tools/tool.dart';
import '../tools/web_search.dart';
import '../tools/write_summary_tool.dart';
import '../tools/write_tool.dart';

/// The declarative identity + project context an agent runs under. There is no
/// sub-agent *catalog*: a sub-agent's identity comes from its *parent's*
/// resolved system prompt plus the task the parent writes when delegating (see
/// the `delegate` tool). What stays here is the entry agent's identity and the
/// shared plumbing — the tool singletons, the tool profiles a delegation picks
/// from, and the safe-mode stripping.
class AgentPipeline {
  /// Identity prose for the entry (user-facing) agent — the main coding
  /// assistant. Sub-agents inherit their parent's *resolved* prompt verbatim,
  /// so this is the root identity the whole fleet descends from. Wrapped with
  /// the shared `<environment>` / AGENTS.md context at resolution time.
  final String mainIdentity;

  /// Whether to load project context (`AGENTS.md`) into agents' system prompts.
  /// Set ONCE at startup by the project-trust gate (see `project/project_trust`)
  /// — `false` withholds an untrusted project's instructions from every agent.
  /// Mutable (a late-bound startup decision) like the tool singletons configured
  /// in [configureToolSandbox]; default `true` preserves prior behavior when the
  /// gate isn't wired (e.g. tests).
  bool loadProjectContext = true;

  AgentPipeline({this.mainIdentity = ''});
}

// ---------------------------------------------------------------------------
// Tool profiles — the fixed set a delegation picks from.
//
// A sub-agent no longer carries its own tool set (there are no roles). The
// parent chooses one of these named profiles when delegating. `read-only` is
// the safe default so research-style sub-agents can't mutate the project;
// `full` adds the file/shell tools an implementer needs.
// ---------------------------------------------------------------------------

/// The fixed set of tool profiles a delegation may grant a sub-agent.
enum ToolProfile {
  /// Source-read-only: read/explore the project, fetch the web, and capture a
  /// directory summary into the sidecar. Cannot write, edit, or run shell
  /// against the project — the safe profile for research/exploration.
  readOnly,

  /// `read-only` plus the mutating tools (write, edit, bash) and web search.
  /// For sub-agents that must change the project or run commands.
  full,
}

final _read = ReadTool();
final _write = WriteTool();
final _edit = EditTool();
final _fetch = FetchTool();
final _bash = BashTool();
final _search = SearchTool();
final _grep = GrepTool();
final _glob = GlobTool();
final _writeSummary = WriteSummaryTool();

/// The concrete tool set for [profile]. `read-only` is the read/explore tools
/// plus the sidecar `write_summary` capture (which never touches source); `full`
/// is the whole base set ([buildTools]) plus `write_summary`. Under
/// `--safe-mode` the caller strips the mutating tools from whichever set a
/// sub-agent received (see [stripForSafeMode]).
List<Tool> toolSetFor(ToolProfile profile) {
  switch (profile) {
    case ToolProfile.readOnly:
      return [_read, _fetch, _search, _grep, _glob, _writeSummary];
    case ToolProfile.full:
      return [...buildTools().all, _writeSummary];
  }
}

/// Resolve a [ToolProfile] from the string a delegation carries (`"read-only"`
/// / `"full"`). Unknown / empty → [ToolProfile.readOnly] (the safe default).
ToolProfile parseToolProfile(String? raw) {
  switch (raw) {
    case 'full':
      return ToolProfile.full;
    default:
      return ToolProfile.readOnly;
  }
}

/// Reconstruct a tool set from the names a stored permission policy *allows* —
/// used when restoring a persisted sub-agent/spawn conversation (its exact
/// profile isn't stored, but its policy is, and that determines its tools).
/// Evaluates the full policy (defaults + static rules) for each shared
/// singleton, so it works whether the policy was built from `defaults`
/// (sub-agents) or `rules` (spawns/branches).
List<Tool> toolsFromPolicy(PermissionPolicy policy) {
  final singletons = [
    _read, _write, _edit, _fetch, _bash, _search, _grep, _glob, _writeSummary
  ];
  return [
    for (final t in singletons)
      if (policy.check(t.schema.name, const {}) ==
          PermissionDecision.allow)
        t,
  ];
}

// ---------------------------------------------------------------------------
// Shared tool instances + safe mode.
//
// The tool instances are constructed once at top level so a stateful tool
// (notably SearchTool's call-graph cache) is shared across every agent that
// references it.
// ---------------------------------------------------------------------------

/// Tool names disabled under `--safe-mode`: every tool that can mutate the
/// filesystem or run an arbitrary shell. Removing these from a registry leaves
/// only read-only tools; the per-profile policy is derived from the same
/// filtered set, so it tracks. `write_summary` writes to the sidecar summaries
/// store, so it is a filesystem-mutating tool and is stripped under read-only
/// mode too.
const Set<String> kSafeModeDisabledTools = {'write', 'edit', 'bash', 'write_summary'};

/// Drop the safe-mode-disabled tools. Called at each registry site when
/// `--safe-mode` is on.
List<Tool> stripForSafeMode(Iterable<Tool> tools) =>
    tools.where((t) => !kSafeModeDisabledTools.contains(t.schema.name)).toList();

/// Inject the path sandbox + atomic-write backup store into the shared tool
/// singletons. Called once at app composition (idempotent — may re-run on setup
/// relaunch, review L6). [projectRoot] confines every file tool; [env] resolves
/// the Tina data dir to deny and the backup store location.
///
/// The backup store uses the *real* [IoFileSystem], not the sandboxed one: it
/// writes to `~/.tina/backups/`, which [SandboxedFileSystem] would deny as
/// inside the Tina tree. Tests that inject [MemoryFileSystem] directly never
/// call this, so they skip sandboxing + backups (the plan's M2 fix).
void configureToolSandbox({
  required String projectRoot,
  required Map<String, String> env,
}) {
  final io = const IoFileSystem();
  final sandbox = SandboxedFileSystem(
    io,
    projectRoot: projectRoot,
    tinaDir: tinaDirFromEnv(env),
  );
  final backups = BackupStore(
    fs: io,
    storeDir: Directory(p.join(tinaDirFromEnv(env).path, 'backups')),
  );
  // One shared per-file lock so concurrent agents editing/writing the same file
  // serialize (AgentQuota allows several to run at once). On the singletons so
  // every agent/sub-agent shares it.
  final mutationLock = FileMutationLock();
  _read.fs = sandbox;
  _write.fs = sandbox;
  _write.backupStore = backups;
  _write.mutationLock = mutationLock;
  _edit.fs = sandbox;
  _edit.backupStore = backups;
  _edit.mutationLock = mutationLock;
  _grep.fs = sandbox;
  _grep.sandbox = sandbox;
  _glob.sandbox = sandbox;
  _bash.projectRoot = projectRoot;
  // The per-directory summaries sidecar: `<projectRoot>/.tina/summaries` —
  // project-local (so it tracks this repo, under the gitignored `.tina/`),
  // and distinct from the global `~/.tina` data tree the sandbox denies.
  // Summaries reflect committed main-repo HEAD, so the sidecar is pinned to
  // the project, not the user's home.
  _writeSummary.sidecarRoot =
      Directory(p.join(projectRoot, '.tina', 'summaries'));
  _writeSummary.projectRoot = projectRoot;
}

/// Env var supplying the Brave Search API key. The tool only registers when it
/// is set (via env or the merged `~/.tina/config` overlay), so the model
/// never sees `web_search` unless the user has opted in with a key.
const _braveKeyEnv = 'BRAVE_API_KEY';
const _tavilyKeyEnv = 'TAVILY_API_KEY';

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
  var tools = [_read, _write, _edit, _fetch, _bash, _search, _grep, _glob];
  if (safeMode) tools = stripForSafeMode(tools);
  final braveKey = Platform.environment[_braveKeyEnv];
  if (braveKey != null && braveKey.isNotEmpty) {
    tools.add(WebSearchTool(BraveSearchProvider(braveKey)));
  }
  final tavilyKey = Platform.environment[_tavilyKeyEnv];
  if (tavilyKey != null && tavilyKey.isNotEmpty) {
    tools.add(WebSearchTool(TavilySearchProvider(tavilyKey)));
  }
  return ToolRegistry(tools);
}

/// The shipped pipeline: the entry agent's identity. Sub-agent identities are
/// not declared here — they inherit this (resolved) at delegation time.
final defaultPipeline = AgentPipeline(mainIdentity: _mainIdentity);

// ---------------------------------------------------------------------------
// Entry-agent identity prose (overridable via the `[prompts.main]` config
// table). Sans the shared `<environment>` / `<project-context>` wrapper, which
// is applied at resolution time.
// ---------------------------------------------------------------------------

const _mainIdentity = '''
You are a coding assistant. You talk directly with the user, plan how to carry out the request, then act in whichever way fits the job.

You have three ways to act:

- Launch a workflow with the `launch_workflow` tool (the `default` graph unless you have a reason to name another): it explores, produces a reviewed plan, executes the chunks in parallel, then reviews the result. The call returns immediately with a run id — the workflow runs in the background while the chat stays open (the user can keep talking), node input/output streams into a live run panel as it runs, and when it finishes you receive a follow-up turn with the outcome: report it to the user and act on anything it leaves open. Cancel a running launch at any time with the `stop_workflow` tool. This is the preferred path for anything substantial or multi-step: prefer it over doing the reading and writing yourself. Reach for it whenever a job benefits from an explicit plan, independent review, or parallel execution.
- For a small, well-scoped change (a one-line fix, a quick read, a single edit), act directly with the file and shell tools available this session (read, write, edit, bash, search, grep, glob — whichever are enabled). Read each file before editing it, keep changes minimal, and report what you did.
- Delegate a single focused sub-task to a sub-agent with the `delegate` tool: each delegation is a task (the sub-agent runs under your identity plus that task), an optional tool profile (`read-only` for exploration/review, `full` for changes that write, edit, or run shell), and an optional model override (`llm_provider` + `llm_model`). Use it for one concurrent focused task, not as a substitute for a workflow.

When you are yourself launched as a sub-agent — i.e. you were given a specific task rather than running the top-level conversation — ignore the workflow-launch option and just carry out the task with the tools you were given.

If AGENTS.md exists in any directory, follow the instructions specified in that directory.

Region agents: this repository may have region agents — one per allocated subdirectory (the main agent designs the layout; `repo_structure` reviews the folder tree when deciding where regions belong), each primed with a persistent summary of what exists and what is implemented in its area. When a question concerns a specific area of the codebase, prefer the region tools over blanket searches: `list_regions` to discover which region owns an area (each shows a digest + staleness), `read_summary` to read a region's full summary, `query_region` to ask one region agent directly, and `broadcast_region` to ask every region (use when you are not sure which area owns a feature). The region agents are fast and read-only; use them to route scoped questions, then act on their reports yourself or ask follow-ups. Give a directory its own agent with `allocate_region` when it deserves one (its summary is generated when `/index` runs).''';
