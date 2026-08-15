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
    PipelineEventListener? onEvent,
  }) async {
    // 1. Resolve + expand the prompt (falls back to label).
    final rawPrompt = node.prompt.isNotEmpty ? node.prompt : node.label;
    final prompt = expandTemplate(rawPrompt, context);

    // 2. Assemble the node's declared context — its handoff contract: exactly
    //    the prior outputs it named in its `context` attribute, nothing more.
    final preamble = buildPreamble(context, keys: node.contextKeys);

    // 3. Write the prompt for the audit trail.
    // 4. Run the backend.
    final CodergenResult result;
    try {
      result = await backend.run(
        node: node,
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

    // A transient backend failure asks the engine to retry this node. There
    // is no output to record — returning early keeps the empty response from
    // being published under the node's id and `writes` keys (a shared plan
    // key must not be clobbered with ''). The engine's retry loop re-runs the
    // node; if retries exhaust, it converts this to a fail outcome itself.
    if (result.outcome?.status == StageStatus.retry) {
      final retry = result.outcome!;
      await runStore.writeNode(
          nodeId: node.id, outcome: retry, prompt: prompt, response: '');
      return retry;
    }

    // 5. Build the outcome. Always record this node's output under its id,
    //    plus the spec's last_stage/last_response bookkeeping, plus any
    //    `writes` keys (the shared-key pattern: a reviewer publishing the
    //    current plan under `plan`). Merge with any explicit outcome the
    //    backend returned (e.g. a verdict); its contextUpdates win on a clash.
    final base = result.outcome ??
        const Outcome.success();
    final updates = <String, String>{
      node.id: responseText,
      for (final w in {...node.writesKeys})
        if (w != node.id) w: responseText,
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

/// Render the run context as labeled sections of prior work, restricted to
/// the [keys] this node declared in its `context` attribute — the node's
/// handoff contract. Keys render in declared order; a declared key with no
/// value yet (e.g. a revision that hasn't happened) renders nothing. No keys
/// declared → no preamble: nothing accumulates by default.
String buildPreamble(Context context, {required List<String> keys}) {
  if (keys.isEmpty) return '';
  final buf = StringBuffer();
  for (final key in keys) {
    final value = context.getString(key);
    if (value.isEmpty) continue;
    buf.writeln('--- $key ---');
    buf.writeln(value);
    buf.writeln();
  }
  return buf.toString().trimRight();
}

/// Expand `$<key>` tokens in [template] against the run [context]. `$goal`
/// aliases the graph goal (`graph.goal`); any other context key (`$input`,
/// `$history`, node ids, ...) resolves from the context. Unknown or empty
/// tokens are left verbatim, so templates stay safe for prompt text that
/// legitimately contains `$`. A token ends at a non-identifier char — a
/// trailing period in prose (`...for: $input.`) is NOT part of the key, while
/// dotted identifiers (`$node.section`) are.
String expandTemplate(String template, Context context) {
  return template.replaceAllMapped(
    RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)'),
    (m) {
      final key = m.group(1)!;
      final value =
          key == 'goal' ? context.getString('graph.goal') : context.getString(key);
      return value.isEmpty ? m.group(0)! : value;
    },
  );
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';
