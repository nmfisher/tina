import 'package:tina_app/src/composition/agent_composition.dart';
import 'package:tina_app/src/composition/runtime_resources.dart';
import 'package:tina_app/src/config/runtime_config.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_app/src/execution/project_execution.dart';
import 'package:tina_app/src/summaries/summary_index.dart';
import 'package:tina_app/src/summaries/summary_repository.dart';

/// Executes an already-planned fleet. Owns the execution scope and provider;
/// borrows interaction hosts and the factory's project tool scope.
class SummaryRunner implements SummaryFleet {
  final RuntimeConfig config;
  final ProjectExecutionFactory executionFactory;
  SummaryRunner({required this.config, required this.executionFactory});
  @override
  Future<SpendLedger> run(SummaryPlan plan, RunInteraction interaction) async {
    final app = await executionFactory();
    final resources = RuntimeResources()..own(app.dispose);
    return resources.run(() async {
      final host = interaction.host ?? HeadlessHost();
      if (interaction.host == null) resources.own(host.dispose);
      // The fleet's own provider, built on demand from this ephemeral
      // composition and closed with it below — no other path shares it.
      final provider = app.buildStartupProvider();
      resources.own(provider.close);
      resources.own(app.scheduler.dispose);
      // The top agent is the orchestrator with a summarization identity: it has
      // only `delegate` + channels (no file tools, structurally — see
      // buildAgent's withSubAgents path), which is exactly the shape we want.
      final agent = buildAgent(
        pipeline: app.pipeline,
        scheduler: app.scheduler,
        conversationId: 'summary',
        provider: provider,
        host: host,
        policy: app.policy,
        config: config,
        withSubAgents: true,
        system: _orchestratorPrompt(plan.work.toRegenerate),
      );

      final history = <Message>[];
      await agent.run(
        history: history,
        userInput: _userPrompt(plan.work.toRegenerate),
        cancelSignal: interaction.cancelSignal,
      );

      // Finish owned work before recording results or merging usage.
      await resources.dispose();

      return app.spendLedger;
    });
  }

  String _userPrompt(List<String> staleDirs) {
    if (staleDirs.isEmpty) {
      return 'No directories are stale. Nothing to summarize.';
    }
    final lines = StringBuffer()
      ..writeln(
        'Regenerate per-directory summaries for the following stale '
        'directories. For each, delegate a sub-agent with the task "read '
        '<dir> and write its summary with write_summary". Batch at most 8 '
        'per `delegate` call.\n',
      );
    for (final dir in staleDirs) {
      lines.writeln('- $dir');
    }
    return lines.toString();
  }

  String _orchestratorPrompt(List<String> staleDirs) => '''
You are the summarization orchestrator for a code repository. Your sole job is to fan out sub-agents — one per stale directory — so each reads its directory and writes a prose summary into the sidecar store.

For each directory listed in the user message, delegate a sub-agent with the task: "Read <dir> and write a markdown summary of it by calling write_summary("<dir>", <content>). Do not include a tracking header — write_summary stamps it." The sub-agents run read-only (they get read, search, grep, glob, and write_summary). Batch at most 8 delegations per `delegate` call (the tool caps it); if there are more, make multiple calls. Do not summarize directories yourself — always delegate. Do not write plans or run review loops; this is a pure fan-out.

When every directory has been delegated, stop. Your final answer is a one-line confirmation of how many directories you summarized.''';
}
