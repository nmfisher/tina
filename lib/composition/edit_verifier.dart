import 'dart:async';
import 'dart:io';

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

  /// Startup tree-health check (#22b): run `dart analyze` over the WHOLE
  /// project (no file argument) in [cwd] (null = the process cwd) and return
  /// a notice naming the broken tree when the analyzer reports error-severity
  /// diagnostics — the headless host prepends it to the turn so the model is
  /// TOLD at startup, before it plans anything, that fixes come first. The
  /// per-edit verdicts from [call] live in the transcript, but compaction can
  /// drop them, the break may pre-date the session, or the breakage came from
  /// outside (a kill, a manual edit); the current tree state is authoritative.
  ///
  /// Shares the exact parse/cap/trim of [blockFor]; only the header differs
  /// (it names the tree, not one file). Null on a clean or warnings-only
  /// analyze and on any timeout/spawn failure — never throws into the caller.
  Future<String?> projectCheck({String? cwd}) async {
    try {
      final result = await processRunner
          .run('dart', ['analyze'], workingDirectory: cwd)
          .timeout(const Duration(seconds: 30));
      return _cappedErrorBlock(
        stdout: result.stdout,
        stderr: result.stderr,
        header: (n) =>
            '[tree-health] the working tree does not compile: $n error(s)'
            ' — fix these FIRST:',
      );
    } on TimeoutException {
      return null; // bounded: never hang startup
    } catch (_) {
      return null; // spawn failure and friends never kill the run
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
    return _cappedErrorBlock(
      stdout: stdout,
      stderr: stderr,
      header: (n) =>
          '[analyze] $filePath: $n error(s) — fix before continuing:',
    );
  }

  /// Whether THIS run may act on a [wrapTreeHealth] notice: does an `edit` of
  /// a scratch `.dart` file in [cwd] (null = process cwd) pass the given
  /// [policy]? The probe mirrors what a real fix attempt would need — static
  /// allow/deny rules and mode widening decide; no ask is ever surfaced.
  /// Exposed for tests so the actionable gate can be asserted without
  /// spawning a run.
  static bool editActionable(PermissionPolicy policy, {String? cwd}) {
    final dir = cwd ?? Directory.current.path;
    final joined = dir.endsWith('/')
        ? '${dir}tree_health_probe.dart'
        : '${dir}/tree_health_probe.dart';
    return policy.check('edit', {'filePath': joined}) ==
        PermissionDecision.allow;
  }

  /// Wrap a [projectCheck] notice for the headless turn prefix (#27). When
  /// [editActionable] is false — a read-only/no-allow run — the usual "fix
  /// these FIRST" framing is a denial spiral invitation: the model tries
  /// edit after edit, each refused, burning steps it never recovers (#27 Run
  /// A: 12 wasted steps). In that case append an explicit do-not-try line so
  /// the model treats the breakage as context and answers with read-only
  /// tools instead.
  static String wrapTreeHealth(String notice, {required bool editActionable}) {
    if (editActionable) return notice;
    return '$notice\n'
        'You do NOT have edit permission in this run — do not try to fix '
        'these. Treat them as pre-existing context and answer with read-only '
        'tools.';
  }

  /// Shared parse+cap core behind [blockFor] and [projectCheck]: collect the
  /// `error - ` lines from combined stdout+stderr, cap at [maxErrorLines]
  /// with a `... (K more)` tail, severity-trim each line, and open the block
  /// with [header] (built from the total error count). Null when there are
  /// no error lines.
  static String? _cappedErrorBlock({
    required String stdout,
    required String stderr,
    required String Function(int errorCount) header,
  }) {
    final errorLines = (stdout + stderr)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.startsWith('error - '))
        .toList();
    if (errorLines.isEmpty) return null;

    final shown = errorLines.take(maxErrorLines).toList();
    final more = errorLines.length - shown.length;
    final buf = StringBuffer()..write(header(errorLines.length));
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
    final body = codeIdx > 0
        ? withoutSeverity.substring(0, codeIdx)
        : withoutSeverity;
    return body.trim();
  }
}
