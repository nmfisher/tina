import 'dart:async';

import 'package:tina/config.dart';
import 'package:tina/platform/environment.dart';
import 'package:tina_engine/tina_engine.dart';

import 'environment_record.dart';
import 'environment_runner.dart';
import 'environment_store.dart';

/// The in-app seam for the environment feature (docs/proposals/
/// environment_agent.md): a pure-read [status] (no LLM — the record's presence
/// plus the tracking entry's stale verdict) and [refresh], which runs the
/// environment agent on the ephemeral composition and so requires a live
/// [config] + [registry].
///
/// Mirrors [SummaryIndex]: [status] needs nothing but the project root;
/// [refresh] asserts the composition parts.
class EnvironmentIndex {
  EnvironmentIndex({
    required this.projectRoot,
    this.config,
    this.registry,
    this.environment,
    this.spendLedger,
  });

  /// The repo root. The record lives at `$projectRoot/ENVIRONMENT.md`; the
  /// machine-owned tracking entry at `$projectRoot/.tina/environment/`.
  final String projectRoot;

  /// Live-session composition parts; only required for [refresh]. Nullable so
  /// [status] can run without a composition (startup, tests, the dance probe).
  final Config? config;
  final ProviderRegistry? registry;
  final Environment? environment;

  /// The LIVE session's ledger: the agent run's usage merges into it after an
  /// in-process refresh. Null headless (throwaway ledger).
  final SpendLedger? spendLedger;

  /// The pure-read probe. No LLM, no side effects — the answer to "does a
  /// record exist, and is it current?".
  EnvironmentStatus status() => EnvironmentStatus(
        recordPresent: EnvironmentRecord.exists(projectRoot),
        staleReason: store.staleReason(),
      );

  /// The machine-owned tracking store (Dart-only writer).
  EnvironmentTrackingStore get store =>
      EnvironmentTrackingStore(projectRoot: projectRoot);

  /// Run the environment agent (first-load population or a stale re-verify).
  /// [host] routes the agent's output (defaults to a HeadlessHost — pass the
  /// conversation host in-session); [cancelSignal] cancels mid-run. Returns
  /// true when the run completed and the tracking entry was recorded.
  Future<bool> refresh({
    HostInterface? host,
    Future<void>? cancelSignal,
  }) async {
    final cfg = config;
    final reg = registry;
    if (cfg == null || reg == null) {
      throw StateError(
        'EnvironmentIndex.refresh requires a Config + ProviderRegistry; '
        'the caller must wire them (status() does not).',
      );
    }
    return EnvironmentRunner(
      config: cfg,
      registry: reg,
      environment: environment,
      projectRoot: projectRoot,
      host: host,
      cancelSignal: cancelSignal,
      spendLedger: spendLedger,
    ).run();
  }
}

/// The pure-read staleness answer for the environment region.
class EnvironmentStatus {
  /// Whether `ENVIRONMENT.md` exists — false means first load: the environment
  /// agent should populate it from measurements.
  final bool recordPresent;

  /// Why the region is stale, or null when current. From the machine-owned
  /// tracking entry, never from the record's prose.
  final String? staleReason;

  const EnvironmentStatus({required this.recordPresent, this.staleReason});

  bool get stale => staleReason != null;
}

/// The warm-load block for the system prompt's `<environment>` funnel: the
/// record's claims as compact lines plus the machine-rendered `status:`
/// verdict. Null when there is no record (nothing to load), when it is
/// unreadable, or on any read failure — a bad record must never break prompt
/// assembly.
String? projectEnvironmentBlock(String projectRoot) {
  final record = EnvironmentRecord.load(projectRoot);
  if (record == null) return null;
  final reason =
      EnvironmentTrackingStore(projectRoot: projectRoot).staleReason();
  final block =
      record.promptBlock(stale: reason != null, staleReason: reason);
  return block.isEmpty ? null : block;
}
