import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'execution_request.dart';
import 'process_runner.dart';
import 'sandbox_runner.dart';
import 'tool.dart';
import 'tool_input.dart';

/// Read-only observations, not inferred authority to write any reported path.
class ExecutionInfoTool implements Tool {
  final String projectRoot;
  final Map<String, String> environment;
  final ProcessRunner runner;

  ExecutionInfoTool(
      {required this.projectRoot,
      required Map<String, String> environment,
      required this.runner})
      : environment = Map.unmodifiable(environment);

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'execution_info',
        description:
            'Inspect the execution environment, sandbox backend, network '
            'policy, writable directories and cache locations without running a '
            'command. Optionally resolve an executable. Reports only selected path '
            'settings, never the full environment. A cache location is not a write grant.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'executable': {'type': 'string'},
          }
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final sandbox = runner is SandboxedProcessRunner
        ? runner as SandboxedProcessRunner
        : null;
    final name = optionalString(input, 'executable');
    final home = environment['HOME'];
    String? resolver;
    try {
      resolver = File('/etc/resolv.conf').resolveSymbolicLinksSync();
    } on FileSystemException {/* Report absence without guessing. */}
    return ToolResult(const JsonEncoder.withIndent('  ').convert({
      'projectRoot': projectRoot,
      'sandbox': sandbox?.backendDescription ??
          'pass-through: no filesystem confinement',
      'network': sandbox?.networkIsolated == true
          ? 'isolated'
          : 'not isolated by Tina',
      if (Platform.isLinux) 'resolverFile': resolver,
      'pathSettings': {
        for (final key in [
          'HOME',
          'PATH',
          'TMPDIR',
          'PUB_CACHE',
          'XDG_CACHE_HOME',
          'FLUTTER_ROOT'
        ])
          if (environment.containsKey(key)) key: environment[key]
      },
      'pubCache': environment['PUB_CACHE'] ??
          (home == null ? null : p.join(home, '.pub-cache')),
      'writableDirectories': sandbox?.accessPolicy.effectiveWritablePaths ?? [],
      'readOnlyOverrides': sandbox?.accessPolicy.readOnlyPaths ?? [],
      if (name != null)
        'executable':
            resolveExecutionExecutable(name, environment, projectRoot),
      'note': 'Cache paths are observations, not write grants. DNS/network failures '
          'and dependency resolution failures do not establish a filesystem denial.',
    }));
  }
}
