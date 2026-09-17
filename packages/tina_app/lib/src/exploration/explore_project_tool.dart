import 'dart:convert';
import 'package:tina_engine/tina_engine.dart';
import 'exploration_workflow.dart';
import 'models.dart';

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
        'Filter a repository for the main agent. Rank a compact file manifest, '
        'then selectively check content until useful evidence is found. Large '
        'files are split into bounded overlapping regions. Returns paths, line '
        'ranges and source excerpts. mode=auto may hand off clear small candidates '
        'without Typesafe content verification; verify always checks content; '
        'rank sends names only and returns candidate paths. Names and selected '
        'content are sent to Typesafe. Unchecked files remain unknown. Results are '
        'cached locally against unchanged inputs; refresh=true bypasses reuse.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'question': {'type': 'string', 'minLength': 1, 'maxLength': 2000},
        'mode': {
          'type': 'string',
          'enum': ['auto', 'verify', 'rank'],
        },
        'max_results': {'type': 'integer', 'minimum': 1, 'maximum': 8},
        'refresh': {'type': 'boolean'},
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
    final mode = input['mode'] ?? 'auto';
    final maxResults = input['max_results'] ?? 1;
    final refresh = input['refresh'] ?? false;
    if (question is! String ||
        question.trim().isEmpty ||
        question.length > 2000 ||
        !['auto', 'verify', 'rank'].contains(mode) ||
        refresh is! bool ||
        maxResults is! int ||
        maxResults < 1 ||
        maxResults > 8 ||
        input.keys.any(
          (key) =>
              !['question', 'mode', 'max_results', 'refresh'].contains(key),
        )) {
      return ToolResult.error(
        'Use question (1–2000 characters), optional mode (auto/verify/rank), max_results (1–8), and refresh (boolean).',
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
        mode: ExplorationMode.values.byName(mode as String),
        maxResults: maxResults,
        refresh: refresh,
        cancellation: cancellation,
        onProgress: (line) => onOutput?.call('$line\n'),
      );
      return ToolResult(
        jsonEncode(result.toJson()),
        isError: result.status != 'completed' && result.status != 'partial',
      );
    } on JudgmentException catch (e) {
      return ToolResult.error(
        'Exploration failed: ${e.failure.name}. '
        '${e.failure == JudgmentFailure.invalidRequest ? "Use a Git project and a focused question; check the configured Typesafe model." : "Check Typesafe settings or retry later."}',
      );
    } on ArgumentError {
      return ToolResult.error(
        'Invalid Typesafe configuration. Check the [typesafe] settings, including exploration limits.',
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
