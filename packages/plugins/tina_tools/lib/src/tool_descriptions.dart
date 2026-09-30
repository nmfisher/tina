import 'package:tina_core/tina_core.dart';
import 'process_runner.dart';

/// Quote an argv for display only. Execution always keeps the original list.
String commandText(String program, Iterable<Object?> args) =>
    [program, ...args].map((value) {
      final text = '$value';
      return RegExp(r'^[a-zA-Z0-9_./:=@%+,\-]+$').hasMatch(text)
          ? text
          : "'${text.replaceAll("'", "'\\''")}'";
    }).join(' ');

String _path(Map<String, dynamic> input) =>
    '${input['filePath'] ?? input['path'] ?? '.'}';
ToolDescription describeRead(Map<String, dynamic> input) =>
    ToolDescription(title: 'Read file', target: _path(input), fields: {
      if (input['offset'] != null) 'Start line': '${input['offset']}',
      if (input['limit'] != null) 'Lines': '${input['limit']}',
    });
ToolDescription describeWrite(Map<String, dynamic> input) =>
    ToolDescription(title: 'Write file', target: _path(input));
ToolDescription describeEdit(Map<String, dynamic> input) =>
    ToolDescription(title: 'Edit file', target: _path(input));
ToolDescription describeLs(Map<String, dynamic> input) =>
    ToolDescription(title: 'List files', target: _path(input));
ToolDescription describeStat(Map<String, dynamic> input) =>
    ToolDescription(title: 'Inspect file', target: _path(input));
ToolDescription describeGlob(Map<String, dynamic> input) => ToolDescription(
    title: 'Find files',
    target: '${input['pattern'] ?? ''}',
    fields: {'Directory': _path(input)});
ToolDescription describeBash(Map<String, dynamic> input) => ToolDescription(
    title: 'Run shell command',
    target: '${input['command'] ?? ''}',
    fields: {'Command': '${input['command'] ?? ''}'});
ToolDescription describeExec(Map<String, dynamic> input) {
  final program =
      '${input['program'] ?? input['executable'] ?? '(unknown program)'}';
  final args = input['args'] is List ? input['args'] as List : const [];
  final command = commandText(program, args);
  final base = program.split('/').last;
  final titles = {
    'ls': 'List files',
    'grep': 'Search file contents',
    'rg': 'Search file contents',
    'find': 'Find files',
    'sed': 'Run sed',
    'cat': 'Read files',
    'head': 'Read the start of a file',
    'tail': 'Read the end of a file',
  };
  // Only identify a Git action when the actual first argument is a subcommand.
  // Flags/global options and shell strings use the honest generic fallback.
  final git = base == 'git' && args.isNotEmpty
      ? switch (args.first) {
          'push' => 'Push Git changes',
          'fetch' => 'Fetch Git changes',
          'pull' => 'Pull Git changes',
          'status' => 'Check Git status',
          'diff' => 'Compare Git changes',
          'log' => 'Read Git history',
          'add' => 'Stage Git changes',
          'commit' => 'Commit Git changes',
          'checkout' => 'Run Git checkout',
          'switch' => 'Switch Git branch',
          'branch' => 'Manage Git branches',
          'merge' => 'Merge Git changes',
          'rebase' => 'Rebase Git changes',
          'reset' => 'Reset Git state',
          _ => null,
        }
      : null;
  return ToolDescription(
      title: git ?? titles[base] ?? 'Run $base',
      target: command,
      fields: {'Command': command});
}

ToolDescription describeProcess(Map<String, dynamic> input) => ToolDescription(
    title: switch (input['action']) {
      'cancel' => 'Stop background process',
      'wait' => 'Wait for background process',
      _ => 'Check background process',
    },
    target: '${input['job_id'] ?? input['id'] ?? ''}');

ToolDescription describeCommandRequest(ProcessRequest request) {
  if ({'sh', 'bash'}.contains(request.command.split('/').last) &&
      request.arguments.length == 2 &&
      request.arguments.first == '-c') {
    return describeBash({'command': request.arguments.last});
  }
  return describeExec({'program': request.command, 'args': request.arguments});
}
