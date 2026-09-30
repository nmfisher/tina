import 'package:tina_core/tina_core.dart';
import 'tool_descriptions.dart';

import 'process_runner.dart';
import 'process_tool_base.dart';
import 'tool_input.dart';

/// `exec` — run a program with literal arguments, no shell.
///
/// Arguments are passed unchanged to the selected program. No shell quoting,
/// expansion or implicit option separator is applied. Permission and OS
/// sandbox enforcement still wrap every invocation.
class ExecTool extends ProcessToolBase {
  /// The runner this tool starts processes through. Enforcement lives on
  /// the runner; the tool carries no policy of its own.
  @override
  final ProcessRunner runner;

  /// The directory the program runs in. Null means the process inherits the
  /// host's cwd.
  final String? workingDirectory;

  /// Extra environment for the child, on top of the inherited environment.
  final Map<String, String>? environment;

  ExecTool({
    required this.runner,
    this.workingDirectory,
    this.environment,
  });

  @override
  Duration get defaultTimeout => const Duration(minutes: 10);

  @override
  ToolSchema get schema => const ToolSchema(
        describe: describeExec,
        name: 'exec',
        description:
            'Run a program directly with literal arguments, without a shell. '
            'Captures stdout, stderr and the exit code. Shell expansions, '
            'pipes and redirects are not interpreted. Arguments are passed '
            'unchanged, including options and subcommands; no -- is inserted. '
            'Include an option separator yourself only where the program '
            'supports and needs it. Prefer `bash` for anything needing shell '
            'syntax. Each call is checked against the session\'s permissions '
            'before anything runs; a refusal arrives as this call\'s error '
            'result. New user input makes a running command yield a job ID '
            'without stopping it; use process to inspect, wait or cancel.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'network': {
              'type': 'boolean',
              'description':
                  'Request network access for this subprocess and its children. Reviewed with execution under the current permission mode; filesystem sandbox stays active.'
            },
            'network_reason': {
              'type': 'string',
              'description':
                  'Required when network is true. Explain why network access is needed.'
            },
            'program': {
              'type': 'string',
              'description': 'Program to run (looked up on PATH).',
            },
            'args': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Argument list passed unchanged to the program, including '
                      'options and subcommands. No shell interpretation.',
            },
            'timeout': {
              'type': 'integer',
              'description':
                  'Seconds to wait before the program is killed. Default 600.',
            },
          },
          'required': ['program'],
        },
      );

  @override
  Future<ToolResult> execute(Map<String, dynamic> input,
      {ProcessControl? control}) async {
    final String program;
    final List<String> modelArgs;
    try {
      program = requiredString(input, 'program');
      final raw = input['args'];
      if (raw == null) {
        modelArgs = const [];
      } else {
        if (raw is! List || raw.any((e) => e is! String)) {
          return ToolResult.error('args must be a list of strings');
        }
        modelArgs = List<String>.from(raw);
      }
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    }

    return runRequest((
      command: program,
      arguments: modelArgs,
      workingDirectory: workingDirectory,
      environment: environment,
      stdin: null,
      timeout: timeoutFrom(input) ?? defaultTimeout,
    ), control: control, input: input);
  }
}
