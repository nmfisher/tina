import 'dart:async';

import 'package:tina_engine/tina_engine.dart';

/// A headless post-edit compile gate (#22a): after a `write` or `edit` succeeds,
/// run `dart analyze <filePath>` (30s bounded) and, when the analyzer reports
/// error-severity diagnostics, append a compact block to the tool result the
/// model reads next step — so it sees the compile error while its edit is still
/// in context and can self-correct before the NEXT `dart run` exits 254.
///
/// Only fires for tool names `edit`/`write` with `.dart` file paths. Clean
/// analyze, warnings-only, non-Dart paths, and any timeout/spawn failure return
/// null (no block appended). A verifier crash is caught at the agent and
/// logged; this class never throws into the agent loop.
///
/// The engine's [ToolResultVerifier] is a plain function typedef, so this
/// class conforms via its `call` method (no `implements` clause).
class DartAnalyzeVerifier {
  final ProcessRunner processRunner;

  DartAnalyzeVerifier({ProcessRunner? processRunner})
      : processRunner = processRunner ?? const IoProcessRunner();

  /// How many error lines the block carries before it truncates to a
  /// `... (K more)` tail.
  static const int maxErrorLines = 5;

  /// The [ToolResultVerifier] seam: fires only for `edit`/`write` on `.dart`
  /// targets; anything else is a silent no-op.
  Future<String?> call(String toolName, Map<String, dynamic> input) async {
    // Only `edit` and `write` tools, and only when the target ends `.dart`.
    if (toolName != 'edit' && toolName != 'write') return null;
    final filePath = input['filePath'] as String?;
    if (filePath == null || filePath.isEmpty) return null;
    if (!filePath.endsWith('.dart')) return null;

    try {
      final result = await processRunner
          .run('dart', ['analyze', filePath])
          .timeout(const Duration(seconds: 30));
      return blockFor(
        stdout: result.stdout,
        stderr: result.stderr,
        filePath: filePath,
      );
    } on TimeoutException {
      return null; // bounded: never hang the turn
    } catch (_) {
      return null; // spawn failure and friends never hang or kill the turn
    }
  }

  /// Pure output→block mapping (exposed for tests): parse `dart analyze`
  /// output — verified against a scratch `.dart` file with real errors, the
  /// error-severity lines read `  error - path:line:col - message  - code` —
  /// and return the remediation block, or null when there are no errors
  /// (clean analyze, warnings-only, or a failed invocation with no parseable
  /// diagnostics).
  static String? blockFor({
    required String stdout,
    required String stderr,
    required String filePath,
  }) {
    final errorLines = (stdout + stderr)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.startsWith('error - '))
        .toList();
    if (errorLines.isEmpty) return null;

    final shown = errorLines.take(maxErrorLines).toList();
    final more = errorLines.length - shown.length;
    final buf = StringBuffer()
      ..write('[analyze] $filePath: ${errorLines.length} error(s) — '
          'fix before continuing:');
    for (final line in shown) {
      buf.write('\n  ${_trimSeverity(line)}');
    }
    if (more > 0) buf.write('\n  ... ($more more)');
    return buf.toString();
  }

  /// `error - path:line:col - message  - code` → `path:line:col message`.
  static String _trimSeverity(String line) {
    final withoutSeverity = line.substring('error - '.length);
    // Drop the trailing diagnostic code (`  - some_code`) when present.
    final codeIdx = withoutSeverity.lastIndexOf('  - ');
    final body =
        codeIdx > 0 ? withoutSeverity.substring(0, codeIdx) : withoutSeverity;
    return body.trim();
  }
}
