/// The cross-leg test fixture: a tools plugin shaped exactly like the
/// wasm leg's `PortableToolsPlugin` (tina_wasm), living in a runnable
/// package so every catalog-consumer suite can hold a wasm-shaped
/// payload in plain `dart test` — the gap that hid the live cast
/// failure (commit 28: every test environment held a native
/// `ToolsPlugin` where production-wasm holds the portable one).
///
/// Implements exactly the portable plugin's surfaces —
/// [ModePolicySource], [ToolSessionSource], [ToolsPluginSurface] — and
/// deliberately NOT the native `ToolsPlugin`: the leg split is an
/// owner ruling. If `PortableToolsPlugin`'s surface set changes, this
/// stub must change with it (the wasm suite pins the pair).
library;

import 'package:tina_engine_2/tina_engine_2.dart' show AgentPlugin;
import 'package:tina_mode/tina_mode.dart'
    show ModePlugin, ModePolicySource, PermissionMode;

import '../../portable_tools.dart' as tt;

/// The wasm-shaped tools plugin for cross-leg tests: `tina/tools` as
/// the wasm leg sees it. A real [ModePlugin] carries the mode state so
/// mode-policy consumers exercise real delegation; everything else is
/// the portable no-op shape.
final class WasmShapedToolsPlugin extends AgentPlugin
    implements ModePolicySource, tt.ToolSessionSource, tt.ToolsPluginSurface {
  WasmShapedToolsPlugin({PermissionMode mode = PermissionMode.approve})
      : modePolicy = ModePlugin(mode: mode);

  @override
  String get id => 'tina/tools';

  @override
  int get order => 10;

  @override
  final ModePlugin modePolicy;

  @override
  PermissionMode get mode => modePolicy.mode;

  @override
  set mode(PermissionMode value) => modePolicy.mode = value;

  @override
  tt.ToolSandboxView get sandbox => _NoSandbox();

  @override
  List<tt.Tool> get toolList => const [];

  @override
  tt.ToolDirectoryGrants get readDirectories => const _NoDirectoryGrants();

  @override
  tt.ToolDirectoryGrants get writeDirectories => const _NoDirectoryGrants();

  @override
  tt.ToolProcessRunnerView get processRunner => const _NoRunner();

  @override
  tt.ToolCommandApprovals get commandApprovals => const _NoCommandApprovals();

  @override
  bool get osSandbox => false;

  @override
  String get workingDirectory => '.';
}

/// The no-op sandbox: the portable boundary's shape without a WASI
/// filesystem — reads refuse, writes refuse, the guard refuses.
final class _NoSandbox implements tt.ToolSandboxView {
  final tt.FileGrants _grants = tt.FileGrants();

  @override
  tt.Approver? get approver => null;

  @override
  set approver(tt.Approver? value) {}

  @override
  bool Function(String path)? get readablePath => null;

  @override
  set readablePath(bool Function(String path)? value) {}

  @override
  tt.FileGrants get grants => _grants;

  @override
  PermissionMode get mode => PermissionMode.approve;

  @override
  set mode(PermissionMode value) {}

  @override
  Future<void> guard(tt.FileOp op, String path) async =>
      throw tt.ToolFsException('no filesystem in the wasm-shaped stub', path);

  @override
  Future<bool> fileExists(String path) async => false;

  @override
  Future<bool> directoryExists(String path) async => false;

  @override
  Future<List<int>> readFileBytes(String path) async =>
      throw tt.ToolFsException('no filesystem in the wasm-shaped stub', path);

  @override
  Future<String> readFileString(String path) async =>
      throw tt.ToolFsException('no filesystem in the wasm-shaped stub', path);

  @override
  Future<void> writeFile(String path, String content) async =>
      throw tt.ToolFsException('no filesystem in the wasm-shaped stub', path);

  @override
  Future<void> createDirectory(String path, {bool recursive = false}) async {}

  @override
  Future<void> rename(String from, String to) async {}

  @override
  Future<void> delete(String path) async {}

  @override
  Future<String> createTempFile({required String near}) async =>
      throw tt.ToolFsException('no filesystem in the wasm-shaped stub', near);
}

/// No remembered directories: the portable slice keeps none.
final class _NoDirectoryGrants implements tt.ToolDirectoryGrants {
  const _NoDirectoryGrants();

  @override
  List<String> get paths => const [];

  @override
  bool allows(String target) => false;
}

/// The no-op process runner: no spawns under the wasm-shaped stub. The
/// answer-cache seams exist (they are surface members) and stay inert.
final class _NoRunner implements tt.ToolProcessRunnerView {
  const _NoRunner();

  @override
  Future<tt.RunOutcome> run(tt.ProcessRequest request,
          {tt.ProcessControl? control}) =>
      throw UnsupportedError(
        'the process tools are a native-only slice; no runner exists '
        'in the wasm-shaped stub',
      );

  @override
  tt.ToolCommandGrants get grants => const _NoCommandGrants();

  @override
  tt.ProcessCommandApprover? get commandApprover => null;

  @override
  set commandApprover(tt.ProcessCommandApprover? value) {}

  @override
  PermissionMode get mode => PermissionMode.yolo;

  @override
  set mode(PermissionMode value) {}

  @override
  String? Function(String program, List<String> arguments)?
      get readOnlySearchResolver => null;

  @override
  set readOnlySearchResolver(
      String? Function(String program, List<String> arguments)? value) {}

  @override
  void Function(String program, List<String> arguments, List<String> files)?
      get onReadOnlySearchCompleted => null;

  @override
  set onReadOnlySearchCompleted(
      void Function(
              String program, List<String> arguments, List<String> files)?
          value) {}
}

final class _NoCommandGrants implements tt.ToolCommandGrants {
  const _NoCommandGrants();

  @override
  bool get isEmpty => true;

  @override
  int get length => 0;

  @override
  bool coversRequest(tt.ProcessRequest request,
          {tt.ProcessPermission permission = tt.ProcessPermission.execution,
          tt.ProcessDirectoryAccess directoryAccess =
              const tt.ProcessDirectoryAccess.empty()}) =>
      false;

  @override
  void rememberRequest(tt.ProcessRequest request,
      {Set<tt.ProcessPermission> permissions = const {}}) {}
}

/// No remembered command approvals: the wasm-shaped slice persists none.
final class _NoCommandApprovals implements tt.ToolCommandApprovals {
  const _NoCommandApprovals();

  @override
  List<Map<String, Object?>> get entries => const [];

  @override
  bool coversAccess(String capability, String target) => false;

  @override
  void revoke(String id, {String? directory}) {}

  @override
  Map<String, Object?> settings(tt.CommandApprovalScope scope) => const {};

  @override
  String? get filePath => null;
}
