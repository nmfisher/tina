import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import '../tui/intent_status.dart';
import 'typesafe.dart';

/// The classifier transport is selected independently of the conversation model.
/// Credentials are read per request so changes in /settings take effect live.
///
/// PT0 self-gating: [interactive] carries the launcher's interactivity decision
/// (a plain parameter, per the proposal — not an env flag), and a headless
/// launch contributes nothing. The descriptor is still mounted, so consumers
/// that inspect the plugin list see it; the factory's `Object()` result binds
/// no services and registers no contributions.
PluginDescriptor configuredIntentInputPlugin(
  Map<String, String> env, {
  bool interactive = true,
}) => PluginDescriptor(
  id: 'tina.intent-input',
  requires: {spendLedgerServiceKey},
  factory: FnPluginFactory((context) {
    if (!interactive) return Object();
    final ledger = context.require(spendLedgerServiceKey);
    final plugin = IntentInput((input, cancellation) async {
      final service = createConfiguredTypeSafeService(env: env);
      if (service == null) return null;
      try {
        return await classifyIntent(
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
      id: 'tina.intent-input.status',
      dispose: plugin.dispose,
    );
    context.register(
      const IntentStatusRenderer(),
      id: 'tina.intent-input.renderer',
    );
    return plugin;
  }),
);
