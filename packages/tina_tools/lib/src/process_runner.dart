/// The process-execution seam, the twin of [FileSystem]: the file tools read
/// and write through one, the process tools (bash, exec) start programs
/// through the other.
///
/// Two contracts live here:
///
/// - [ProcessRunner] — run a command and get its exit code with captured
///   stdout and stderr. [IoProcessRunner] is the real implementation. There
///   is deliberately **no OS-level confinement behind it today** (no
///   bubblewrap, no `sandbox-exec` — neither binary exists in this
///   container); when one lands it will be a second [ProcessRunner], and
///   nothing above this seam will change. See the package README.
/// - [RunOutcome] — the decoded result. A **refusal is a distinct outcome,
///   not an exception**: the caller cannot guess whether a throw meant "the
///   permission boundary said no" or "the program crashed", and the two need
///   completely different treatment (a refusal is the model's answer; a
///   non-zero exit is just a result).
///
/// Enforcement itself lives in `sandboxed_process_runner.dart`, which wraps
/// a [ProcessRunner] the way `SandboxedFileSystem` wraps a [FileSystem].
/// This file holds the seam and the shapes only — no policy, no asks, no
/// timeout policy — so tests can script any of it deterministically.
library;

import 'dart:async';
import 'dart:io';

/// One command the runner has been asked to run.
///
/// [command] is the program (looked up on `PATH`); [arguments] are passed
/// literally — no shell interprets them. The record is what the asker is
/// shown and what grants are matched against, so it carries exactly what
/// will run and nothing else.
typedef ProcessRequest = ({
  String command,
  List<String> arguments,
  String? workingDirectory,
  Map<String, String>? environment,
  String? stdin,
  Duration? timeout,
});

/// What happened: the command ran to completion ([CommandCompleted]) or the
/// permission boundary refused it before a process existed
/// ([CommandRefused]).
sealed class RunOutcome {
  const RunOutcome();
}

/// The command ran (through the wrapped runner) and finished. A **non-zero
/// [exitCode] is a normal result, not a refusal** — the two must never be
/// confused: the model sees `exit code` + output and decides what to do,
/// exactly as it does with a failing build.
class CommandCompleted extends RunOutcome {
  final int exitCode;
  final String stdout;
  final String stderr;

  /// Why the runner allowed it — `'inside the session's writable set'`, a
  /// grant note, or null. Purely informational; the model never needs it.
  final String? note;
  const CommandCompleted(
      {required this.exitCode,
      required this.stdout,
      required this.stderr,
      this.note});
}

/// The boundary refused the command before any process started. [reason]
/// names the specific rule that decided, in the model's words — the same
/// discipline as a `SandboxViolation` message. Tools convert this into an
/// ordinary error result; they never re-throw it.
class CommandRefused extends RunOutcome {
  final String reason;
  const CommandRefused(this.reason);
}

/// Runs a command and returns its outcome. This is the seam; wrap it with
/// [SandboxedProcessRunner] for enforcement, or use [IoProcessRunner] raw
/// when a host decides permissions itself.
abstract class ProcessRunner {
  Future<RunOutcome> run(ProcessRequest request);
}

/// [ProcessRunner] over real `dart:io` — the process actually runs here, so
/// the caller must have decided this is allowed before reaching it. Spawns
/// the program directly; [ProcessRequest.arguments] reach it as argv with no
/// shell in between, so a command string has to come via
/// `command: <shell>, arguments: ['-c', ...]` (that is what BashTool does).
class IoProcessRunner implements ProcessRunner {
  const IoProcessRunner();

  @override
  Future<RunOutcome> run(ProcessRequest request) async {
    try {
      final result = await Process.run(
        request.command,
        request.arguments,
        workingDirectory: request.workingDirectory,
        environment: request.environment,
        includeParentEnvironment: request.environment == null,
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      ).timeout(request.timeout ?? const Duration(minutes: 10));
      return CommandCompleted(
        exitCode: result.exitCode,
        stdout: result.stdout is String
            ? result.stdout as String
            : (result.stdout?.toString() ?? ''),
        stderr: result.stderr is String
            ? result.stderr as String
            : (result.stderr?.toString() ?? ''),
      );
    } on TimeoutException {
      // The command's own timeout fired and the work was killed. That is a
      // completed run with a killed-shaped exit, not a permission refusal:
      // the boundary allowed it, the process just did not finish.
      return const CommandCompleted(
          exitCode: -9,
          stdout: '',
          stderr: 'timed out: the command was killed after its timeout',
          note: 'timeout');
    } on ProcessException catch (e) {
      // The program could not be started at all (not found, not
      // executable). Also a completed run from the boundary's point of
      // view — the decision to run was made; the OS said no.
      return CommandCompleted(
          exitCode: 127, stdout: '', stderr: e.message, note: 'spawn failed');
    }
  }
}
