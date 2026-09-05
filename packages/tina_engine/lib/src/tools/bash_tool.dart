import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'audit.dart';
import 'process_runner.dart';
import 'process_tree.dart';
import 'tool.dart';
import 'tool_input.dart';

final _log = Logger('tina.tools.bash');

/// The shell-command denylist.
///
/// A regex denylist on a raw shell is a **speed bump, not a sandbox** — a
/// motivated model reaches around it with `python3 -c`, `base64 -d | bash`,
/// `bash -c "$(curl …)"`, `/dev/tcp`, or unrestricted `git push` (all
/// documented in the hardening plan's residual risks). Its job is to block the
/// obvious, lazy, and *accidental* destructive commands and make destructive
/// intent legible.
///
/// Each entry is `(pattern, explanation)`. [bashIsDenied] matches against the
/// *denormalized* command (lowercased, whitespace collapsed) so `git  reset
/// --hard` still matches. The explanation is what the model sees when blocked.
final List<(RegExp, String)> kBashDenylist = [
  // Rooted wipes: `rm -rf /`, `rm -rf /*`. Requires whitespace directly before
  // the `/` so the path operand is *root itself* — allows `rm -rf ./build` (and
  // `./build/`, whose trailing slash is preceded by a letter).
  (
    RegExp(r'\brm\b[^;&|]*-\w*f\w*\b[^;&|]*?\s/\s*\*?\s*(?:$|[;&|])'),
    'rooted recursive delete (rm -rf /)',
  ),
  // Recursive delete of the working directory / everything in it: `rm -rf .`,
  // `rm -rf ./`, `rm -fr .`, `rm -r *`. Catches the project-self-destruction
  // family. Requires a recursive flag (`-r`, packed `-rf`/`-fr`, or
  // `--recursive`) AND a whitespace-delimited operand that is `.`, `./`, or
  // `*` — so `rm -rf ./build` (a real target) and `rm -rf .hidden` are NOT
  // caught, only wholesale cwd/glob deletion.
  (
    RegExp(r'\brm\b[^;&|]*(-\w*r\w*|--recursive)[^;&|]*?'
        r'\s(?:\.|\.\/|\*)(?:\s|$|[;&|])'),
    'recursive delete of the working directory (rm -rf . / *)',
  ),
  // `--no-preserve-root` is only ever destructive intent.
  (
    RegExp(r'\brm\b[^;&|]*--no-preserve-root'),
    'rm --no-preserve-root',
  ),
  // Block-device formatters.
  (RegExp(r'\bmkfs\S*'), 'filesystem formatting (mkfs)'),
  // dd targeting a /dev node (destructive disk writes) — either direction.
  (
    RegExp(r'\bdd\b[^;&|]*\b[io]f=/dev/\S+'),
    'raw disk write via dd to a device',
  ),
  // Classic forkbomb form `:(){ :|:& };:`. The trailing `;` before the final
  // `:` is optional so both `};:` and `}:` match.
  (
    RegExp(r':\(\)\s*\{[^;]*:\|[^;]*\}\s*;?\s*:'),
    'forkbomb pattern',
  ),
  // Destructive git. Misses unrestricted `git push` (residual risk).
  (
    RegExp(r'\bgit\b[^;&|]*\bclean\b[^;&|]*-f'),
    'force-cleaning untracked files (git clean -f)',
  ),
  (
    RegExp(r'\bgit\b[^;&|]*reset\s+--hard'),
    'hard reset (git reset --hard)',
  ),
  // Whitespace (not \b) before the flag: '-' isn't a word char so no boundary.
  (
    RegExp(r'\bgit\b[^;&|]*push\b[^;&|]*\s(-f|--force)\b'),
    'force push',
  ),
  (
    RegExp(r'\bgit\b[^;&|]*checkout\s+--[^;&|]*\.'),
    'discarding working-tree changes (git checkout --)',
  ),
  (
    // `-d` (lowercased): normalization lowercases the command before matching,
    // so the pattern must match the lowercased flag.
    RegExp(r'\bgit\b[^;&|]*branch\s+-d\b'),
    'force-deleting a branch (git branch -D)',
  ),
  // `chmod 777` (recursive or not).
  (RegExp(r'\bchmod\b[^;&|]*777'), 'opening permissions to 777 (chmod)'),
  // `chmod 000` (recursive or not) — strips all permissions, a soft-delete/lock.
  (RegExp(r'\bchmod\b[^;&|]*\b000\b'), 'stripping all permissions (chmod 000)'),
  // Pipe-to-shell: `curl|wget … | sh|bash|zsh|dash`. Misses command
  // substitution (`bash -c "$(curl …)"`) and `curl … | /bin/bash`.
  (
    RegExp(
        r'\b(curl|wget)\b[^;&|]*\|[^;&|]*\b(sh|bash|zsh|dash)\b'),
    'piping fetched content straight into a shell',
  ),
  // Writing to a /dev device other than the common pseudo-devices (writing
  // `/dev/null` is normal; writing `/dev/sda` is not).
  (
    RegExp(r'[>]{1,2}\s*/dev/(?!null|zero|random|urandom|stdin|stderr|stdout|tty|f{1,2}d\w*|/)\S+'),
    'writing to a device node (/dev/...)',
  ),
  // Wholesale deletion via tools other than `rm`.
  // `find … -delete` removes every matched path.
  (RegExp(r'\bfind\b[^;&|]*\s-delete\b'), 'find -delete'),
  // `find … -exec rm` / `-execdir rm` runs rm over every match.
  (
    RegExp(r'\bfind\b[^;&|]*-exec(?:dir)?\s+rm\b'),
    'find -exec rm',
  ),
  // `rsync … --delete` deletes destination files absent from the source — a
  // mirror-sync to an empty/wrong source is mass deletion.
  (RegExp(r'\brsync\b[^;&|]*--delete\b'), 'rsync --delete'),
];

/// True if [command] trips the denylist. The command is denormalized (lowercased,
/// inner whitespace collapsed) before matching so flag packing and extra
/// spaces don't evade it. Returns the matched explanation so the caller can
/// surface *why* it was blocked.
({bool denied, String? reason}) bashIsDenied(String command) {
  final normalized =
      command.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  for (final (pattern, explanation) in kBashDenylist) {
    if (pattern.hasMatch(normalized)) {
      return (denied: true, reason: explanation);
    }
  }
  return (denied: false, reason: null);
}

/// Validate that a `cwd` stays within the project root. Returns null when OK,
/// otherwise a human-readable violation message. A broken symlink or a cwd
/// outside the root is rejected. When [projectRoot] is null (e.g. tests that
/// don't set one) the check is skipped — bash has no fs of its own, so the root
/// is threaded in explicitly.
String? assertCwdWithinProject(String? cwd, String? projectRoot) {
  if (cwd == null || projectRoot == null) return null;
  final target = Directory(cwd).resolveSymbolicLinksSync();
  final root = Directory(projectRoot).resolveSymbolicLinksSync();
  if (target != root && !p.isWithin(root, target)) {
    return 'cwd escapes the project root: $cwd';
  }
  return null;
}

class BashTool implements Tool {
  /// Per-stream cap on captured output. The process keeps running and we keep
  /// reading the pipe (so it doesn't block on write back-pressure), but we
  /// stop appending to the buffer once we cross this — bounds memory when a
  /// command floods stdout (e.g. `cat /dev/urandom`, a chatty test suite).
  static const int outputByteCap = 200 * 1024;

  /// After the process exits we'd like to drain the pipes for any final
  /// output, but if the shell forked a child that inherited the stdout fd we
  /// won't see EOF until that child exits too. Bound the wait so a `sh -c
  /// "long_running_thing"` that we kill returns promptly.
  static const Duration _streamDrainGrace = Duration(milliseconds: 500);

  /// How long to wait for the process to die after a kill before giving up on
  /// it. If it hasn't exited within this window (a stuck/D-state process that
  /// ignores SIGTERM and survives SIGKILL) we stop waiting, report what we
  /// captured, and say so — rather than hanging the tool forever.
  final Duration postKillGrace;

  /// Hard clamp on the model-supplied `timeoutSeconds`: at least 1s (0 or
  /// negative would kill instantly), at most 900s — comfortably above the
  /// session watchdog's 300s default (lib/config.dart), so a legitimate long
  /// command isn't raced by both timers.
  static const int _minTimeoutSec = 1;
  static const int _maxTimeoutSec = 900;

  /// Clamps a model-supplied timeout into [_minTimeoutSec, _maxTimeoutSec].
  /// Exposed (static, pure) so tests can pin the boundaries without waiting on
  /// real timers.
  static int clampTimeoutSeconds(int seconds) =>
      seconds.clamp(_minTimeoutSec, _maxTimeoutSec).toInt();

  final Duration timeout;

  /// Subprocess execution is injected so the tool is unit-testable without
  /// spawning a real shell. Defaults to [IoProcessRunner] (/bin/sh); app
  /// composition swaps in a [SandboxedProcessRunner] to confine writes. Mutable
  /// (set once at composition, like [projectRoot]).
  ProcessRunner processRunner;

  /// Project root the shell's `cwd` is confined to. Mutable so app composition
  /// can set it once. Null disables the cwd sandbox (e.g. in tests that don't
  /// set a root). Bash has no [FileSystem] of its own, so the root is threaded
  /// in explicitly and validated with [assertCwdWithinProject] before the
  /// shell starts.
  String? projectRoot;

  /// Where to spill full output once a stream exceeds [outputByteCap]. Defaults
  /// to the OS temp dir; tests inject a directory they can inspect.
  final Directory Function() tempDirFactory;

  BashTool({
    this.timeout = const Duration(seconds: 60),
    this.postKillGrace = const Duration(seconds: 10),
    ProcessRunner? processRunner,
    this.projectRoot,
    Directory Function()? tempDirFactory,
  })  : processRunner = processRunner ?? const IoProcessRunner(),
        tempDirFactory = tempDirFactory ?? (() => Directory.systemTemp);

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'bash',
        description:
            'Run a shell command via /bin/sh -c. Captures stdout, stderr, '
            'and exit code. Runs in the tina process cwd unless `cwd` is '
            'given. Subject to the session permission policy. Each call is a '
            'fresh shell — chain dependent steps with `&&` rather than '
            'expecting state to persist.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description': 'The shell command to run.',
            },
            'cwd': {
              'type': 'string',
              'description':
                  'Working directory for the command. Absolute or relative '
                  'to the agent cwd. Defaults to the agent cwd.',
            },
            'timeoutSeconds': {
              'type': 'integer',
              'description':
                  'Override the default 60s timeout. Clamped to 1–900s.',
            },
          },
          'required': ['command'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final String command;
    final String? cwd;
    final int timeoutSec;
    try {
      command = requiredString(input, 'command');
      cwd = optionalString(input, 'cwd');
      final requested =
          optionalInt(input, 'timeoutSeconds') ?? timeout.inSeconds;
      // Clamp the model-supplied override to [1, 900]: 0 or negative would
      // kill the command before it starts, and anything beyond 900s is long
      // past the point where the session watchdog (300s default) has already
      // pulled the plug — no honest timeout lives above that.
      timeoutSec = clampTimeoutSeconds(requested);
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    }
    if (cwd != null && !Directory(cwd).existsSync()) {
      return ToolResult.error('cwd does not exist: $cwd');
    }
    // Cwd sandbox (review H1/M2): the shell's working directory must stay
    // within the project root. Runs inside execute (after the ask-gate) but is
    // unconditional, so yolo can't skip it. Honest-label: prompt-then-block.
    final cwdViolation = assertCwdWithinProject(cwd, projectRoot);
    if (cwdViolation != null) {
      auditDenial(kind: auditSandbox, detail: cwdViolation);
      return ToolResult.error(cwdViolation);
    }
    // Command denylist: block obvious destructive commands before the shell
    // starts. Audited for forensics; the raw command is redacted by audit.dart.
    final denial = bashIsDenied(command);
    if (denial.denied) {
      auditDenial(kind: auditDenylist, detail: command);
      return ToolResult.error(
        'Command blocked by safety denylist: ${denial.reason}. This command '
        'is considered destructive. If you genuinely need it, rephrase the '
        'task without it.',
      );
    }

    final RunningProcess proc;
    try {
      proc = await processRunner.start(
        '/bin/sh',
        ['-c', command],
        workingDirectory: cwd ?? Directory.current.path,
      );
    } catch (e) {
      return ToolResult.error('Failed to start: $e');
    }
    final stopwatch = Stopwatch()..start();

    // Each stream keeps a rolling tail (what the model sees) and spills the
    // full output to a temp file once it crosses the cap — so a multi-MB flood
    // is bounded in memory yet nothing is permanently lost.
    final stdoutAcc = _BashOutput(outputByteCap, tempDirFactory, 'stdout');
    final stderrAcc = _BashOutput(outputByteCap, tempDirFactory, 'stderr');

    // Drive stdout/stderr through explicit subscriptions so we can cancel
    // them after proc exit — see [_streamDrainGrace].
    final outDone = Completer<void>();
    final errDone = Completer<void>();
    void completeOnce(Completer<void> c) {
      if (!c.isCompleted) c.complete();
    }

    final outSub = proc.stdout.transform(utf8.decoder).listen(
      (s) {
        stdoutAcc.append(s);
        if (onOutput != null) onOutput(s);
      },
      onDone: () => completeOnce(outDone),
      onError: (Object e, StackTrace st) {
        _log.fine('stdout stream error', e, st);
        completeOnce(outDone);
      },
    );
    final errSub = proc.stderr.transform(utf8.decoder).listen(
      (s) {
        stderrAcc.append(s);
        if (onOutput != null) onOutput(s, stderr: true);
      },
      onDone: () => completeOnce(errDone),
      onError: (Object e, StackTrace st) {
        _log.fine('stderr stream error', e, st);
        completeOnce(errDone);
      },
    );

    // Terminate the whole descendant tree on cancel/timeout — not just the
    // /bin/sh child — so a backgrounded/forked process can't outlive the
    // command. The tree is killed FIRST, while the shell is still alive and its
    // children are discoverable; then the direct child is signalled via the seam
    // (which is also what drives in-memory test doubles — killProcessTree is a
    // no-op for their pid). Fire-and-forget: the await on [proc.exitCode] below
    // resolves once the process actually dies.
    Future<void> terminate() async {
      await killProcessTree(proc.pid);
      try {
        // The tree-kill above has already SIGKILLed everything it can see;
        // `force` marks this direct signal as the last-resort escalation (the
        // in-memory test seam records it — see [postKillGrace] below).
        proc.kill(force: true);
      } catch (e) {
        _log.fine('direct kill failed', e);
      }
    }

    var cancelled = false;
    var timedOut = false;
    // The exit wait is a race: [proc.exitCode] vs a [postKillGrace] window
    // that opens only once a kill has been sent. A process that exits on its
    // own — however slowly — gets unbounded time; the grace exists purely so
    // a kill-proof (stuck/D-state) process can't hang the tool forever.
    final exitOnce = Completer<int>();
    unawaited(proc.exitCode
        .then((c) { if (!exitOnce.isCompleted) exitOnce.complete(c); }));
    var killedButStuck = false;
    Future<void> terminateWithGrace() async {
      await terminate();
      Timer(postKillGrace, () {
        if (!exitOnce.isCompleted) {
          killedButStuck = true;
          exitOnce.complete(-1);
        }
      });
    }

    final timer = Timer(Duration(seconds: timeoutSec), () {
      timedOut = true;
      terminateWithGrace();
    });
    cancelSignal?.then((_) {
      cancelled = true;
      terminateWithGrace();
    });

    final exitCode = await exitOnce.future;
    timer.cancel();
    stopwatch.stop();

    if (killedButStuck) {
      // Nobody is coming: drop the subscriptions so the run() future can
      // finish even though the pipes never close. Skips the bounded drain
      // below — there is nothing more to drain from a process we abandoned.
      await outSub.cancel();
      await errSub.cancel();
      _log.warning(
        'bash: process did not exit within ${postKillGrace.inSeconds}s of '
        'the kill — reporting with the output captured so far',
      );
    } else {
      try {
        await Future.wait([outDone.future, errDone.future])
            .timeout(_streamDrainGrace);
      } on TimeoutException {
        // Pipes still held open by a forked descendant — keep what we've got.
        _log.fine('stream drain timed out — keeping buffered output');
      }
      await outSub.cancel();
      await errSub.cancel();
    }
    await stdoutAcc.close();
    await stderrAcc.close();

    final outTail = stdoutAcc.tail();
    final errTail = stderrAcc.tail();
    final report = StringBuffer();
    if (cancelled) {
      report.writeln('cancelled by user');
    }
    if (timedOut) {
      report.writeln('command timed out after ${timeoutSec}s '
          '(exit: $exitCode)');
    } else {
      report.writeln('exit: $exitCode');
    }
    if (killedButStuck) {
      report.writeln(
          'process did not exit after kill; output may be incomplete');
    }
    report.writeln('stdout:');
    report.write(outTail.isEmpty ? '(empty)\n' : outTail);
    report.write(stdoutAcc.summaryLine());
    report.writeln('stderr:');
    report.write(errTail.isEmpty ? '(empty)\n' : errTail);
    report.write(stderrAcc.summaryLine());
    return ToolResult(
      report.toString(),
      isError: cancelled || timedOut || exitCode != 0,
      elapsed: stopwatch.elapsed,
      timedOut: timedOut,
      emptyOutput:
          stdoutAcc.totalChars + stderrAcc.totalChars == 0,
    );
  }
}

/// One bash stream's output, bounded in memory: keeps a rolling tail (the last
/// [cap] chars, ~bytes — what the model sees) and, once the stream crosses
/// [cap], spills the FULL output to a temp file so nothing is permanently lost.
/// Mirrors pi's `OutputAccumulator` in spirit, narrower in scope.
class _BashOutput {
  _BashOutput(this.cap, this._tempDirFactory, this._label);

  final int cap;
  final Directory Function() _tempDirFactory;
  final String _label;

  final StringBuffer _tail = StringBuffer();
  int _tailChars = 0;
  final List<String> _pending = []; // pre-spill chunks, flushed to [_spill]
  IOSink? _spill;
  String? spillPath;
  bool truncated = false;
  int totalChars = 0;

  static int _counter = 0;

  void append(String chunk) {
    totalChars += chunk.length;

    // Rolling tail: trim the head once it's well past 2× the cap so memory
    // stays bounded even for multi-MB floods. The tail is the model-facing view.
    _tail.write(chunk);
    _tailChars += chunk.length;
    if (_tailChars > cap * 4) {
      final s = _tail.toString();
      final keep = s.substring(s.length - cap * 2);
      _tail
        ..clear()
        ..write(keep);
      _tailChars = keep.length;
    }

    if (_spill != null) {
      _spill!.write(chunk);
      return;
    }
    // Not yet spilling: buffer the prefix so the temp file can hold the full
    // output once we cross the threshold.
    _pending.add(chunk);
    if (totalChars > cap) {
      truncated = true;
      _openSpill();
      if (_spill != null) {
        for (final p in _pending) {
          _spill!.write(p);
        }
        _pending.clear();
      }
    }
  }

  void _openSpill() {
    try {
      _counter++;
      final file =
          File(p.join(_tempDirFactory().path, 'tina-bash-$_label-$_counter.log'));
      _spill = file.openWrite();
      spillPath = file.path;
    } catch (e) {
      _log.warning('bash spill open failed for $_label', e);
      _spill = null;
    }
  }

  /// The decoded tail to show the model (at most [cap] chars).
  String tail() {
    final s = _tail.toString();
    return s.length > cap ? s.substring(s.length - cap) : s;
  }

  /// A trailing summary line (with newline) when the stream was truncated, else
  /// an empty string.
  String summaryLine() {
    if (!truncated) return '';
    if (spillPath != null) {
      return '... (truncated: showing the last ~$cap of $totalChars bytes; '
          'full output: $spillPath)\n';
    }
    return '... (truncated at $cap bytes; showing the tail)\n';
  }

  /// Flush + close the spill file. Safe to call once the stream has ended.
  Future<void> close() async {
    final spill = _spill;
    _spill = null;
    if (spill == null) return;
    try {
      await spill.flush();
      await spill.close();
    } catch (e) {
      _log.warning('bash spill close failed for $_label', e);
    }
  }
}
