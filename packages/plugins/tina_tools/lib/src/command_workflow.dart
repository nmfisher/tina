import 'dart:io';

import 'package:path/path.dart' as path;

import 'process_runner.dart';
import 'sandbox_home.dart';
import 'read_only_commands.dart';

String? commandWorkflow(ProcessRequest request, String workspace) {
  request = literalShellRequest(request) ?? request;
  if (request.stdin != null || request.environment != null) return null;
  final program = path.basename(request.command);
  final arguments = request.arguments;
  if (!{'dart', 'flutter'}.contains(program) || arguments.isEmpty) return null;
  final action = arguments.first;
  var prefixLength = 1;
  if (program == 'dart' && action == 'compile') {
    if (arguments.length < 2 ||
        !{'exe', 'aot-snapshot', 'jit-snapshot', 'js', 'wasm'}
            .contains(arguments[1])) return null;
    prefixLength = 2;
  } else if (program == 'flutter' && action == 'build') {
    if (arguments.length < 2 ||
        !{
          'apk',
          'appbundle',
          'ios',
          'ipa',
          'macos',
          'linux',
          'windows',
          'web',
          'bundle'
        }.contains(arguments[1])) return null;
    prefixLength = 2;
  } else if (!{'test', 'analyze', 'format'}.contains(action) ||
      program == 'flutter' && action == 'format') return null;
  final flags = switch (action) {
    'test' => {
        '--run-skipped',
        '--chain-stack-traces',
        '--no-chain-stack-traces',
        '--fail-fast',
        '--no-fail-fast',
        '--coverage',
        '--no-pub',
        '--enable-asserts',
        '--no-enable-asserts',
      },
    'analyze' => {
        '--fatal-infos',
        '--no-fatal-infos',
        '--fatal-warnings',
        '--no-fatal-warnings',
        '--no-pub',
      },
    'format' => {'--fix', '--set-exit-if-changed'},
    _ => {
        '--release',
        '--debug',
        '--profile',
        '--no-pub',
        '--no-codesign',
        '--split-per-abi',
        '--obfuscate',
        '--source-maps',
        '--no-source-maps'
      },
  };
  final values = switch (action) {
    'test' => {
        '--name',
        '-n',
        '--plain-name',
        '--tags',
        '-t',
        '--exclude-tags',
        '-x',
        '--reporter',
        '-r',
        '--timeout',
        '--concurrency',
        '-j',
        '--platform',
        '-p',
        '--test-randomize-ordering-seed',
        '--total-shards',
        '--shard-index',
      },
    'format' => {'--line-length', '-l', '--output', '-o'},
    'compile' || 'build' => {
        '--target-platform',
        '--build-name',
        '--build-number',
        '--dart-define',
        '--optimization-level'
      },
    _ => <String>{},
  };
  try {
    final root = canonicalSandboxPath(workspace);
    final cwd = canonicalSandboxPath(request.workingDirectory ?? workspace);
    if (!sandboxPathUnder(cwd, root)) return null;
    for (var index = prefixLength; index < arguments.length; index++) {
      final argument = arguments[index];
      final equals = argument.indexOf('=');
      final option = equals < 0 ? argument : argument.substring(0, equals);
      if (flags.contains(argument)) continue;
      if (values.contains(option)) {
        if (equals < 0 && ++index >= arguments.length) return null;
        continue;
      }
      if ({'compile', 'build'}.contains(action) &&
          {'-o', '--output', '-t', '--target', '--split-debug-info'}
              .contains(option)) {
        if (equals < 0 && ++index >= arguments.length) return null;
        final operand =
            equals < 0 ? arguments[index] : argument.substring(equals + 1);
        if (!sandboxPathUnder(
            canonicalSandboxPath(
                path.isAbsolute(operand) ? operand : path.join(cwd, operand)),
            root)) return null;
        continue;
      }
      if (argument.startsWith('-')) return null;
      if (!sandboxPathUnder(
          canonicalSandboxPath(
              path.isAbsolute(argument) ? argument : path.join(cwd, argument)),
          root)) return null;
    }
    return '$program ${arguments.take(prefixLength).join(' ')}';
  } on FileSystemException {
    return null;
  }
}
