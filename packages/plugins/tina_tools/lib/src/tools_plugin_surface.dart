/// The portable public surface of `tina/tools`: what hosts and tests
/// touch on the plugin, expressed without `dart:io` so one seam serves
/// every view of the plugin —
///
/// - natively, [ToolsPlugin] implements this surface over the real
///   sandbox, process runner and grant stores;
/// - under wasm (and in analyzer configurations where the
///   `dart.library.io` conditional resolves the other way), the app
///   layer's `ToolsPlugin` alias IS this surface, so the members the
///   CI-named tests drive (`sandbox`, `toolList`, `readDirectories`,
///   `writeDirectories`, `processRunner`, `commandApprovals`,
///   `modePolicy`, `mode`, …) resolve identically either way.
///
/// The view interfaces keep their members' meaning faithful to the
/// native classes that implement them (names and semantics match
/// one-for-one); they deliberately expose only what hosts consume.
library;

import 'package:tina_engine_2/tina_engine_2.dart' show AgentPlugin;
import 'package:tina_mode/tina_mode.dart'
    show ModePlugin, PermissionMode;

import 'file_system.dart' show FileSystem;
import 'permissions.dart' show Approver, FileGrants, FileOp;
import 'process_runner.dart'
    show
        ProcessCommandApprover,
        ProcessControl,
        ProcessDirectoryAccess,
        ProcessPermission,
        ProcessRequest,
        RunOutcome;
import 'tool.dart' show Tool;

/// The scope a remembered command approval applies to.
enum CommandApprovalScope { session, workspace, global }

/// The `tina/tools` plugin as hosts see it.
abstract interface class ToolsPluginSurface implements AgentPlugin {
  /// The enforcement boundary every file tool goes through, consulted
  /// per call.
  ToolSandboxView get sandbox;

  /// The session's tools; their schemas are what the loop pins.
  List<Tool> get toolList;

  /// The remembered read-only directories.
  ToolDirectoryGrants get readDirectories;

  /// The remembered writable directories.
  ToolDirectoryGrants get writeDirectories;

  /// The sandboxed process runner the command tools drive.
  ToolProcessRunnerView get processRunner;

  /// The remembered command approvals.
  ToolCommandApprovals get commandApprovals;

  /// The mode policy this plugin owns (and `tina/mode` drives).
  ModePlugin get modePolicy;

  /// The current permission mode.
  PermissionMode get mode;
  set mode(PermissionMode mode);

  /// Whether OS confinement was requested at launch.
  bool get osSandbox;

  /// The session's working directory.
  String get workingDirectory;
}

/// The file sandbox as a host needs it: a filesystem whose every
/// operation passes the boundary, plus the approver an attachment
/// wires, the readable-path predicate the OS plan feeds, the session's
/// file grants and the boundary's current mode.
abstract interface class ToolSandboxView implements FileSystem {
  /// Who answers a file ask; null means asks are refused.
  Approver? get approver;
  set approver(Approver? value);

  /// Whether a read target is readable without an ask; null asks.
  bool Function(String path)? get readablePath;
  set readablePath(bool Function(String path)? value);

  /// Session-scoped file grants ("always" answers).
  FileGrants get grants;

  /// The boundary's current permission mode.
  PermissionMode get mode;
  set mode(PermissionMode mode);

  /// Checks [op] at resolved [path] once; refuses by throwing.
  Future<void> guard(FileOp op, String path);
}

/// Remembered read-only (or, for [ToolsPluginSurface.writeDirectories],
/// writable) directories.
abstract interface class ToolDirectoryGrants {
  /// The granted paths.
  List<String> get paths;

  /// Whether [target] lies in a granted directory.
  bool allows(String target);
}

/// The process runner as a host needs it.
abstract interface class ToolProcessRunnerView {
  /// Runs [request] under the mode table and the sandbox.
  Future<RunOutcome> run(ProcessRequest request, {ProcessControl? control});

  /// The remembered command approvals.
  ToolCommandGrants get grants;

  /// Who answers a command ask; null refuses.
  ProcessCommandApprover? get commandApprover;
  set commandApprover(ProcessCommandApprover? value);

  /// The runner's current permission mode.
  PermissionMode get mode;
  set mode(PermissionMode mode);
}

/// Command grants as a host needs them.
abstract interface class ToolCommandGrants {
  /// Whether nothing is remembered.
  bool get isEmpty;

  /// How many approvals are remembered.
  int get length;

  /// Whether [request] is covered by a remembered approval.
  bool coversRequest(ProcessRequest request,
      {ProcessPermission permission,
      ProcessDirectoryAccess directoryAccess});

  /// Remembers [request] as approved for [permissions].
  void rememberRequest(ProcessRequest request,
      {Set<ProcessPermission> permissions});
}

/// The command approval store as a host needs it.
abstract interface class ToolCommandApprovals {
  /// The remembered approvals, as the settings layer serializes them.
  List<Map<String, Object?>> get entries;

  /// Whether a standing access grant covers [capability] on [target].
  bool coversAccess(String capability, String target);

  /// Forgets the remembered approval with [id].
  void revoke(String id, {String? directory});

  /// The approvals remembered for [scope], as settings overrides.
  Map<String, Object?> settings(CommandApprovalScope scope);

  /// The store file's path, when approvals persist to disk.
  String? get filePath;
}
