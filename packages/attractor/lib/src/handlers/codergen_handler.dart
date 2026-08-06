import '../codergen_backend.dart';
import '../node_handler.dart';

/// The default LLM task handler (`box`). Expands `$goal` in the prompt,
/// assembles a preamble from the run context's prior-node outputs, delegates
/// to the [CodergenBackend], then writes the prompt/response/status and
/// returns the outcome.
///
/// The backend may return an explicit [Outcome] (e.g. an autonomous reviewer's
/// verdict); otherwise the node is a success whose response is stored under
/// `context.<nodeId>` for downstream nodes.
class CodergenHandler implements NodeHandler {
  final CodergenBackend backend;

  CodergenHandler(this.backend);

  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
  }) async {
    // 1. Resolve + expand the prompt (falls back to label).
    final rawPrompt = node.prompt.isNotEmpty ? node.prompt : node.label;
    final prompt = _expandGoal(rawPrompt, graph.goal);

    // 2. Assemble carryover context from prior nodes.
    final preamble = buildPreamble(context);

    // 3. Write the prompt for the audit trail.
    // 4. Run the backend.
    final CodergenResult result;
    try {
      result = await backend.run(
        node: node,
        role: node.role,
        prompt: prompt,
        preamble: preamble,
        context: context,
        cancelSignal: cancelSignal,
      );
    } catch (e) {
      final fail = Outcome.fail('codergen backend error: $e');
      await runStore.writeNode(
          nodeId: node.id, outcome: fail, prompt: prompt, response: '');
      return fail;
    }

    final responseText = result.text;

    // 5. Build the outcome. Always record this node's output under its id, plus
    //    the spec's last_stage/last_response bookkeeping. Merge with any
    //    explicit outcome the backend returned (e.g. a verdict).
    final base = result.outcome ??
        const Outcome.success();
    final updates = <String, String>{
      node.id: responseText,
      'last_stage': node.id,
      'last_response': _truncate(responseText, 200),
      ...base.contextUpdates,
    };
    final outcome = Outcome(
      status: base.status,
      preferredLabel: base.preferredLabel,
      suggestedNextIds: base.suggestedNextIds,
      contextUpdates: updates,
      notes: base.notes.isEmpty ? 'stage completed: ${node.id}' : base.notes,
      failureReason: base.failureReason,
    );

    // 6. Persist + return.
    await runStore.writeNode(
      nodeId: node.id,
      outcome: outcome,
      prompt: prompt,
      response: responseText,
    );
    return outcome;
  }
}

/// Render the run context as labeled sections of prior work. Engine-managed
/// keys ([Context.internalKeys]) are skipped — only the prior nodes' outputs
/// (and any workflow-set values) are carried forward.
String buildPreamble(Context context) {
  if (context.isEmpty) return '';
  final buf = StringBuffer();
  for (final entry in context.orderedEntries) {
    if (Context.internalKeys.contains(entry.key)) continue;
    if (entry.key.startsWith('internal.')) continue;
    if (entry.value.isEmpty) continue;
    buf.writeln('--- ${entry.key} ---');
    buf.writeln(entry.value);
    buf.writeln();
  }
  return buf.toString().trimRight();
}

String _expandGoal(String prompt, String goal) =>
    goal.isEmpty ? prompt : prompt.replaceAll('\$goal', goal);

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';
