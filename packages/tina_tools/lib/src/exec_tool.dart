import 'package:tina_core/tina_core.dart';

import 'fenced_arguments.dart';
import 'process_runner.dart';
import 'process_tool_base.dart';
import 'tool_input.dart';

/// `exec` — run a program with literal arguments, no shell.
///
/// The tool's own signature says what it is, and the shape is the safety
/// property: the model names a **program** and supplies **values**, and this
/// tool assembles the argv itself. Model values are fenced — passed after
/// `--`, where POSIX argument parsing requires the program to treat them as
/// positionals — so a model value *cannot* arrive as an option: a string
/// like `--pre=rm -rf /` reaches the program as inert data, never as a
/// flag. The fence is structural ([FencedArguments] is the only way argv
/// leaves this tool), not a convention each call site has to remember.
///
/// That is the whole distinction from [BashTool], and why this is not bash
/// with an argv mode bolted on: there the model writes the command string
/// whole and it can do anything; here the model cannot form an option out
/// of its own values.
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
        name: 'exec',
        description:
            'Run a program directly with literal arguments, without a shell. '
            'Captures stdout, stderr and the exit code. Shell expansions, '
            'pipes and redirects are not interpreted; model-supplied values '
            'are passed as data after the `--` fence, so they can never be '
            'read as options. Prefer `bash` for anything needing shell '
            'syntax. Each call is checked against the session\'s permissions '
            'before anything runs; a refusal arrives as this call\'s error '
            'result.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'program': {
              'type': 'string',
              'description': 'Program to run (looked up on PATH).',
            },
            'args': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Literal argument values. Passed as data after the `--` '
                      'fence — never read as options, whatever they look like.',
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
  Future<ToolResult> execute(Map<String, dynamic> input) async {
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

    // The fence: every model value goes after `--`. There is no code path
    // that emits a model value before it.
    final argv = FencedArguments()..forValues(modelArgs);

    return runRequest((
      command: program,
      arguments: argv.build(),
      workingDirectory: workingDirectory,
      environment: environment,
      stdin: null,
      timeout: timeoutFrom(input) ?? defaultTimeout,
    ));
  }
}

extension _FenceAll on FencedArguments {
  /// Adds every value as fenced model data. Named for the call site's
  /// intent: this is all of them, unconditionally.
  void forValues(List<String> values) {
    for (final v in values) {
      this.value(v);
    }
  }
}
