import 'dart:async';
import 'package:tina_core/tina_core.dart';
import 'process_runner.dart';
import 'process_tool_base.dart';
import 'tool.dart';
import 'tool_input.dart';

enum _Wake { input, cancelled, timer }

final class _Job {
  _Job(this.id);
  final String id;
  final cancel = Completer<void>();
  final started = Completer<void>();
  late Future<RunOutcome> done;
  RunOutcome? outcome;
  bool detached = false;
  String output = '';
  void stop() {
    if (!cancel.isCompleted) cancel.complete();
  }

  void capture(String text, bool error) {
    output += '${error ? '[stderr] ' : ''}$text';
    if (output.length > 65536) output = output.substring(output.length - 65536);
  }
}

/// Job lifetimes belong to this plugin, independently of a foreground turn.
/// The inner runner still performs every permission and sandbox check.
final class ProcessJobs implements ProcessRunner {
  ProcessJobs(this.inner);
  static int _nextOwner = 0;
  final _owner =
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${++_nextOwner}';
  final ProcessRunner inner;
  final _jobs = <String, _Job>{};
  int _next = 0;
  bool _closed = false;

  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    if (_closed) return const CommandRefused('process jobs are closed');
    final job = _Job('process-$_owner-${++_next}');
    _jobs[job.id] = job;
    job.done = Future.sync(() => inner.run(request,
        control: ProcessControl(
          isCancelled: () => job.cancel.isCompleted,
          whenCancelled: job.cancel.future,
          onStarted: () {
            if (!job.started.isCompleted) job.started.complete();
            control?.onStarted?.call();
          },
          onOutput: (text, {isError = false}) {
            job.capture(text, isError);
            if (!job.detached) control?.onOutput?.call(text, isError: isError);
          },
        ))).then((result) {
      job.outcome = result;
      return result;
    }, onError: (Object error) {
      final result = CommandCompleted(
          exitCode: 127, stdout: '', stderr: 'process failed: $error');
      job.outcome = result;
      return result;
    });
    if (control?.isCancelled?.call() == true) job.stop();
    final cancellation = control?.whenCancelled;
    if (cancellation != null) {
      unawaited(Future.any([cancellation, job.done]).then((_) {
        if (!job.detached && control?.isCancelled?.call() == true) job.stop();
      }));
    }
    final result = await _wait(job, control);
    if (result is! CommandRunning) _jobs.remove(job.id);
    return result;
  }

  Future<RunOutcome> _wait(_Job job, ProcessControl? control,
      {Duration? duration}) async {
    if (job.outcome != null) return job.outcome!;
    final wake = <Future<Object?>>[job.done];
    final pending = control?.whenInputPending;
    if (pending != null) {
      // Never call an awaiting permission decision a running process.
      wake.add(
          job.started.future.then((_) => pending).then((_) => _Wake.input));
    }
    Timer? timer;
    if (duration != null) {
      final elapsed = Completer<void>();
      timer = Timer(duration, elapsed.complete);
      wake.add(elapsed.future.then((_) => _Wake.timer));
    }
    final cancellation = control?.whenCancelled;
    if (cancellation != null)
      wake.add(cancellation.then((_) => _Wake.cancelled));
    try {
      final result = await Future.any(wake);
      if (result == _Wake.cancelled || control?.isCancelled?.call() == true) {
        if (!job.detached) {
          job.stop();
          return await job.done;
        }
        return const CommandCompleted(
            exitCode: -9,
            stdout: '',
            stderr: 'cancelled waiting for process',
            cancelled: true);
      }
      if (result is RunOutcome) return result;
      job.detached = true;
      return CommandRunning(job.id, job.output);
    } finally {
      timer?.cancel();
    }
  }

  Future<ToolResult> inspect(Map<String, dynamic> input,
      {ProcessControl? control}) async {
    final id = requiredString(input, 'job_id');
    final job = _jobs[id];
    if (job == null)
      return ToolResult.error(
          'No live job $id in this session. Do not automatically rerun the command.');
    final action = input['action'] ?? 'status';
    switch (action) {
      case 'cancel':
        job.stop();
        return processOutcomeResult(await job.done);
      case 'wait':
        final ms = optionalInt(input, 'wait_ms');
        if (ms != null && ms < 0)
          return ToolResult.error('wait_ms must be nonnegative');
        return processOutcomeResult(await _wait(job, control,
            duration: ms == null ? null : Duration(milliseconds: ms)));
      case 'status':
        return processOutcomeResult(
            job.outcome ?? CommandRunning(id, job.output));
      default:
        return ToolResult.error('action must be status, wait or cancel');
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final job in _jobs.values) {
      job.stop();
    }
    await Future.wait([for (final job in _jobs.values) job.done]);
    _jobs.clear();
  }
}

final class ProcessJobTool implements Tool {
  ProcessJobTool(this.jobs);
  final ProcessJobs jobs;
  @override
  ToolSchema get schema => const ToolSchema(
          name: 'process',
          description:
              'Inspect, wait for, or cancel a background process job from bash/exec. '
              'Waiting yields immediately when new user input arrives. Jobs belong to this session and do not survive exit.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'job_id': {'type': 'string'},
              'action': {
                'type': 'string',
                'enum': ['status', 'wait', 'cancel']
              },
              'wait_ms': {'type': 'integer', 'minimum': 0},
            },
            'required': ['job_id']
          });
  @override
  Future<ToolResult> execute(Map<String, dynamic> input,
      {ProcessControl? control}) async {
    try {
      return await jobs.inspect(input, control: control);
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    }
  }
}
