
/// What a tool actually does — declared, not inferred from its name.
///
/// The permission table answers "may this run?" with one bit per tool, which
/// cannot express the dimensions that decide whether auto-approval is safe.
/// `grep` is a read-only tool that spawns a process with model-controlled
/// arguments; `fetch` is read-only and reaches the network; `git` is
/// "read-only by construction" and still writes repository metadata. Each was
/// classified on one axis and leaked on the others.
///
/// So a tool states the observable facts instead: where it reads and writes,
/// whether it starts a process, and whether it can send data off the machine.
/// The gate then derives its decision from those facts, and
/// [ToolCapabilities.escapesTheSandbox] names the combination that a project
/// sandbox does not contain — the one that must never be silently
/// auto-approved.
library;

import 'process_runner.dart';

/// Where a tool reads from.
enum ReadScope {
  /// Confined to the project root (and never the Tina data tree).
  project,

  /// Anywhere the process can reach, including secrets in `$HOME`.
  host,
}

/// Where a tool writes.
enum WriteScope {
  /// Reads only.
  none,

  /// Confined to the project root by [SandboxedFileSystem].
  project,

  /// Tina's own data for this project (`.tina/`), not the user's source.
  sidecar,

  /// Anywhere the process can reach.
  host,
}

/// Whether a tool starts a process, and who chose the arguments.
enum SpawnScope {
  /// Runs nothing.
  none,

  /// The tool chooses the program AND every argument; model input is passed as
  /// data that cannot be read as an option.
  fixed,

  /// Model input can reach the argument list as a token the program may read as
  /// an OPTION. This is the argv-injection shape (`grep --pre=<cmd>`), and it is
  /// never safe to auto-approve.
  modelArgv,
}

/// Whether a tool can send data off the machine.
enum NetworkScope {
  /// Local only.
  none,

  /// Sends requests to a URL the model chooses.
  egress,
}

/// A tool's declared behaviour. See the library comment.
class ToolCapabilities {
  final ReadScope reads;
  final WriteScope writes;
  final SpawnScope spawns;
  final NetworkScope network;

  /// Why it is acceptable to auto-approve this tool *even though* it escapes
  /// the sandbox, in plain words. Required for any escaping tool that is
  /// allowed by default: the point is that the justification is a field a test
  /// reads, not a sentence in a comment nobody rechecks.
  final String? reviewed;

  const ToolCapabilities({
    this.reads = ReadScope.project,
    this.writes = WriteScope.none,
    this.spawns = SpawnScope.none,
    this.network = NetworkScope.none,
    this.reviewed,
  });

  /// Nothing declared — deliberately the worst case on every axis, so a tool
  /// that says nothing is never auto-approved and shows up in the sweep.
  static const undeclared = ToolCapabilities(
    reads: ReadScope.host,
    writes: WriteScope.host,
    spawns: SpawnScope.modelArgv,
    network: NetworkScope.egress,
  );

  /// True when auto-approving this tool would grant something the project
  /// sandbox does not contain: an uncontained process, egress, or a write
  /// outside the project. A read of the host is included because it is how
  /// `$HOME` secrets reach the model.
  bool get escapesTheSandbox =>
      spawns == SpawnScope.modelArgv ||
      network == NetworkScope.egress ||
      writes == WriteScope.host ||
      reads == ReadScope.host;

  /// The one-line reason this tool may be auto-approved despite escaping, or
  /// null when it does not escape.
  String? get justification => reviewed;
}

/// The declared capabilities for every tool the project composition mounts.
///
/// A single map, checked for completeness against the live registry by the
/// permission sweep: a tool that is mounted but missing here fails the test,
/// so "undeclared" cannot become the quiet default. Moving each declaration
/// onto its own tool class is the follow-up; the invariants are enforced
/// either way, because the sweep reads this and the decision table together.
const Map<String, ToolCapabilities> kToolCapabilities = {
  // --- file tools: everything confined to the project root --------------
  'read': ToolCapabilities(),
  'write': ToolCapabilities(writes: WriteScope.project),
  'edit': ToolCapabilities(writes: WriteScope.project),
  'glob': ToolCapabilities(),
  'ls': ToolCapabilities(),
  'stat': ToolCapabilities(),
  'which': ToolCapabilities(),

  // --- process spawning -------------------------------------------------
  // bash/exec run a model-chosen program or shell line: the uncontained
  // vector, gated in every mode and never pre-approved for a sub-agent.
  'bash': ToolCapabilities(spawns: SpawnScope.modelArgv),
  'exec': ToolCapabilities(spawns: SpawnScope.modelArgv),
  // rg/git are fixed programs whose model input is fenced behind `--`; both
  // take the shared (sandboxed) runner, so the spawn is contained.
  'grep': ToolCapabilities(spawns: SpawnScope.fixed),
  'git': ToolCapabilities(spawns: SpawnScope.fixed),
  'search': ToolCapabilities(spawns: SpawnScope.fixed),

  // --- network ----------------------------------------------------------
  'fetch': ToolCapabilities(network: NetworkScope.egress),
  'web_search': ToolCapabilities(network: NetworkScope.egress),

  // --- host reads -------------------------------------------------------
  // Reports the environment (HOME/PATH/TMPDIR/PUB_CACHE, resolv.conf) to the
  // model. Read-only, but it is a host read, so auto-approval is a decision
  // that has to be stated rather than assumed.
  'execution_info': ToolCapabilities(
    reads: ReadScope.host,
    reviewed: 'reports the OS/toolchain environment the agent needs to run '
        'commands correctly; no file contents, and no write or spawn',
  ),

  // --- project metadata / Tina-owned state ------------------------------
  'write_summary': ToolCapabilities(
    writes: WriteScope.sidecar,
    spawns: SpawnScope.fixed,
    reviewed: 'writes only inside .tina/summaries/<slug>.md, guarded by an '
        'explicit containment check, and shells out to fixed read-only git',
  ),

  // --- orchestration ----------------------------------------------------
  'delegate': ToolCapabilities(),
  'send': ToolCapabilities(),
  'receive': ToolCapabilities(),
  'close': ToolCapabilities(),
  'ask_user': ToolCapabilities(),
  'stop_workflow': ToolCapabilities(),
  'launch_workflow': ToolCapabilities(),
  'broadcast_region': ToolCapabilities(),
  'repo_structure': ToolCapabilities(),
  'list_regions': ToolCapabilities(),
  'query_region': ToolCapabilities(),
  'read_summary': ToolCapabilities(),
  'allocate_region': ToolCapabilities(writes: WriteScope.sidecar),
  'render_image': ToolCapabilities(
    reads: ReadScope.host,
    reviewed: 'reads an image path to paint it into the panel; the bytes are '
        'never returned to the model',
  ),
};

/// The declaration for [tool], or the worst case when nothing is declared.
ToolCapabilities capabilitiesFor(String tool) =>
    kToolCapabilities[tool] ?? ToolCapabilities.undeclared;

/// A tool that starts a process, and so must let the framework hand it the
/// shared runner.
///
/// A tool that constructs its own `IoProcessRunner` silently opts out of the
/// process sandbox — a file-system sandbox cannot confine a subprocess, and
/// this is exactly how `grep` and `git` ran unconfined. Declaring the runner
/// through one interface is what lets the permission sweep check every
/// spawning tool at once instead of a human remembering to look.
abstract interface class SpawnsProcess {
  ProcessRunner get processRunner;
}
