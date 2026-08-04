import 'region.dart';

/// Turn-indicator hook (retired animation).
///
/// The info panel used to host two animations driven through the shared
/// [StatusRegion]: a "thinking" braille spinner while a turn was in flight,
/// and an idle beach scene at rest. Both have been retired — the info panel
/// is now a static reference surface (see [InfoPanel]), and this class is a
/// no-op.
///
/// It remains so the agent/session lifecycle — which is wired to start/stop a
/// spinner per turn ([Agent], [ProviderStreamConsumer], [SessionManager]) —
/// keeps compiling. Every method is a cheap no-op: nothing is drawn and no
/// timers are created.
class Spinner {
  /// Retained for API compatibility; the spinner no longer draws, so this has
  /// no observable effect.
  bool enabled;

  /// The region this spinner would draw into. Retained for [attachRegion].
  StatusRegion? region;

  /// Relative row within [region]. Retained for API compatibility.
  int rowOffset;

  Spinner({this.enabled = false, this.region, int? rowOffset})
      : rowOffset = rowOffset ?? _defaultRow(region);

  /// The default drawing row for a bounded indicator — the last row of the
  /// region. Kept because [ProgressCounter] still references it.
  static int _defaultRow(StatusRegion? r) {
    if (r == null) return 0;
    if (r.bounds.isEmpty) return 0;
    return r.bounds.height - 1;
  }

  /// No-op. The turn lifecycle calls this when a response starts.
  void start({String label = 'thinking'}) {}

  /// No-op. The turn lifecycle calls this when a response ends.
  void stop() {}

  /// No-op. Session setup calls this at launch/switch.
  void startIdle() {}

  /// No-op. Teardown calls this before leaving the alternate screen.
  void dispose() {}

  /// Rebind to [r] (or `null` to detach). No longer cancels timers or clears
  /// anything — there's nothing to cancel — just records the new region.
  void attachRegion(StatusRegion? r) {
    region = r;
    enabled = r != null;
    rowOffset = _defaultRow(r);
  }
}

/// Bounded progress indicator. Same StatusRegion contract the [Spinner] once
/// had: writes a label + count to one row. Not wired into the app, but kept
/// as a self-contained utility (and exercised by its tests).
class ProgressCounter {
  final bool enabled;
  final StatusRegion? region;
  final int rowOffset;

  bool _active = false;
  String _label = '';
  int? _total;

  ProgressCounter({
    this.enabled = true,
    this.region,
    int? rowOffset,
  }) : rowOffset = rowOffset ?? Spinner._defaultRow(region);

  void start(String label, {int? total}) {
    if (!enabled || _active || region == null) return;
    _label = label;
    _total = total;
    _active = true;
    _draw(0);
  }

  void tick(int current) {
    if (!_active) return;
    _draw(current);
  }

  void finish({String? message}) {
    if (!_active) return;
    _active = false;
    final r = region;
    if (r == null) return;
    if (message != null) {
      r.writeAt(rowOffset, r.screen.colorize(r.screen.theme.spinner.dim, message));
    } else {
      r.clearAt(rowOffset);
    }
  }

  void _draw(int current) {
    final r = region;
    if (r == null) return;
    final count = _total != null ? '$current/$_total' : '$current items';
    r.writeAt(
        rowOffset, r.screen.colorize(r.screen.theme.spinner.dim, '⠿ $_label $count'));
  }
}
