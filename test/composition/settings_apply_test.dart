// Tests for the /settings apply seam (lib/composition/settings_apply.dart):
// the live-quota panel seams and the post-close apply + report. The
// coordinator handler that consumes these is wired in tui_coordinator.dart;
// these tests pin the semantics it inherits (the wording contract, the
// restart-only vs apply-now split, and the rate-limit apply) without needing
// a TUI.
import 'package:tina/composition/settings_apply.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('SettingsApplier quota seams', () {
    LiveQuotas quotas() => LiveQuotas(
      RuntimeConfig(
        maxTurnTokens: 1000,
        maxSessionTokens: 2000,
        maxRequestTokens: 3000,
        maxSubAgentTokens: 4000,
      ),
      SpendLedger(maxGlobalTokens: 5000, requestsPerMinute: 6),
    );

    test('seedQuota merges live caps over the disk slice, keeping disk '
        'rate-limit knobs', () {
      final applier = SettingsApplier(
        registry: ProviderRegistry(),
        quotas: quotas(),
      );
      final seeded = applier.seedQuota!(
        const LimitsConfig(minRequestIntervalMs: 750, maxConcurrentRequests: 2),
      );
      expect(seeded.maxTurnTokens, 1000);
      expect(seeded.maxSessionTokens, 2000);
      expect(seeded.maxRequestTokens, 3000);
      expect(seeded.maxSubAgentTokens, 4000);
      expect(seeded.maxGlobalTokens, 5000);
      expect(seeded.requestsPerMinute, 6);
      // Rate-limit knobs are not live state — the panel edits the disk values.
      expect(seeded.minRequestIntervalMs, 750);
      expect(seeded.maxConcurrentRequests, 2);
    });

    test('onQuotaSaved pushes saved caps into the live runtime', () {
      final q = quotas();
      final applier = SettingsApplier(registry: ProviderRegistry(), quotas: q);
      applier.onQuotaSaved!(
        const LimitsConfig(
          maxTurnTokens: 222,
          maxSessionTokens: 333,
          maxRequestTokens: 444,
          maxSubAgentTokens: 555,
          maxGlobalTokens: 666,
          requestsPerMinute: 7,
        ),
      );
      expect(q.maxTurnTokens, 222);
      expect(q.maxSessionTokens, 333);
      expect(q.maxRequestTokens, 444);
      expect(q.maxSubAgentTokens, 555);
      expect(q.maxGlobalTokens, 666);
      expect(q.requestsPerMinute, 7);
    });

    test('absent live quota service → null seams (quota slice is '
        'restart-only)', () {
      final applier = SettingsApplier(registry: ProviderRegistry());
      expect(applier.seedQuota, isNull);
      expect(applier.onQuotaSaved, isNull);
    });
  });

  group('SettingsApplier.finish', () {
    test('saved quota → applies-live report even with no config write', () {
      final q = LiveQuotas(
        RuntimeConfig(maxTurnTokens: 1),
        SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0),
      );
      final applier = SettingsApplier(registry: ProviderRegistry(), quotas: q);
      // The panel round-trips the seeded config, so a real save always
      // carries all six caps (0 = unlimited) — matching the coordinator's
      // pre-refactor `!` assumptions.
      applier.onQuotaSaved!(
        const LimitsConfig(
          maxTurnTokens: 9,
          maxSessionTokens: 0,
          maxRequestTokens: 0,
          maxSubAgentTokens: 0,
          maxGlobalTokens: 0,
          requestsPerMinute: 0,
        ),
      );
      expect(q.maxTurnTokens, 9);
      final report = applier.finish(null);
      expect(report.wroteConfig, isFalse);
      expect(report.quotaAppliedLive, isTrue);
      expect(report.quotaLiveApplies, isTrue);
      expect(report.changed, isTrue);
    });

    test('no save at all → unchanged report and dim message', () {
      final applier = SettingsApplier(
        registry: ProviderRegistry(),
        quotas: LiveQuotas(
          RuntimeConfig(),
          SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0),
        ),
      );
      final report = applier.finish(null);
      expect(report.changed, isFalse);
      expect(report.message, '(settings unchanged)\n');
    });

    test('config write without a live quota service → rate-limit apply now, '
        'next-launch wording for quota', () {
      final registry = ProviderRegistry()
        ..rateLimiter.minInterval = const Duration(milliseconds: 1000);
      final applier = SettingsApplier(registry: registry);
      final report = applier.finish(
        const UserConfig(limits: LimitsConfig(minRequestIntervalMs: 750)),
      );
      expect(report.wroteConfig, isTrue);
      expect(report.quotaAppliedLive, isFalse);
      expect(report.quotaLiveApplies, isFalse);
      // The rate-limit knob from the written config landed on the live
      // registry — the apply-now promise in the message is real.
      expect(
        registry.rateLimiter.minInterval,
        const Duration(milliseconds: 750),
      );
      expect(report.message, contains('rate-limit changes apply now'));
      expect(
        report.message,
        contains('quota and theme apply on the next launch'),
      );
    });

    test('live quotas present → quota-now wording', () {
      final applier = SettingsApplier(
        registry: ProviderRegistry(),
        quotas: LiveQuotas(
          RuntimeConfig(),
          SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0),
        ),
      );
      final report = applier.finish(const UserConfig());
      expect(report.quotaLiveApplies, isTrue);
      expect(report.message, contains('quota changes apply now'));
      expect(report.message, contains('theme applies on the next launch'));
    });

    test('rate-limit config warnings surface in the message', () {
      final applier = SettingsApplier(registry: ProviderRegistry());
      final report = applier.finish(
        const UserConfig(
          providers: {
            'glm': ProviderConfig(
              minRequestIntervalMs: 150,
              requestsPerMinute: 60,
            ),
          },
        ),
      );
      expect(report.warnings, hasLength(1));
      expect(report.message, contains(report.warnings.single));
    });
  });
}
