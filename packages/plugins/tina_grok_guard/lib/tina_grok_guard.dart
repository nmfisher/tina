import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_approvals/tina_approvals.dart';

PluginDefinition<C> grokGuardDefinition<C>() =>
    PluginDefinition.dependingOn<C, ApprovalRequester>('tina/grok-guard',
        dependency: approvalRequester,
        live: true,
        create: (_, approvals) => GrokGuardPlugin(approvals));

/// Policy only: the selected approval channel owns the question's UI.
final class GrokGuardPlugin extends AgentPlugin {
  GrokGuardPlugin(this.approvals);
  final ApprovalRequester approvals;
  static const question =
      'Your message contains grok, this is a no-no. Are you sure you want to proceed?';
  @override
  String get id => 'tina/grok-guard';

  @override
  Future<void> onInput(TurnContext context) async {
    if (!context.input.text.toLowerCase().contains('grok')) return;
    try {
      final decision = await approvals.request(
          operation: 'Send message?',
          target: 'user input',
          reason: question,
          kind: ApprovalKind.confirmation);
      if (decision != ApprovalDecision.allow)
        context.cancel('message declined');
    } catch (_) {
      context.cancel('message confirmation unavailable');
    }
  }
}
