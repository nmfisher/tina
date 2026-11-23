/// The window-derived compaction policy: how the active model's context
/// window sets the automatic trigger and the kept-recent tail. Named
/// fractions, never magic numbers in the flow.
///
/// The plugin itself stays window-agnostic — it takes closures, so this
/// arithmetic is testable without a provider and the composition root
/// (the catalog) owns the live model lookup.
library;

import 'dart:math' as math;

/// The safe fixed trigger when the active model's window is unknown or
/// unresolvable — the historical default. Compaction stays ENABLED at
/// this level; an unknown window never silently disables it.
const int compactionFallbackThresholdTokens = 100000;

/// The kept-recent floor: even a tiny window keeps at least this many
/// estimated transcript tokens verbatim (the historical default).
const int compactionMinKeptRecentTokens = 15000;

/// The automatic trigger sits at this fraction of the context window,
/// leaving headroom for the response and the estimator's error.
const double compactionWindowTriggerFraction = 0.80;

/// The kept-recent tail scales to this fraction of the window, floored
/// at [compactionMinKeptRecentTokens], so a large window keeps a
/// meaningful recent tail instead of a fixed sliver.
const double compactionWindowKeepRecentFraction = 0.10;

/// The automatic trigger for a known window, in estimated input tokens.
int windowCompactionThreshold(int contextWindow) =>
    (contextWindow * compactionWindowTriggerFraction).round();

/// The kept-recent budget for a known window, in estimated transcript
/// tokens.
int windowKeptRecentTokens(int contextWindow) => math.max(
    compactionMinKeptRecentTokens,
    (contextWindow * compactionWindowKeepRecentFraction).round());

/// The trigger the automatic check uses this turn:
/// - a positive [overrideTokens] is an absolute threshold (the setting);
/// - otherwise a positive [contextWindow] derives the trigger from the
///   window;
/// - otherwise (window unknown/unresolvable) the safe fixed default.
///
/// 0 means disabled — the caller applies the same `<= 0` rule the
/// explicit config has always used. Negative values are not produced
/// by the setting (minimum 0) or by descriptors; treat them as unset.
int effectiveCompactionThreshold({
  required int? contextWindow,
  int? overrideTokens,
}) {
  if (overrideTokens != null) return overrideTokens;
  final window = contextWindow;
  if (window == null || window <= 0) {
    return compactionFallbackThresholdTokens;
  }
  return windowCompactionThreshold(window);
}

/// The kept-recent budget the split uses this turn: scaled to the
/// window when one is known, the historical floor otherwise.
int effectiveKeptRecentTokens({required int? contextWindow}) {
  final window = contextWindow;
  if (window == null || window <= 0) return compactionMinKeptRecentTokens;
  return windowKeptRecentTokens(window);
}
