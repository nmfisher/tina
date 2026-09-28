import 'package:tina_core/tina_core.dart';

/// A tool the model can call. The contract is the advertised [schema] plus
/// one async [execute] — nothing else. A tool declares nothing about
/// permissions: the model is free to try any tool, and the thing that
/// refuses is the [FileSystem] the tool was handed, per call. All value
/// types come from `tina_core`; this package defines none.
abstract class Tool {
  ToolSchema get schema;

  /// Run the tool. Fast tools ignore cancellation; the loop checks its token
  /// around each call.
  Future<ToolResult> execute(Map<String, dynamic> input);
}

/// Wrap a string-returning executor so it satisfies a loop whose
/// `registerExecutor` wants the full [ToolResult]. The content is the
/// string; no flags are set.
Future<ToolResult> Function(Map<String, Object?>) stringExecutor(
        Future<String> Function(Map<String, Object?>) exec) =>
    (input) async => ToolResult(await exec(input));
