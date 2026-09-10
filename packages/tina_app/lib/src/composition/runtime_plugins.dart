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

/// Built-in plugin that provides the conversation-owned [LlmProviderFactory]
/// under [providerFactoryServiceKey]. Every provider built from it is wrapped
/// in a [MeteringProvider] — spend metering plus the shared [PauseGate] — so
/// even `provider.send` calls that bypass the per-agent token budget are
/// counted. Requires the ledger, which is what guarantees the ordering: the
/// ledger exists before any provider can be built.
PluginDescriptor providerFactoryPlugin(
  RuntimeConfig config,
  ProviderRegistry registry,
  PauseGate pauseGate,
) => PluginDescriptor(
  id: 'tina.app.provider-factory',
  requires: {spendLedgerServiceKey},
  provides: [providerFactoryServiceKey],
  factory: FnPluginFactory((context) {
    final ledger = context.require(spendLedgerServiceKey);
    final factory = RuntimeProviderFactory(
      registry,
      decorator: (inner) => MeteringProvider(inner, ledger, pauseGate),
    );
    // The factory owns the closed flag only — closing it tears down provider
    // acquisition. Registered once here, so scope dispose closes it exactly
    // once and `dispose()` stays idempotent.
    context.own(factory.close);
    return factory;
  }),
);
