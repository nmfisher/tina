import 'execution_schema.dart';
import 'execution_request.dart';
import 'process_runner.dart';
import 'process_tool.dart';
import 'tool.dart';

/// Direct argv execution; shares the shell tool's permissions and lifecycle.
class ExecTool extends ProcessTool {
  ExecTool(
      {super.timeout,
      super.postKillGrace,
      super.processRunner,
      super.projectRoot,
      super.tempDirFactory,
      super.environment,
      super.preparedRequest});

  @override
  bool get usesShell => false;

  @override
  ExecTool copyWith({ProcessRunner? runner, ExecutionRequest? request}) =>
      ExecTool(
          timeout: timeout,
          postKillGrace: postKillGrace,
          projectRoot: projectRoot,
          tempDirFactory: tempDirFactory,
          environment: environment,
          processRunner: runner ?? processRunner,
          preparedRequest: request ?? preparedRequest);

  @override
  ToolSchema get schema {
    return ToolSchema(
      name: 'exec',
      description:
          'Run a program directly with literal arguments, without a shell. '
          'Prefer this for setup, builds, tests, and package installation. '
          'Captures stdout, stderr and the program exit code; no echo/tail wrappers '
          'are needed. Shell expansions, pipes and redirects are not interpreted. '
          'Preserves HOME and cache settings by default. Uses the same command '
          'approval and sandbox access policy as bash.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'executable': {
            'type': 'string',
            'description': 'Program name on PATH or path to executable.'
          },
          'args': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Literal arguments, each as a separate string.'
          },
          ...executionProperties,
        },
        'required': ['executable'],
      },
    );
  }
}
