import 'package:tina_core/tina_core.dart';

import 'tool_capabilities.dart';

/// A tool the model can call. The contract is the advertised [schema], the
/// declared [capabilities], and one async [execute]. All value types come from
/// `tina_core`; this package defines none.
abstract class Tool {
  ToolSchema get schema;

  /// What this tool actually does — declared here, not inferred from a name
  /// table. See [ToolCapabilities].
  ToolCapabilities get capabilities;

  /// Run the tool. Fast tools ignore cancellation; the loop checks its token
  /// around each call.
  Future<ToolResult> execute(Map<String, dynamic> input);
}
