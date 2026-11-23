import 'package:tina_settings/tina_settings.dart';

/// The override for the automatic compaction trigger, in absolute
/// estimated input tokens.
///
/// Value semantics (read together with the setting's SOURCE):
/// - no override written (source == null): window-derived — 80% of the
///   active model's context window, resolved live each turn, with the
///   safe 100000 fallback when the window is unknown;
/// - a written positive value: the absolute trigger;
/// - a written 0: automatic compaction disabled — the same `<= 0` rule
///   the explicit [CompactionConfig.thresholdTokens] has always used.
///   `/compact` still works.
final compactionThresholdSetting = SettingDefinition<int>(
    id: 'tina/auto-compact/threshold_tokens',
    label: 'Auto-compaction threshold',
    description:
        'Estimated input tokens that trigger automatic compaction. '
        'Default: 80% of the active model\'s context window, read live '
        'each turn (100000 when the window is unknown). Set an absolute '
        'token count to override; 0 disables automatic compaction. '
        '/compact still works when disabled.',
    defaultValue: 0,
    kind: SettingKind.integer,
    minimum: 0,
    applyAt: ApplyAt.nextRequest);
