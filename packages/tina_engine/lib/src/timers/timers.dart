/// Timer system for the tina engine (task #33,
/// docs/proposals/timer_system.md).
///
/// Surfaces:
/// - `TimerService` — the runtime: fixed-grid schedule with busy-collapse,
///   runaway-guard suspension, export/restore snapshots (spec §4, §8).
/// - the interval parser (`parseInterval`, spec §5),
/// - the three thin tools (`set_timer`, `cancel_timer`, `list_timers`,
///   spec §6),
/// - the per-session sidecar store (spec §10).
library;

export 'interval_parser.dart';
export 'timer_service.dart';
export 'timer_tools.dart';
