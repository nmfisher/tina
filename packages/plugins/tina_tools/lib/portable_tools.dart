/// The portable subset of `tina_tools`: the file tools (read, write,
/// edit) and the filesystem seam they run on, with no `dart:io` import
/// anywhere in the graph. A wasm composition root imports THIS library
/// (never the main barrel, which reaches the sandboxed runner and the
/// process tools); a native build can use it identically.
///
/// Everything here is the real tool code the full plugin registers —
/// same classes, same behavior — just the slice that carries no
/// platform-only dependency.
library;

export 'src/file_system.dart';
export 'src/default_file_system.dart';
export 'src/permissions.dart'
    show
        Approval,
        Approver,
        FileOperation,
        FileOp,
        FileGrants,
        ToolVerdict,
        decideOperation,
        operationReason;
export 'src/tool.dart';
export 'src/tool_input.dart';
export 'src/tool_descriptions.dart';
export 'src/tool_file_system.dart';
export 'src/tool_boundary.dart';
export 'src/tools_plugin_surface.dart';
// The session-source interface the native catalog's context plugin
// consumes; portable implementations (the wasm engine's tools plugin)
// declare it so the capability resolves unchanged.
export 'src/tools_plugin.dart' show ToolSessionSource;
export 'src/process_runner.dart'
    show
        ProcessCommandApprover,
        ProcessControl,
        ProcessDirectoryAccess,
        ProcessPermission,
        ProcessRequest,
        RunOutcome;
export 'src/asking_boundary.dart';
export 'src/sandbox_violation.dart';
export 'src/atomic_write.dart';
export 'src/read_tool.dart';
export 'src/write_tool.dart';
export 'src/edit_tool.dart';
