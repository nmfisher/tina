import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import '../tui/input_status.dart';
import 'typesafe.dart';

/// The classifier transport is selected independently of the conversation model.
/// Credentials are read per request so changes in /settings take effect live.
PluginDescriptor configuredGitInputPlugin(
  Map<String, String> env,
) => PluginDescriptor(
  id: 'tina.git-input',
  requires: {spendLedgerServiceKey},
  factory: FnPluginFactory((context) {
    final ledger = context.require(spendLedgerServiceKey);
    final plugin = GitInput((input, cancellation) async {
      final service = createConfiguredTypeSafeService(env: env);
      if (service == null) return null;
      try {
        return await classifyGitInput(
          source: InputTextSource(input.id, input.originalText, input.history),
          service: MeteredJudgmentService(
            inner: service,
            ledger: ledger,
            budget: service.config.requestBudget,
            outputTokenAllowance: 1024,
          ),
          budget: service.config.requestBudget,
          cancellation: cancellation,
        );
      } finally {
        service.close();
      }
    });
    context.register(
      plugin,
      id: 'tina.git-input.status',
      dispose: plugin.dispose,
    );
    context.register(const GitStatusRenderer(), id: 'tina.git-input.renderer');
    return plugin;
  }),
);
