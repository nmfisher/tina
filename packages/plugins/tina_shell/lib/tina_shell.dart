import 'dart:async';
import 'dart:io';

import 'package:tina_core/tina_core.dart';
import 'package:tina_engine_2/tina_engine_2.dart' show AgentPlugin;
import 'package:tina_tools/tina_tools.dart';

/// Commands explicitly entered by the user. The process runner provides
/// pipes, cancellation and bounded capture; model approval policy and the
/// OS sandbox are not part of this path.
final class ShellPlugin extends AgentPlugin {
  ShellPlugin({
    required this.terminal,
    required this.workingDirectory,
    ProcessRunner runner = const IoProcessRunner(),
    String? shell,
    this.timeout = const Duration(minutes: 10),
  })  : shell = shell ?? _defaultShell(),
        _jobs = ProcessJobs(runner);

  @override
  String get id => 'tina/shell';
  final Terminal terminal;
  final String workingDirectory;
  final String shell;
  final Duration timeout;
  final ProcessJobs _jobs;
  Completer<void>? _cancelled;
  bool _closed = false;

  @override
  List<Command> get commands => [
        Command(
          name: 'shell',
          inputPrefix: '!',
          description:
              'Run !command with your shell permissions, without a model call',
          handler: run,
          cancel: cancel,
          allowWhileRunning: true,
        ),
      ];

  Future<void> run(String command) async {
    if (_closed) return;
    if (command.trim().isEmpty) {
      terminal.writeln('Usage: !command (or /shell command)');
      return;
    }
    if (_cancelled != null) {
      terminal.writeln('A shell command is already running in this session.');
      return;
    }
    final cancelled = Completer<void>();
    _cancelled = cancelled;
    try {
      _write('!$command');
      final outcome = await _jobs.run((
        command: shell,
        arguments: [Platform.isWindows ? '/c' : '-c', command],
        workingDirectory: workingDirectory,
        environment: null,
        stdin: null,
        timeout: timeout,
      ),
          control: ProcessControl(
            isCancelled: () => cancelled.isCompleted,
            whenCancelled: cancelled.future,
          ));
      if (!_closed) _write(processOutcomeResult(outcome).content);
    } finally {
      _cancelled = null;
    }
  }

  void cancel() {
    final cancelled = _cancelled;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
  }

  static String _defaultShell() {
    final configured =
        Platform.environment[Platform.isWindows ? 'COMSPEC' : 'SHELL'];
    return configured != null && configured.isNotEmpty
        ? configured
        : (Platform.isWindows ? 'cmd.exe' : '/bin/sh');
  }

  // A command can emit terminal controls and megabytes of output. Only plain,
  // bounded lines reach the frontend, which owns all terminal rendering.
  void _write(String text) {
    final clean = text
        .replaceAll(RegExp(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)'), '')
        .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '')
        .replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]'), '')
        .replaceAll('\t', '    ');
    final bounded = clean.length > 65536 ? clean.substring(0, 65536) : clean;
    final lines = bounded.split('\n');
    for (final line in lines.take(200)) {
      terminal.writeln(line);
    }
    if (clean.length > bounded.length || lines.length > 200) {
      terminal.writeln('… (shell output truncated)');
    }
  }

  @override
  void closeSession() {
    _closed = true;
    cancel();
    unawaited(_jobs.close());
  }
}
