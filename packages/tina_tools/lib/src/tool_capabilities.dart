/// What a tool actually does — declared, not inferred from its name.
///
/// One bit per tool cannot express the dimensions that decide whether
/// auto-approval is safe: `grep` is read-only but spawns a process with
/// model-controlled arguments; `fetch` is read-only and reaches the network.
/// So a tool states the observable facts instead — where it reads and writes,
/// whether it starts a process, whether it can send data off the machine —
/// and a gate derives its decision from those facts. [ToolCapabilities.escapesTheSandbox]
/// names the combination a project sandbox does not contain: the one that must
/// never be silently auto-approved.
///
/// Each tool declares its own capabilities as a getter. There is no central
/// name-keyed table: a tool that says nothing falls back to the worst case at
/// the gate, and nothing needs a completeness sweep.
library;

/// Where a tool reads from.
enum ReadScope {
  /// Reads nothing on the machine: a control-plane tool. Having no machine
  /// effect is NOT a reason to auto-approve something — this is the one value
  /// that never derives an `allow`.
  none,

  /// Confined to the project root (and never the Tina data tree).
  project,

  /// Anywhere the process can reach, including secrets in `$HOME`.
  host,
}

/// Where a tool writes.
enum WriteScope {
  /// Reads only.
  none,

  /// Confined to the project root by `SandboxedFileSystem`.
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

  /// Model input can reach the argument list as a token the program may read
  /// as an OPTION. This is the argv-injection shape (`grep --pre=<cmd>`), and
  /// it is never safe to auto-approve.
  modelArgv,
}

/// Whether a tool can set OTHER agents in motion, and how far they may go.
///
/// This is the axis the read-only boundary turns on: a tool with no machine
/// effect of its own can still hand work to an agent that writes. The old
/// boundary was a list of names, and it encoded exactly this distinction
/// without saying so.
enum IndirectWork {
  /// Sets nothing else in motion.
  none,

  /// Runs other agents, but only ever under the read-only profile.
  readOnlyOnly,

  /// Can cause work that writes or runs a model-chosen program.
  anyProfile,
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

  /// See [IndirectWork]. Defaults to [IndirectWork.none] because a tool that
  /// starts other agents has to say so.
  final IndirectWork indirect;

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
    this.indirect = IndirectWork.none,
    this.reviewed,
  });

  /// Nothing declared — deliberately the worst case on every axis, so a tool
  /// that says nothing is never auto-approved and shows up at the gate.
  static const undeclared = ToolCapabilities(
    reads: ReadScope.host,
    writes: WriteScope.host,
    spawns: SpawnScope.modelArgv,
    network: NetworkScope.egress,
    indirect: IndirectWork.anyProfile,
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

  /// True when the tool does anything to the machine at all. A control-plane
  /// tool does not, and is therefore left out of a derived decision table
  /// entirely: "touches nothing" is not the same as "safe to run unattended" —
  /// starting an autonomous run touches nothing and is still the user's call.
  bool get touchesTheMachine =>
      reads != ReadScope.none ||
      writes != WriteScope.none ||
      spawns != SpawnScope.none ||
      network != NetworkScope.none;

  /// The one-line reason this tool may be auto-approved despite escaping, or
  /// null when it does not escape.
  String? get justification => reviewed;
}
