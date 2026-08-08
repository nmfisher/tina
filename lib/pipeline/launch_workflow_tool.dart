import 'package:tina_engine/tina_engine.dart';

import 'workflow_supervisor.dart';

/// The agent-callable workflow launcher. The main agent hands a task to a DOT
/// workflow (the `default` graph by default); this tool starts it as a
/// **background run** under the [WorkflowSupervisor] and returns immediately —
/// the chat stays open while the run churns, node progress streams into the
/// chat via [sink], and when the run finishes the supervisor's `onComplete`
/// hook wakes the launching conversation with a synthetic turn carrying the
/// outcome (see `SessionController.injectWorkflowResult`).
///
/// Fire-and-forget from the agent's perspective: `execute` does not await the
/// run. The agent learns the result in a follow-up turn and can cancel a
/// still-running launch with the `stop_workflow` tool.
class LaunchWorkflowTool implements Tool {
  final WorkflowSupervisor _supervisor;
  final String _conversationId;
  final AgentSink _sink;

  LaunchWorkflowTool({
    required WorkflowSupervisor supervisor,
    required String conversationId,
    required AgentSink sink,
  })  : _supervisor = supervisor,
        _conversationId = conversationId,
        _sink = sink;

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'launch_workflow',
        description: 'Launch a DOT workflow (a plan → review → parallel '
            'execute → review pipeline) in the background. The preferred '
            'way to handle substantial or multi-step work: the workflow '
            'explores, plans, has the plan independently reviewed, executes '
            'the chunks in parallel, and reviews the outcome. Node progress '
            'streams into the chat while it runs, and the chat stays open — '
            'you get a follow-up turn with the outcome when the run finishes. '
            'Use this for anything that benefits from a plan, independent '
            'review, or parallel execution; use the file tools directly for '
            'small changes and `delegate` for a single focused sub-task. '
            'Cancel a running launch with stop_workflow.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'input': {
              'type': 'string',
              'description': 'The task to hand to the workflow. Put everything '
                  'the workflow needs here — it flows in as \$input.',
            },
            'workflow': {
              'type': 'string',
              'description': 'The workflow (DOT file) to run, by name. '
                  'Defaults to "default".',
            },
          },
          'required': ['input'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final task = input['input'];
    if (task is! String || task.trim().isEmpty) {
      return ToolResult.error('launch_workflow requires a non-empty `input`.');
    }
    final workflow = (input['workflow'] as String?)?.trim().isEmpty ?? true
        ? 'default'
        : (input['workflow'] as String).trim();

    final run = _supervisor.launch(
      name: workflow,
      conversationId: _conversationId,
      sink: _sink,
      input: task,
    );

    return ToolResult('Launched workflow "$workflow" in the background '
        '(run ${run.id}). It runs to completion while the chat stays open; '
        'node progress streams into the chat, and I\'ll get a follow-up turn '
        'with the outcome when it finishes. Cancel it with stop_workflow if '
        'needed.');
  }
}

/// The agent-callable workflow stopper. Mirrors the old user-typed
/// `/workflow stop` as an agent tool: cancels a still-running background
/// launch ([WorkflowSupervisor.stop]), by run id or the most recent one.
class StopWorkflowTool implements Tool {
  final WorkflowSupervisor _supervisor;

  StopWorkflowTool({required WorkflowSupervisor supervisor})
      : _supervisor = supervisor;

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'stop_workflow',
        description: 'Cancel a running workflow launched with launch_workflow. '
            'Pass run_id to stop a specific run; omit it to stop the most '
            'recent running workflow. The run aborts at its next node '
            'boundary and you get a completion turn reporting it cancelled.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'run_id': {
              'type': 'string',
              'description': 'The id of the run to stop (from the '
                  'launch_workflow result). Defaults to the most recent '
                  'running workflow.',
            },
          },
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final id = (input['run_id'] as String?)?.trim();
    final target = id == null
        ? (_supervisor.active.isNotEmpty ? _supervisor.active.first : null)
        : _supervisor.find(id);

    if (target == null || !target.isRunning) {
      return ToolResult(
          id == null
              ? 'No running workflow to stop.'
              : 'Run $id is not running (it may already have finished).');
    }

    _supervisor.stop(target.id);
    return ToolResult(
        'Stopped workflow "${target.workflowName}" (run ${target.id}). It '
        'will abort at its next node boundary.');
  }
}
