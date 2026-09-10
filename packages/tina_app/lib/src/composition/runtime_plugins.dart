import 'dart:io';

import 'package:tina_engine/tina_engine.dart';

import 'package:tina_app/src/config/runtime_config.dart';

/// Built-in plugin that provides the conversation-wide [SpendLedger] under
/// [spendLedgerServiceKey]. The ledger's constructor arguments mirror
/// `buildExecutionRuntime` exactly; it is the FIRST service the composition
/// creates, before anything that could build a provider, so the metering
/// decorator wraps every provider from the very first wire call.
PluginDescriptor spendLedgerPlugin(RuntimeConfig config) => PluginDescriptor(
  id: 'tina.app.spend-ledger',
  provides: [spendLedgerServiceKey],
  factory: FnPluginFactory((context) {
    final ledger = SpendLedger(
      maxGlobalTokens: config.maxGlobalTokens,
      requestsPerMinute: config.requestsPerMinute,
    );
    // #46 (c): make a degrading provider patch visible while it burns — the
    // ledger notices when retried (failed-attempt) spend crosses a tenth of
    // total spend and escalates by further tenths. stderr is the default sink
    // (visible headless and in nohup logs, same channel as the watchdog); a
    // TUI may replace it with a chat renderer.
    ledger.onRetriedSpendNotice = stderr.writeln;
    // The ledger owns no native state and holds no wire resources; nothing
    // to own in the scope, so no `context.own` here.
    return ledger;
  }),
);

/// Built-in plugin that registers each of [decorators] as a scope
/// CONTRIBUTION (ids `tina.decorator.<index>`, in list order) and provides the
/// [ProviderDecoratorStage] ordering marker under
/// [providerDecoratorStageServiceKey]. The marker carries no behavior — it
/// exists so [providerFactoryPlugin] can declare an order-only dependency on
/// this plugin: all decorator contributions are registered before the factory
/// builds the provider policy stack, in the same way the ledger's key forces
/// ledger-before-factory.
PluginDescriptor providerDecoratorsPlugin(
  List<ProviderDecorator> decorators,
) => PluginDescriptor(
  id: 'tina.app.provider-decorators',
  provides: [providerDecoratorStageServiceKey],
  factory: FnPluginFactory((context) {
    for (var i = 0; i < decorators.length; i++) {
      context.register(decorators[i], id: 'tina.decorator.$i');
    }
    return const ProviderDecoratorStage();
  }),
);

/// Built-in plugin that provides the conversation-owned [LlmProviderFactory]
/// under [providerFactoryServiceKey]. Every provider built from it is wrapped
/// in a [MeteringProvider] — spend metering plus the shared [PauseGate] — so
/// even `provider.send` calls that bypass the per-agent token budget are
/// counted. Requires the ledger, which is what guarantees the ordering: the
/// ledger exists before any provider can be built.
///
/// Decorators: the factory's decorator stack wraps the scope's
/// [ProviderDecorator] contributions AROUND the always-present metering
/// layer, first declared outermost. The stage dependency is an ORDER-ONLY
/// edge — nothing is read through the key — same trick as the phase guard
/// requiring the policy guard's key. It is gated behind
/// [orderOnDecoratorStage]: the full execution composition
/// ([buildExecutionRuntime]) mounts [providerDecoratorsPlugin] and turns the
/// edge on, making the engine pin the decorators plugin ahead of this one so
/// every contribution is registered before the stack is built; runtimes that
/// hand-assemble ledger + factory without a decorator provider — the
/// pre-plugin shape, which the stage key cannot resolve — keep activating
/// unchanged, and with no contributions the stack is metering only, exactly
/// the default.
PluginDescriptor providerFactoryPlugin(
  RuntimeConfig config,
  ProviderRegistry registry,
  PauseGate pauseGate, {
  bool orderOnDecoratorStage = false,
}) => PluginDescriptor(
  id: 'tina.app.provider-factory',
  requires: {
    spendLedgerServiceKey,
    if (orderOnDecoratorStage) providerDecoratorStageServiceKey,
  },
  provides: [providerFactoryServiceKey],
  factory: FnPluginFactory((context) {
    final ledger = context.require(spendLedgerServiceKey);
    // Metering is the innermost layer and is always present; the scope's
    // decorator contributions wrap AROUND it, first declared outermost
    // (hence the reversed iteration).
    LlmProvider decorate(LlmProvider inner) {
      var p = MeteringProvider(inner, ledger, pauseGate) as LlmProvider;
      for (final d in providerDecoratorsFromScope(context.scope).reversed) {
        p = d(p);
      }
      return p;
    }
    final factory = RuntimeProviderFactory(registry, decorator: decorate);
    // The factory owns the closed flag only — closing it tears down provider
    // acquisition. Registered once here, so scope dispose closes it exactly
    // once and `dispose()` stays idempotent.
    context.own(factory.close);
    return factory;
  }),
);
