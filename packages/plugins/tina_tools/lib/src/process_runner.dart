library;

import 'dart:async';
import 'dart:io';

import 'process_tree.dart';
import 'captured_process.dart';

/// One command the runner has been asked to run.
///
/// [command] is the program (looked up on `PATH`); [arguments] are passed
/// literally — no shell interprets them. The record is what the approver is
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

/// Permissions for a process invocation. Network opens access for the entire
/// subprocess tree; it does not relax filesystem confinement.
enum ProcessPermission { execution, network, unconfined }

/// What happened: the command ran to completion ([CommandCompleted]), the
/// permission boundary refused it before a process existed
/// ([CommandRefused]), or the OS sandbox stopped it mid-run
/// ([CommandBlocked]).
sealed class RunOutcome {
  const RunOutcome();
}

/// The command continues under a session-owned job manager.
final class CommandRunning extends RunOutcome {
  const CommandRunning(this.id, this.output);
  final String id;
  final String output;
}

/// The command ran (through the wrapped runner) and finished. A **non-zero
/// [exitCode] is a normal result, not a refusal** — the two must never be
/// confused: the model sees `exit code` + output and decides what to do,
/// exactly as it does with a failing build.
class CommandCompleted extends RunOutcome {
  final int exitCode;
  final String stdout;
  final String stderr;

  /// Why the runner allowed it — `'inside the session's writable directories'`, a
  /// grant note, or null. Purely informational; the model never needs it.
  final String? note;
  final bool cancelled;
  final bool timedOut;
  const CommandCompleted(
      {required this.exitCode,
      required this.stdout,
      required this.stderr,
      this.note,
      this.cancelled = false,
      this.timedOut = false});
}

/// The boundary refused the command before any process started. [reason]
/// names the specific rule that decided, in the model's words — the same
/// discipline as a `SandboxViolation` message. Tools convert this into an
/// ordinary error result; they never re-throw it.
class CommandRefused extends RunOutcome {
  final String reason;
  const CommandRefused(this.reason);
}

/// The permission gate approved the command, **the operating system's
/// sandbox then stopped it**. Distinct from [CommandCompleted] (a bare
/// non-zero exit the model would read as "the tool failed, try again" —
/// but no retry inside the same jail can ever work) and from
/// [CommandRefused] (our gate's word, set before any process existed).
///
/// [reason] says what the kernel refused and names the sandbox as the
/// stopper, in the model's words.
class CommandBlocked extends RunOutcome {
  final String reason;
  const CommandBlocked(this.reason);
}

/// Runs a command and returns its outcome. This is the seam; wrap it with
/// [SandboxedProcessRunner] for enforcement, or use [IoProcessRunner] raw
/// when a host decides permissions itself.
abstract class ProcessRunner {
  Future<RunOutcome> run(ProcessRequest request, {ProcessControl? control});
}

/// Requirements, cancellation and output for one invocation. The permission
/// boundary sets authorization; wrappers preserve the other fields.
/// No loop or terminal dependency.
final class ProcessControl {
  const ProcessControl(
      {this.networkRequested = false,
      this.networkReason,
      this.networkAllowed = false,
      this.outsideSandboxRequested = false,
      this.sandboxReason,
      this.outsideSandboxAllowed = false,
      this.isCancelled,
      this.whenCancelled,
      this.onOutput,
      this.whenInputPending,
      this.background = false,
      this.onStarted});
  final bool networkRequested;
  final String? networkReason;

  /// Authorization supplied by the permission boundary, never by tool input.
  final bool networkAllowed;
  final bool outsideSandboxRequested;
  final String? sandboxReason;

  /// Set by the permission boundary after explicit human authorization.
  /// An execution or network approval alone never sets this.
  final bool outsideSandboxAllowed;
  final bool Function()? isCancelled;
  final Future<void>? whenCancelled;
  final void Function(String text, {bool isError})? onOutput;
  final Future<void>? whenInputPending;

  /// Return a job ID after approval and process startup, without waiting.
  final bool background;
  final void Function()? onStarted;

  ProcessControl copyWith({
    bool? networkRequested,
    String? networkReason,
    bool? networkAllowed,
    bool? outsideSandboxRequested,
    String? sandboxReason,
    bool? outsideSandboxAllowed,
    bool? background,
  }) =>
      ProcessControl(
        networkRequested: networkRequested ?? this.networkRequested,
        networkReason: networkReason ?? this.networkReason,
        networkAllowed: networkAllowed ?? this.networkAllowed,
        outsideSandboxRequested:
            outsideSandboxRequested ?? this.outsideSandboxRequested,
        sandboxReason: sandboxReason ?? this.sandboxReason,
        outsideSandboxAllowed:
            outsideSandboxAllowed ?? this.outsideSandboxAllowed,
        isCancelled: isCancelled,
        whenCancelled: whenCancelled,
        onOutput: onOutput,
        whenInputPending: whenInputPending,
        background: background ?? this.background,
        onStarted: onStarted,
      );
}

/// Owns the spawned process until exit or cancellation cleanup has completed.
class IoProcessRunner implements ProcessRunner {
  const IoProcessRunner();

  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    if (control?.outsideSandboxRequested == true &&
        (control?.outsideSandboxAllowed != true ||
            control?.networkAllowed != true)) {
      return const CommandRefused(
          'Outside-sandbox execution denied: explicit approval for host '
          'filesystem and network access is required.');
    }
    if (control?.networkRequested == true && control?.networkAllowed != true) {
      return const CommandRefused(
          'Network access denied: no permission boundary approved this command.');
    }
    CommandCompleted stopped(String reason, String out, String err) =>
        CommandCompleted(
            exitCode: -9,
            stdout: out,
            stderr: '$err${err.isEmpty ? '' : '\n'}$reason: command stopped',
            note: reason,
            cancelled: reason == 'cancelled',
            timedOut: reason == 'timeout');
    if (control?.isCancelled?.call() == true)
      return stopped('cancelled', '', '');
    final Process process;
    try {
      process = await startCapturedProcess(request.command, request.arguments,
          workingDirectory: request.workingDirectory,
          environment: request.environment,
          includeParentEnvironment: request.environment == null);
    } on ProcessException catch (e) {
      return CommandCompleted(
          exitCode: 127, stdout: '', stderr: e.message, note: 'spawn failed');
    }
    final out = _CapturedOutput();
    control?.onStarted?.call();
    final err = _CapturedOutput();
    final drained = <Future<void>>[];
    final subscriptions = <StreamSubscription<String>>[];
    void capture(
        Stream<List<int>> stream, _CapturedOutput buffer, bool isError) {
      final done = Completer<void>();
      drained.add(done.future);
      subscriptions.add(stream.transform(systemEncoding.decoder).listen((text) {
        buffer.add(text);
        try {
          control?.onOutput?.call(text, isError: isError);
        } catch (_) {
          // An observer cannot abandon ownership of the child.
        }
      }, onDone: () {
        if (!done.isCompleted) done.complete();
      }, onError: (Object error) {
        buffer.add('\noutput read failed: $error');
        if (!done.isCompleted) done.complete();
      }));
    }

    capture(process.stdout, out, false);
    capture(process.stderr, err, true);
    final stop = Completer<String>();
    final finished = Completer<void>();
    void requestStop(String reason) {
      if (!finished.isCompleted && !stop.isCompleted) stop.complete(reason);
    }

    final timer = Timer(request.timeout ?? const Duration(minutes: 10),
        () => requestStop('timeout'));
    final cancelled = control?.whenCancelled;
    if (cancelled != null) {
      // Release the invocation's callback state when it completes normally.
      unawaited(Future.any([cancelled, finished.future]).then((_) {
        if (!finished.isCompleted) requestStop('cancelled');
      }));
    }
    if (control?.isCancelled?.call() == true) requestStop('cancelled');
    Future<void> feedInput() async {
      try {
        if (request.stdin != null) process.stdin.write(request.stdin);
        await process.stdin.close();
      } on IOException {
        // Commands may close stdin early (including while being cancelled).
      }
    }

    unawaited(feedInput());
    try {
      final exit = process.exitCode;
      final result = await Future.any<Object>([exit, stop.future]);
      if (result is String) {
        await killProcessTree(process.pid);
        await exit;
      }
      // A background descendant can inherit the pipes after its parent exits.
      // Do not let those descriptors park the agent indefinitely.
      await Future.wait(drained)
          .timeout(const Duration(seconds: 1), onTimeout: () => []);
      return result is String
          ? stopped(result, out.text, err.text)
          : CommandCompleted(
              exitCode: result as int, stdout: out.text, stderr: err.text);
    } finally {
      finished.complete();
      timer.cancel();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
  }
}

/// Keep a bounded tail even when a subprocess floods its output pipes.
final class _CapturedOutput {
  static const limit = 1024 * 1024;
  String _text = '';
  bool _truncated = false;
  void add(String text) {
    _text += text;
    if (_text.length > limit) {
      _truncated = true;
      _text = _text.substring(_text.length - limit);
    }
  }

  String get text =>
      '${_truncated ? '[earlier output truncated]\n' : ''}$_text';
}
