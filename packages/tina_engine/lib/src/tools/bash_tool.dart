import 'execution_request.dart';
import 'execution_schema.dart';
import 'process_runner.dart';
import 'process_tool.dart';
import 'tool.dart';

export 'process_tool.dart'
    show assertCwdWithinProject, bashIsDenied, kBashDenylist;

/// Shell adapter over the shared execution lifecycle.
class BashTool extends ProcessTool {
  BashTool(
      {super.timeout,
      super.postKillGrace,
      super.processRunner,
      super.projectRoot,
      super.tempDirFactory,
      super.environment,
      super.preparedRequest});

  static int clampTimeoutSeconds(int seconds) =>
      ProcessTool.clampTimeoutSeconds(seconds);
  static const int outputByteCap = ProcessTool.outputByteCap;

  @override
  bool get usesShell => true;

  @override
  BashTool copyWith({ProcessRunner? runner, ExecutionRequest? request}) =>
      BashTool(
          timeout: timeout,
          postKillGrace: postKillGrace,
          projectRoot: projectRoot,
          tempDirFactory: tempDirFactory,
          environment: environment,
          processRunner: runner ?? processRunner,
          preparedRequest: request ?? preparedRequest);

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'bash',
        description:
            'Run a shell command via /bin/sh -c. Prefer exec for ordinary program '
            'execution; use this tool only when shell syntax is needed. Captures stdout, stderr, '
            'and exit code. Runs in the tina process cwd unless `cwd` is '
            'given. Subject to the session permission policy. Each call is a '
            'fresh shell — chain dependent steps with `&&` rather than '
            'expecting state to persist. Set `cwd` instead of prefixing `cd`. '
            'Run the actual build/test command directly: this tool already '
            'captures output, keeps a bounded tail, and spills large output '
            'to a file. Do not add redirection, echo, head, or tail solely '
            'to capture or shorten output; trailing commands can hide a failure. '
            'If a reporting wrapper is necessary, preserve the operation’s '
            'exit status and exit with it. Use the read tool to inspect saved logs.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description': 'The shell command to run.',
            },
            ...executionProperties,
          },
          'required': ['command'],
        },
      );
}
