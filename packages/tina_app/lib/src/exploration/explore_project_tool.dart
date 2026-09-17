import 'dart:convert';
import 'package:tina_engine/tina_engine.dart';
import 'exploration_workflow.dart';

/// Invocation-scoped dependencies: credentials are resolved when the tool runs,
/// and the owned HTTP service is closed on success, cancellation, or failure.
class ExplorationLease {
  final ExplorationWorkflow workflow;
  final void Function() close;
  const ExplorationLease(this.workflow, this.close);
}

class ExploreProjectTool implements Tool {
  final ExplorationLease? Function() open;
  bool _running = false;
  ExploreProjectTool({required this.open});

  @override
  ToolSchema get schema => const ToolSchema(
    name: 'explore_project',
    description:
        'Locate an implementation in this project using bounded local '
        'filename/source search and parallel Typesafe relevance judgments. '
        'Sends selected source excerpts to Typesafe. Returns JSON with paths, '
        'line ranges, excerpts, scores, coverage gaps, and separate usage. '
        'Use a focused question with likely symbol or feature names. Does not '
        'edit files or run builds. No result is not proof of absence.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'question': {'type': 'string', 'minLength': 1, 'maxLength': 2000},
      },
      'required': ['question'],
      'additionalProperties': false,
    },
  );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final question = input['question'];
    if (question is! String ||
        question.trim().isEmpty ||
        question.length > 2000 ||
        input.keys.any((key) => key != 'question')) {
      return ToolResult.error(
        'explore_project requires only a question (1–2000 characters).',
      );
    }
    if (_running)
      return ToolResult.error(
        'An exploration is already running. Wait for it to finish or cancel it first.',
      );
    _running = true;
    final cancellation = JudgmentCancellation();
    var settled = false;
    cancelSignal?.then(
      (_) {
        if (!settled) cancellation.cancel();
      },
      onError: (Object _) {
        if (!settled) cancellation.cancel();
      },
    );
    ExplorationLease? lease;
    try {
      await Future<void>.value(); // Deliver an already-completed cancel signal.
      if (cancellation.isCancelled) {
        return ToolResult.error('Exploration cancelled before dispatch.');
      }
      lease = open();
      if (lease == null) {
        return ToolResult.error(
          'Configure a Typesafe API key in /settings → Typesafe '
          'or TYPESAFE_API_KEY, then retry explore_project.',
        );
      }
      final result = await lease.workflow.run(
        question.trim(),
        cancellation: cancellation,
        onProgress: (line) => onOutput?.call('$line\n'),
      );
      return ToolResult(
        jsonEncode(result.toJson()),
        isError: result.status != 'completed',
      );
    } on JudgmentException catch (e) {
      return ToolResult.error(
        'Exploration failed: ${e.failure.name}. '
        '${e.failure == JudgmentFailure.invalidRequest ? "Use a Git project and a focused question; check the configured Typesafe model." : "Check Typesafe settings or retry later."}',
      );
    } on ArgumentError {
      return ToolResult.error(
        'Invalid Typesafe configuration. Check /settings → Typesafe.',
      );
    } finally {
      settled = true;
      try {
        lease?.close();
      } finally {
        _running = false;
      }
    }
  }
}
