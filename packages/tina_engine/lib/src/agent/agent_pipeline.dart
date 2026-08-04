import 'dart:io';

import 'package:path/path.dart' as p;

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
import 'workflow.dart';

/// The *declaration* of one pipeline stage: its prompt identity, its tools, and
/// its capabilities (delegation, model tier, step ceiling). Pure data. An
/// [Agent] (the runtime executor) is built from it each time the stage runs;
/// the same role can run many times as separate `Agent`s.
///
/// A role's [tools] is the single pivot for the prompt↔tool↔permission
/// couplings: whatever the [promptIdentity] names, [tools] must provide, and the
/// scheduler derives the role's allowed permissions from it (plus `delegate`
/// when [canDelegate]). Because [tools] holds symbolic references to shared
/// [Tool] instances — not names — a missing tool is a compile error, never a
/// runtime lookup.
class AgentRole implements DelegationTarget {
  @override
  final String name;

  @override
  final String description;

  /// Identity prose — what this stage is for and which tools to reach for.
  /// Pairs with [tools]: whatever the prompt names, [tools] must provide.
  /// Wrapped with the shared `<environment>` / AGENTS.md context at resolution
  /// time (see `resolveSystemPrompt`).
  final String promptIdentity;

  /// The static tools this stage runs — symbolic references to the shared tool
  /// instances, not names. Drives three things with one value:
  ///   1. the tool set the stage receives (the scheduler wraps this directly),
  ///   2. the stage's allowed permissions (`_policyFor` allows exactly these),
  ///   3. compile-time checking that every tool is real.
  final Set<Tool> tools;

  /// Attach a context-bound `delegate` tool (built per-run with a scheduler
  /// handle) so this stage can spawn sub-agents. True for main and the
  /// orchestrator. The delegate tool isn't a static instance (it needs a
  /// context), so it's a flag, not a member of [tools].
  final bool canDelegate;

  /// Capability class (e.g. "heavy", "light") mapped to a concrete
  /// `"provider/model"` via the scheduler's tier map. null inherits the
  /// spawning conversation's resolved model.
  final String? modelTier;

  /// Step ceiling, or null for the scheduler default.
  final int? maxSteps;

  const AgentRole({
    required this.name,
    required this.description,
    this.promptIdentity = '',
    this.tools = const <Tool>{},
    this.canDelegate = false,
    this.modelTier,
    this.maxSteps,
  });
}

/// The declarative pipeline as a *value*: [mainRole] + [roles] + [workflows].
/// Not built or validated — every cross-reference (a role's [AgentRole.tools], a
/// [WorkflowStage.target]) is a symbolic, compile-checked reference. The one
/// lookup that stays a string is [target]: the delegate tool receives an agent
/// name from the LLM at runtime and resolves it here (null for unknown, surfaced
/// by the delegate tool as an error).
class AgentPipeline {
  /// The entry stage — talks to the user. Never delegated to, so it is excluded
  /// from [delegateTargets] without a flag, and [role] ('main') returns null.
  final AgentRole mainRole;

  /// Sub-agent stages — all delegatable.
  final List<AgentRole> roles;

  /// Declared flows — also delegatable.
  final List<Workflow> workflows;

  /// Whether to load project context (`AGENTS.md`) into agents' system prompts.
  /// Set ONCE at startup by the project-trust gate (see `project/project_trust`)
  /// — `false` withholds an untrusted project's instructions from every agent.
  /// Mutable (a late-bound startup decision) like the tool singletons configured
  /// in [configureToolSandbox]; default `true` preserves prior behavior when the
  /// gate isn't wired (e.g. tests).
  bool loadProjectContext = true;

  AgentPipeline({
    required this.mainRole,
    this.roles = const [],
    this.workflows = const [],
  });

  /// Look up a sub-agent stage by name (not main).
  AgentRole? role(String name) =>
      roles.cast<AgentRole?>().firstWhere((r) => r?.name == name, orElse: () => null);

  /// Look up a workflow by name.
  Workflow? workflow(String name) => workflows
      .cast<Workflow?>()
      .firstWhere((w) => w?.name == name, orElse: () => null);

  /// Runtime resolution of a name the LLM emitted to the delegate tool. Returns
  /// null for an unknown name (the delegate tool surfaces that as an error).
  DelegationTarget? target(String name) {
    final r = role(name);
    if (r != null) return r;
    return workflow(name);
  }

  /// The delegate picker's source of truth: sub-agents + workflows (never main).
  /// The delegate tool's schema enum is generated from this, so it can't drift.
  List<DelegationTarget> get delegateTargets => [...roles, ...workflows];
}

// ---------------------------------------------------------------------------
// Shared tool instances + the default pipeline.
//
// The tool instances are constructed once at top level so a stateful tool
// (notably SearchTool's call-graph cache) is shared across every role that
// references it — exactly as today, where the scheduler filtered one base set.
// ---------------------------------------------------------------------------

final _read = ReadTool();
final _write = WriteTool();
final _edit = EditTool();
final _fetch = FetchTool();
final _bash = BashTool();
final _search = SearchTool();
final _grep = GrepTool();
final _glob = GlobTool();
final _writeSummary = WriteSummaryTool();

/// Tool names disabled under `--safe-mode`: every tool that can mutate the
/// filesystem or run an arbitrary shell. Removing these from a registry leaves
/// only read-only tools; the per-role policy is derived from the same filtered
/// set, so it tracks. `write_summary` writes to the sidecar summaries store, so
/// it is a filesystem-mutating tool and is stripped under read-only mode too.
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
/// `web_search` when a search API key is configured. The *only* caller is the
/// headless `--prompt` path, which runs main as a direct worker. Interactive
/// main gets none of these (it delegates), and sub-agents bring their own
/// subset via their [AgentRole.tools].
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

final _main = AgentRole(
  name: 'main',
  description: 'User-facing coding assistant; plans and delegates to specialists.',
  promptIdentity: _mainIdentity,
  // No file tools: interactive main delegates. buildAgent enforces this
  // structurally (interactive main gets only delegate + channels).
  canDelegate: true,
);

final _research = AgentRole(
  name: 'research',
  description: 'Read-only codebase exploration: finding call sites, summarizing '
      'subsystems, or answering "where/what" questions.',
  promptIdentity: _researchIdentity,
  tools: {_read, _search, _grep, _glob},
  modelTier: 'heavy',
);

final _implementer = AgentRole(
  name: 'implementer',
  description: 'Implements a specific change.',
  promptIdentity: _implementerIdentity,
  tools: {_read, _write, _edit, _bash},
  modelTier: 'heavy',
);

final _verifier = AgentRole(
  name: 'verifier',
  description: 'Reviews a change for correctness.',
  promptIdentity: _verifierIdentity,
  tools: {_read, _grep, _glob},
  modelTier: 'heavy',
);

final _tester = AgentRole(
  name: 'tester',
  description: 'Writes and runs tests.',
  promptIdentity: _testerIdentity,
  tools: {_read, _bash, _grep},
  modelTier: 'light',
);

final _orchestrator = AgentRole(
  name: 'orchestrator',
  description: 'Reviews the repo, delegates a scout per major subsystem, and '
      'returns a concise overview.',
  promptIdentity: _orchestratorIdentity,
  tools: {_read, _search, _grep, _glob},
  canDelegate: true, // fans out via delegate
  modelTier: 'heavy',
);

final _scout = AgentRole(
  name: 'scout',
  description: 'Summarizes one codebase segment, read-only.',
  promptIdentity: _scoutIdentity,
  tools: {_read, _search, _grep, _glob},
  modelTier: 'light',
);

/// The per-directory summarizer for the sidecar summaries store. Read-only
/// against the source repo (read/search/grep/glob) plus `write_summary`, which
/// can touch only the sidecar path. Because the scheduler derives each role's
/// permissions from its `tools` (the `_policyFor` rule), adding `write_summary`
/// here permits it automatically — **no manual policy widening** — and the role
/// gets no `write`/`edit`/`bash`, so it cannot modify source files. The
/// `write_summary` tool stamps the tracking header itself, so the model can't
/// forge a commit/tree hash.
final _summarizer = AgentRole(
  name: 'summarizer',
  description: 'Reads one directory and writes its prose summary to the '
      'sidecar store via write_summary.',
  promptIdentity: _summarizerIdentity,
  tools: {_read, _search, _grep, _glob, _writeSummary},
  modelTier: 'light',
);

final _qa = Workflow(
  name: 'qa',
  description: 'implement → verify → test, halting on a failed review.',
  stages: [
    WorkflowStage(target: _implementer, task: 'Implement the following.'),
    WorkflowStage(
        target: _verifier,
        task: 'Review the implementation for correctness and edge cases.',
        haltOnFail: true),
    WorkflowStage(
        target: _tester,
        task: 'Write and run tests for the implementation, addressing any '
            'review notes.'),
  ],
);

/// The shipped pipeline. Roles are declared as locals so workflows can reference
/// them symbolically (see `_qa`'s stage targets) — a typo there is a compile
/// error, not a startup crash.
final defaultPipeline = AgentPipeline(
  mainRole: _main,
  roles: [
    _research,
    _implementer,
    _verifier,
    _tester,
    _orchestrator,
    _scout,
    _summarizer,
  ],
  workflows: [_qa],
);

// ---------------------------------------------------------------------------
// Role identity prose (the role-specific guidance a user overrides via the
// `[prompts.<role>]` config table). Sans the shared `<environment>` /
// `<project-context>` wrapper, which is applied at resolution time.
// ---------------------------------------------------------------------------

const _mainIdentity = '''
You are a coding assistant. You talk directly with the user, but you do not read, write or edit files directly, or execute any scripts.

Instead, you will communicate with a single orchestrator agent. The orchestrator (and the sub-agents it orchestrates) will have the ability to read/write/edit/execute files.

Your primary role is planning how to execute the user's instructions (and for how to verify that the user's instructions have been successfully followed) at a high level of abstraction.

You then pass your abstract plan & instruction to the orchestrator.

If AGENTS.md exists in any directory, follow the instructions specified in that directory.''';

const _orchestratorIdentity = '''
You are a coding assistant, but you do not talk directly to the user.

You will receive a high-level plan and objective from an agent that itself is talking with a user.

Your task is to orchestrate a fleet of sub-agents to plan and achieve this objective.

First, launch between 1 and 3 "reading" sub-agents for reading files for the current project. You are free to decide how to allocate responsibility between these agents for project files/directories.

Ask these sub-agents to summarize the files relevant to the high-level plan.

Next, formulate a specific plan for implementing the high-level plan. This plan should not refer to sub-agents yet, but should refer to specific files that you intend on editing.

Write your plan to a .plans folder in the project folder.

Then, launch a "plan review" agent and pass the path to the plan file. The plan review agent will edit this file directly.

Once the plan review agent confirms it has completed its review, clear the context for the plan review agent and ask it to review the plan again.

Once the plan review agent again confirms it has completed its review, launch between 1 and 3 "writing" sub-agents for writing files for the current project.

Where possible, update the plan to split up specific tasks that can be launched in parallel between different writing sub-agents.

Then, coordinate the writing sub-agents to execute the plan.

At each step of the above, tell the user's main agent what you are doing. If something is not clear, ask the main agent. If the main agent itself is not clear, tell it to ask the user.''';

const _researchIdentity = '''
You are a coding assistant whose sole task is to find files that are relevant to a user's request. You are only responsible for a specific area of the codebase; you can investigate that area, but never go outside that area.

Your tools are read, search, grep, and glob. Use them to find call sites, trace data flow, and summarize subsystems. You cannot write, edit, or run shell commands, so confine your answer to what these tools surface. Be concise and cite file paths.''';

const _implementerIdentity = '''
You are an implementation agent inside tina, a terminal coding assistant. You are handed a specific change to make; do exactly that and stop.

Your tools are read, write, edit, and bash. Investigate before changing anything. Prefer `edit` for surgical changes and `write` only for new files or full rewrites. When editing, read the file first so your `oldString` matches exactly. Keep changes minimal and focused; use bash to build or run things when it helps you verify your work.''';

const _verifierIdentity = '''
You are a code-review agent inside tina, a terminal coding assistant. You are given a change to review for correctness, edge cases, and regressions.

Your tools are read, grep, and glob — read-only. Read the changed code and its surrounding context, check callers and tests, and report concrete problems with file paths and line references. If you cannot verify something, say so rather than guessing. Output a concise list of findings, or say it looks good.''';

const _testerIdentity = '''
You are a test-writing agent inside tina, a terminal coding assistant. You are given an implementation to cover with tests, plus any review notes.

Your tools are read, bash, and grep. Read the implementation, follow the existing test conventions, then write and run tests. Use bash to run the test suite and report the outcome. Focus on meaningful coverage of behavior and edge cases, not on line counts.''';

const _scoutIdentity = '''
You are a scout agent inside tina, a terminal coding assistant. You are assigned one segment of the repository; summarize what it does for an orchestrator assembling a repo-wide overview.

Your tools are read, search, grep, and glob — read-only. Survey the segment's entry points, its responsibilities, and its key files. Report a concise summary: what the segment does, the important types/functions, and how it fits with the rest. Cite concrete file paths. Do not speculate beyond what you can read.''';

const _summarizerIdentity = '''
You are a summarizer agent inside tina, a terminal coding assistant. You are assigned one directory of the repository and must write a prose summary of it into the sidecar summaries store.

Your read tools are read, search, grep, and glob — read-only against the source. Use them to survey the directory's entry points, responsibilities, key types/functions, and how it fits with the rest of the repo. Cite concrete file paths. Do not speculate beyond what you can read.

When you are done, write your summary by calling `write_summary(dir, content)`, where `dir` is the directory you were assigned (repo-relative, e.g. "lib") and `content` is the markdown prose. Do NOT include a tracking header in the content — `write_summary` stamps the commit and tree hash itself. You cannot write, edit, or run shell commands against the source repo; the only write you can make is the summary file via `write_summary`.''';

