import 'package:tina_engine/tina_engine.dart';

/// A fresh instance belongs to one admitted environment turn. The underlying
/// conversation registry is never mutated, including on cancellation or error.
class EnvironmentToolStage extends ToolRegistry {
  final ToolRegistry _base;
  late final List<Tool> _inspectionTools;
  late final Tool _transition;
  bool _inspected = false;
  bool _executing = false;

  EnvironmentToolStage(this._base) : super(const []) {
    _inspectionTools = [
      for (final tool in _base.all) ...[
        if (_inspectionNames.contains(tool.schema.name))
          _ObservedInspection(tool, () => _inspected = true),
        // Only the known await-driven delegate can spawn scouts. Do not
        // admit arbitrary launch/channel/plugin tools through this boundary.
        if (tool is DelegateTool)
          _ObservedInspection(tool.readOnly(), () => _inspected = true),
      ],
    ];
    _transition = _BeginExecution(this);
  }

  static const _inspectionNames = {
    'read',
    'ls',
    'stat',
    'which',
    'glob',
    'grep',
    'search',
    'git',
    'fetch',
    'web_search',
    'repo_structure',
    'list_regions',
    'read_summary',
    'query_region',
    'broadcast_region',
  };

  @override
  Iterable<Tool> get all => _executing
      ? _base.all
      : [..._inspectionTools, if (_inspected) _transition];

  @override
  List<ToolSchema> get schemas => all.map((tool) => tool.schema).toList();

  @override
  Tool? operator [](String name) {
    for (final tool in all) {
      if (tool.schema.name == name) return tool;
    }
    return null;
  }
}

class _ObservedInspection implements Tool {
  final Tool _inner;
  final void Function() _onSuccess;
  _ObservedInspection(this._inner, this._onSuccess);

  @override
  ToolSchema get schema => _inner.schema;

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final result = await _inner.execute(
      input,
      cancelSignal: cancelSignal,
      onOutput: onOutput,
    );
    if (!result.isError) _onSuccess();
    return result;
  }
}

class _BeginExecution implements LocalControlTool {
  final EnvironmentToolStage _stage;
  _BeginExecution(this._stage);

  @override
  ToolSchema get schema => const ToolSchema(
    name: 'begin_environment_execution',
    description:
        'Finish environment inspection and enable the conversation’s '
        'normal execution tools on the next step. Summarize repository findings '
        'and identify setup, build, and test commands (or explain why a check '
        'does not apply). This records a plan; it does not execute commands '
        'or approve actions. Tool permissions still apply.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'findings': {
          'type': 'string',
          'description': 'What repository inspection established.',
        },
        'setup': {
          'type': 'string',
          'description': 'Setup commands, or why none are needed.',
        },
        'build': {
          'type': 'string',
          'description': 'Build commands, or why none apply.',
        },
        'test': {
          'type': 'string',
          'description': 'Test commands, or why none apply.',
        },
      },
      'required': ['findings', 'setup', 'build', 'test'],
    },
  );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    if (!_stage._inspected) {
      return ToolResult.error(
        'Inspect the repository before enabling execution.',
      );
    }
    try {
      final plan = {
        for (final key in ['findings', 'setup', 'build', 'test'])
          key: requiredString(input, key).trim(),
      };
      if (plan.values.any((value) => value.isEmpty)) {
        return ToolResult.error(
          'Each plan field must contain findings, commands, or a reason no check applies.',
        );
      }
      _stage._executing = true;
      return ToolResult(
        'Environment execution phase started.\n'
        '${plan.entries.map((entry) => '${entry.key}: ${entry.value}').join('\n')}\n'
        'Use the normal tools and approval policy to run these checks and '
        'write .tina/ENVIRONMENT.md. Nothing has been run or approved by this transition.',
      );
    } on ToolValidationException catch (e) {
      return ToolResult.error(e.message);
    }
  }
}
