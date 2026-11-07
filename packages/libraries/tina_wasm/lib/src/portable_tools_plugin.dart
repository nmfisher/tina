/// The portable tools plugin: the real `read`/`write`/`edit` tool
/// classes (from `tina_tools/portable_tools`) registered as one
/// `tina/tools` plugin over the injected WASI filesystem, with the real
/// mode policy mounted (the same `ModePlugin` the full plugin mounts).
///
/// What the full native plugin additionally provides — sandboxed
/// process runners, glob/ls/stat, approvals store — stays native for
/// now (stage-5 slices); this slice carries the file-editing core the
/// engine's turns need.
library;

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_mode/tina_mode.dart'
    show ModePlugin, ModePolicySource, PermissionMode;
import 'package:tina_tools/portable_tools.dart' as tt;

/// `tina/tools` over the portable file tt.
final class PortableToolsPlugin extends AgentPlugin
    implements ModePolicySource {
  PortableToolsPlugin({
    required tt.FileSystem fileSystem,
    required String workspaceRoot,
    PermissionMode mode = PermissionMode.yolo,
  })  : _fileSystem = fileSystem,
        _workspaceRoot = workspaceRoot,
        modePolicy = ModePlugin(mode: mode);

  final tt.FileSystem _fileSystem;
  final String _workspaceRoot;

  @override
  final ModePlugin modePolicy;

  @override
  String get id => 'tina/tools';

  @override
  int get order => 10;

  final List<tt.Tool> _toolList = [];

  void _build() {
    if (_toolList.isNotEmpty) return;
    _toolList.addAll([
      tt.ReadTool(fs: _fileSystem, workspaceRoot: _workspaceRoot),
      tt.WriteTool(fs: _fileSystem, workspaceRoot: _workspaceRoot),
      tt.EditTool(fs: _fileSystem, workspaceRoot: _workspaceRoot),
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
