/// The portable tools plugin: the real `read`/`write`/`edit` tool
/// classes (from `tina_tools/portable_tools`) registered as one
/// `tina/tools` plugin over the injected WASI filesystem, with the real
/// mode policy mounted (the same `ModePlugin` the full plugin mounts)
/// and the portable asking boundary enforcing the mode table — asks
/// reach the approvals channel exactly as the native sandbox's do.
///
/// What the full native plugin additionally provides — sandboxed
/// process runners, glob/ls/stat, approvals store — stays native for
/// now (stage-5 slices); this slice carries the file-editing core the
/// engine's turns need.
library;

import 'package:tina_approvals/tina_approvals.dart'
    show ApprovalDecision, ApprovalRequester;
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_mode/tina_mode.dart'
    show
        AccessCapability,
        AccessRequirement,
        AuthorizationRequest,
        ModePlugin,
        ModePolicySource,
        PermissionMode;
import 'package:tina_tools/portable_tools.dart' as tt;

/// `tina/tools` over the portable file tools and the asking boundary.
final class PortableToolsPlugin extends AgentPlugin
    implements ModePolicySource {
  PortableToolsPlugin({
    required tt.FileSystem fileSystem,
    required String workspaceRoot,
    PermissionMode mode = PermissionMode.yolo,
    List<String> protectedPaths = const [],
    bool Function(String path)? isWithinWorkspace,
  })  : _boundary = tt.AskingBoundary(
          fileSystem,
          workspaceRoot: workspaceRoot,
          mode: mode,
          protectedPaths: protectedPaths,
          isWithinWorkspace: isWithinWorkspace,
        ),
        modePolicy = ModePlugin(mode: mode) {
    modePolicy.listen((value) {
      _boundary.mode = value;
    });
    _boundary.policyRevision = () => modePolicy.revision;
  }

  /// The enforcement boundary: mode table, asks, session grants.
  final tt.AskingBoundary _boundary;

  @override
  final ModePlugin modePolicy;

  @override
  String get id => 'tina/tools';

  @override
  int get order => 10;

  final List<tt.Tool> _toolList = [];

  /// Wire the approval requester (the `tina/approvals` coordinator):
  /// boundary asks now route through the mode policy's request path —
  /// the same routing the native tools plugin's sandbox uses — so an
  /// ask reaches the session's approval channel and a pipes client can
  /// answer it. Before this, asks are refused ("no approver wired").
  void attachApprovals(ApprovalRequester approvals) {
    modePolicy.approvals = approvals;
    _boundary.approver = (request, reason) async {
      final decision = await modePolicy.request(
        operation: request.op.name,
        target: request.path,
        reason: reason,
        context: const {'permission_scope': 'file'},
        authorization: AuthorizationRequest(
          requirements: [
            AccessRequirement(
              request.op == tt.FileOp.read
                  ? AccessCapability.read
                  : AccessCapability.write,
              request.path,
              workspace: request.op == tt.FileOp.read ||
                  _boundary.isWithinWorkspacePath(request.path),
              granted: _boundary.grantsOf(request.op).allows(request.path),
            ),
          ],
        ),
      );
      return switch (decision) {
        ApprovalDecision.allow => tt.Approval.yes,
        ApprovalDecision.allowAlways => tt.Approval.always,
        ApprovalDecision.deny =>
          throw tt.SandboxViolation('$reason — approval denied or cancelled'),
        _ => tt.Approval.no,
      };
    };
  }

  void _build() {
    if (_toolList.isNotEmpty) return;
    _toolList.addAll([
      tt.ReadTool(fs: _boundary, workspaceRoot: _boundary.workspaceRoot),
      tt.WriteTool(fs: _boundary, workspaceRoot: _boundary.workspaceRoot),
      tt.EditTool(fs: _boundary, workspaceRoot: _boundary.workspaceRoot),
    ]);
  }

  @override
  List<ToolSchema> get tools {
    _build();
    return [for (final tool in _toolList) tool.schema];
  }

  @override
  void mountOn(AgentLoop loop) {
    modePolicy.mountPolicy(loop, ownerId: id);
    _build();
    for (final tool in _toolList) {
      loop.registerContextExecutor(tool.schema.name, (input, context) {
        return tool.execute(Map<String, Object?>.from(input as Map));
      });
    }
  }
}
