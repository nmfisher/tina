import 'package:tina_engine/tina_engine.dart';

import '../config/runtime_config.dart';

/// Runtime-owned quota policy shared by existing and newly created agents.
/// Budgets retain their own spend; only the cap source is shared.
class LiveQuotas {
  final SpendLedger ledger;
  TokenBudgetLimits _main;
  TokenBudgetLimits _delegated;

  LiveQuotas(RuntimeConfig config, this.ledger)
    : _main = TokenBudgetLimits(
        perTurn: _cap(config.maxTurnTokens),
        perSession: _cap(config.maxSessionTokens),
        perRequest: _cap(config.maxRequestTokens),
      ),
      _delegated = TokenBudgetLimits(
        perSession: _cap(config.maxSubAgentTokens),
      );

  static int? _cap(int value) => value == 0 ? null : value;

  int get maxTurnTokens => _main.perTurn ?? 0;
  int get maxSessionTokens => _main.perSession ?? 0;
  int get maxRequestTokens => _main.perRequest ?? 0;
  int get maxSubAgentTokens => _delegated.perSession ?? 0;
  int get maxGlobalTokens => ledger.maxGlobalTokens;
  int get requestsPerMinute => ledger.requestsPerMinute;

  // Keep accounting even while unlimited, so enabling a cap later does not
  // discard spend accumulated earlier in this runtime.
  TokenBudget mainBudget() => TokenBudget(limits: () => _main);
  TokenBudget delegatedBudget() => TokenBudget(limits: () => _delegated);

  void update({
    required int maxTurnTokens,
    required int maxSessionTokens,
    required int maxRequestTokens,
    required int maxSubAgentTokens,
    required int maxGlobalTokens,
    required int requestsPerMinute,
  }) {
    if ([
      maxTurnTokens,
      maxSessionTokens,
      maxRequestTokens,
      maxSubAgentTokens,
      maxGlobalTokens,
      requestsPerMinute,
    ].any((n) => n < 0)) {
      throw ArgumentError('Quota limits must be non-negative');
    }
    _main = TokenBudgetLimits(
      perTurn: _cap(maxTurnTokens),
      perSession: _cap(maxSessionTokens),
      perRequest: _cap(maxRequestTokens),
    );
    _delegated = TokenBudgetLimits(perSession: _cap(maxSubAgentTokens));
    ledger.updateLimits(
      maxGlobalTokens: maxGlobalTokens,
      requestsPerMinute: requestsPerMinute,
    );
  }
}

final liveQuotasServiceKey = ServiceKey<LiveQuotas>('tina.app.live-quotas');

PluginDescriptor liveQuotasPlugin(RuntimeConfig config) => PluginDescriptor(
  id: 'tina.app.live-quotas',
  requires: {spendLedgerServiceKey},
  provides: [liveQuotasServiceKey],
  factory: FnPluginFactory(
    (context) => LiveQuotas(config, context.require(spendLedgerServiceKey)),
  ),
);
