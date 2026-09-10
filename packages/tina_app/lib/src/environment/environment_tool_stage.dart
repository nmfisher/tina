import 'package:tina_engine/tina_engine.dart';

/// Advertised schemas never depend on the phase. Execution is gated locally;
/// a fresh instance belongs to one admitted environment turn.
class EnvironmentToolStage extends ToolRegistry {
  final ToolRegistry _base;
  late final ToolRegistry _catalog;
  late final Map<String, Tool> _inspectionTools;
  late final Tool _transition;
  bool _inspected = false;
  bool _executing = false;

  /// Register on the normal conversation too, so entering/leaving an
  /// environment turn does not change the catalog or cache prefix.
  static Tool get transitionTool => _BeginExecution(null);

  EnvironmentToolStage(this._base) : super(const []) {
    _transition = _BeginExecution(this);
    _catalog = ToolRegistry([
      ..._base.all,
      if (_base['begin_environment_execution'] == null) transitionTool,
    ]);
    _inspectionTools = {
      for (final tool in _base.all)
        if (_inspectionNames.contains(tool.schema.name))
          tool.schema.name: _ObservedInspection(tool, () => _inspected = true),
      if (_base['delegate'] case final DelegateTool delegate)
        'delegate': _ObservedInspection(
          delegate.readOnly(),
          () => _inspected = true,
        ),
    };
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
  Iterable<Tool> get all => _catalog.all;
  @override
  List<ToolSchema> get schemas => _catalog.schemas;
  @override
  Tool? operator [](String name) => forStep()[name];
  @override
  String? executionBlock(String name, Map<String, dynamic> input) =>
      forStep().executionBlock(name, input);
  @override
  ToolRegistry forStep() => _EnvironmentStep(this, _inspected, _executing);
}

class _EnvironmentStep extends ToolRegistry {
  final EnvironmentToolStage stage;
  final bool inspected;
  final bool executing;
  _EnvironmentStep(this.stage, this.inspected, this.executing)
    : super(const []);
  @override
  Iterable<Tool> get all => stage.all;
  @override
  List<ToolSchema> get schemas => stage.schemas;
  @override
  Tool? operator [](String name) {
    if (name == 'begin_environment_execution') return stage._transition;
    return (!executing ? stage._inspectionTools[name] : null) ??
        stage._base[name];
  }

  @override
  String? executionBlock(String name, Map<String, dynamic> input) {
    if (name == 'begin_environment_execution') {
      if (executing) return 'Environment execution is already enabled.';
      return inspected
          ? null
          : 'Inspect the repository with read, ls, grep, glob, stat, which, or git first. Submit the execution plan on a later step, after seeing the inspection results.';
    }
    if (executing) return null;
    if (name == 'delegate' && stage._inspectionTools.containsKey(name)) {
      final entries = input['delegations'];
      if (entries is List &&
          entries.any((entry) => entry is Map && entry['tools'] == 'full')) {
        return 'Environment scouts must use the read-only profile during inspection.';
      }
      return null;
    }
    if (stage._inspectionTools.containsKey(name)) return null;
    return '$name is disabled during environment inspection. Use read, ls, grep, glob, stat, which, or git. After inspection, submit findings and setup/build/test commands with begin_environment_execution. Do not retry with bash.';
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
  final EnvironmentToolStage? _stage;
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
    final stage = _stage;
    if (stage == null)
      return ToolResult.error(
        'This transition is only available during an environment setup task.',
      );
    if (!stage._inspected) {
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
      stage._executing = true;
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
