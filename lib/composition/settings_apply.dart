import 'package:tina/config/user_config.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import 'config_providers.dart';

/// What one `/settings` session changed in the running app, and the message
/// that says so. Built by [SettingsApplier.finish]; consumed by the
/// coordinator, which only picks the host style ([SettingsSaveReport.changed]
/// → success, else dim) — the wording lives here so it stays next to the
/// apply decisions it describes.
class SettingsSaveReport {
  /// Whether any subpanel wrote `~/.tina/config` (null written config = no
  /// slice changed on disk).
  final bool wroteConfig;

  /// Whether the live quota caps were pushed into the running runtime. False
  /// both when nothing was saved and when there is no live quota service this
  /// session (quota edits are restart-only then).
  final bool quotaAppliedLive;

  /// Whether a live quota service exists at all — decides the message's
  /// "quota applies now" vs "quota applies on the next launch" clause.
  final bool quotaLiveApplies;

  /// Config-smell diagnostics from the rate-limit apply (e.g. one provider
  /// setting both `min_request_interval_ms` and `requests_per_minute`).
  final List<String> warnings;

  const SettingsSaveReport({
    required this.wroteConfig,
    required this.quotaAppliedLive,
    required this.quotaLiveApplies,
    this.warnings = const [],
  });

  /// Whether the session did anything worth reporting as a save.
  bool get changed => wroteConfig || quotaAppliedLive;

  /// The host message for the session — byte-identical to the pre-refactor
  /// coordinator strings: a saved line naming what applies now vs on the next
  /// launch (warnings appended, one per line), or a dim "(settings
  /// unchanged)".
  String get message {
    if (!changed) return '(settings unchanged)\n';
    final warnText = warnings.isEmpty ? '' : '\n${warnings.join('\n')}';
    return 'Settings saved to ~/.tina/config — provider, model and rate-limit '
        'changes apply now; '
        '${quotaLiveApplies ? 'quota changes apply now; theme applies on the next launch' : 'quota and theme apply on the next launch'}'
        '$warnText.\n';
  }
}

/// Owns applying one `/settings` session to the running app: the live quota
/// seams the quota subpanel needs (seed the panel from the runtime's current
/// caps, push saved caps back) and the post-close apply (rate-limit knobs into
/// the live registry via [applyRateLimitConfig], then the report).
///
/// One instance per settings session — [onQuotaSaved] flips internal state
/// that [finish] reads. Construct it with `quotas: null` when the live quota
/// service is absent (then the quota seams are null too and the quota slice is
/// restart-only, matching the pre-refactor behavior).
class SettingsApplier {
  final ProviderRegistry registry;
  final LiveQuotas? quotas;
  bool _quotaSaved = false;

  SettingsApplier({required this.registry, this.quotas});

  /// Panel input seam (`currentQuota`): merge the runtime's live quota caps
  /// over the on-disk slice, keeping the disk's rate-limit knobs (they are not
  /// live state — the panel edits them from the config). Null when there is
  /// no live quota service: the panel then shows the on-disk values.
  ///
  /// Exposed as a getter so the panel's existing
  /// `LimitsConfig Function(LimitsConfig)?` parameter accepts it directly.
  LimitsConfig Function(LimitsConfig saved)? get seedQuota =>
      quotas == null ? null : (saved) => _seed(saved);

  LimitsConfig _seed(LimitsConfig saved) => LimitsConfig(
        maxTurnTokens: quotas!.maxTurnTokens,
        maxSessionTokens: quotas!.maxSessionTokens,
        maxRequestTokens: quotas!.maxRequestTokens,
        maxSubAgentTokens: quotas!.maxSubAgentTokens,
        maxGlobalTokens: quotas!.maxGlobalTokens,
        requestsPerMinute: quotas!.requestsPerMinute,
        minRequestIntervalMs: saved.minRequestIntervalMs,
        maxConcurrentRequests: saved.maxConcurrentRequests,
      );

  /// Panel output seam (`onQuotaSaved`): push the saved caps into the live
  /// runtime so they govern existing and newly created agents without a
  /// restart. Null when there is no live quota service (the panel then skips
  /// the callback entirely).
  void Function(LimitsConfig saved)? get onQuotaSaved =>
      quotas == null ? null : (saved) => _applyQuota(saved);

  void _applyQuota(LimitsConfig saved) {
    quotas!.update(
      maxTurnTokens: saved.maxTurnTokens!,
      maxSessionTokens: saved.maxSessionTokens!,
      maxRequestTokens: saved.maxRequestTokens!,
      maxSubAgentTokens: saved.maxSubAgentTokens!,
      maxGlobalTokens: saved.maxGlobalTokens!,
      requestsPerMinute: saved.requestsPerMinute!,
    );
    _quotaSaved = true;
  }

  /// After the panel closes: apply the saved config's rate-limit knobs to the
  /// live registry (idempotent — the same values the startup path installs,
  /// so startup and saves converge) and report what changed. Rate-limit
  /// changes apply now because the limiter reads spacing at acquire time and
  /// the global knobs are plain fields; theme and system-prompt overrides
  /// still wait for the next launch (the report's message says which is
  /// which).
  SettingsSaveReport finish(UserConfig? written) {
    final warnings =
        written == null ? const <String>[] : applyRateLimitConfig(registry, written);
    return SettingsSaveReport(
      wroteConfig: written != null,
      quotaAppliedLive: _quotaSaved,
      quotaLiveApplies: quotas != null,
      warnings: warnings,
    );
  }
}
