import 'package:tina_core/tina_core.dart';

import 'process_runner.dart';
import 'process_tool_base.dart';
import 'tool_input.dart';

/// `bash` — run a **command string** in a shell.
///
/// The tool's own signature says what it is: the model writes one string and
/// the shell interprets all of it, so the command can do anything the
/// process can do. Argument checking cannot make that safe and this tool
/// does not pretend to try — the *runner* it is handed decides per call
/// whether the command runs at all (in `readOnly` everything is refused;
/// other modes require approval or a human session grant). That is also why this is not `exec` with a string mode bolted
/// on: the two shapes are kept apart, here and in [ExecTool].
class BashTool extends ProcessToolBase {
  /// The runner this tool starts processes through. Enforcement lives on
  /// the runner; the tool carries no policy of its own.
  @override
  final ProcessRunner runner;

  /// The directory the command runs in. Null means the process inherits the
  /// host's cwd.
  final String? workingDirectory;

  /// The shell that interprets the command string, with the flag that hands
  /// it the script. Defaults to `/bin/sh -c` on POSIX.
  final String shell;
  final String shellFlag;

  /// Extra environment for the child, on top of the inherited environment.
  final Map<String, String>? environment;

  BashTool({
    required this.runner,
    this.workingDirectory,
    this.shell = '/bin/sh',
    this.shellFlag = '-c',
    this.environment,
  });

  @override
  Duration get defaultTimeout => const Duration(minutes: 10);

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'bash',
        description:
            'Run a shell command string and capture its exit code, stdout and '
            'stderr. The string is interpreted whole by the shell — pipes, '
            'expansions and redirects all apply — so it can do anything the '
            'process can. Prefer `exec` when you have a program and literal '
            'arguments. Each call is checked against the session\'s '
            'permissions before anything runs; a refusal arrives as this '
            'call\'s error result. New user input makes a running command yield '
            'a job ID without stopping it; use process to inspect, wait or cancel.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description': 'The shell command string to run.',
            },
            'timeout': {
              'type': 'integer',
              'description': 'Seconds to wait before the command is killed. '
                  'Default 600.',
            },
          },
          'required': ['command'],
        },
      );

  @override
  Future<ToolResult> execute(Map<String, dynamic> input,
      {ProcessControl? control}) async {
    final String command;
    try {
      command = requiredString(input, 'command');
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    }
    return runRequest((
      command: shell,
      arguments: [shellFlag, command],
      workingDirectory: workingDirectory,
      environment: environment,
      stdin: null,
      timeout: timeoutFrom(input) ?? defaultTimeout,
    ), control: control);
  }
}
