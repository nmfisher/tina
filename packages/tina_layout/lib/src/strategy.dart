/// Runtime-swappable layout strategies — one dispatcher, two sources.
///
/// Sources that feed the same [LayoutStrategies] machinery:
///
/// * **Native strategies are TRUSTED CODE, compiled in.** They are
///   classes in the application's Dart (the shipped presets, or a
///   workspace strategy registered via the app's
///   `registerLayoutStrategy`), with no runtime code loading: an AOT
///   binary cannot load Dart at runtime, and trusted code has no
///   isolation boundary to enforce anyway. Because they are trusted,
///   native strategies may also reshape the chat screen's template
///   through `ScreenPolicy` (see tina_console's
///   `ScreenLayoutStrategy`) — an extension the wasm contract
///   deliberately does not have. See `docs/native-layout-strategies.md`.
///
/// * **Wasm bridge strategies are CAPABILITY-FREE but ISOLATED.** The
///   host mounts a `tina:layout@1.0.0` strategy component (zero
///   capabilities; the host refuses any component importing beyond WASI
///   and the contract's own types), and the TUI's bridge adapter
///   forwards solves to it across the Store boundary under an epoch
///   deadline. A wedged or garbage plugin falls back to the built-in
///   solver here, never a wedged screen. See `docs/layout-plugin.md`.
///
/// Both implement this same [LayoutStrategy] shape — the Dart form of
/// `tina:layout/strategy@1.0.0` — so a strategy moves between the two
/// runtimes unchanged in spirit: a native strategy ports to the plugin
/// form by wrapping its solve in a guest, and the bridge adapter is
/// itself just another strategy installed from the host side.
///
/// Dispatch rule: with nothing installed the dispatcher IS the built-in
/// [GridSolver]. With a strategy installed, [solve] tries it and falls
/// back to the built-in on ANY failure — exception, malformed solution
/// — firing a once-per-install notice through [onFallbackNotice].
/// Swaps notify [addListener] listeners so live screens re-layout.
library;

import 'geometry.dart';
import 'solver.dart' show GridSolution, GridSolver;
import 'spec.dart';

/// Identity card of a layout strategy.
final class StrategyDescriptor {
  final String id;

  /// The contract version the strategy speaks (`1.0.0`).
  final String version;

  final String description;

  const StrategyDescriptor({
    required this.id,
    required this.version,
    required this.description,
  });

  @override
  String toString() => 'StrategyDescriptor($id $version)';
}

/// A layout strategy: a pure, synchronous function from
/// (spec, terminal size, metrics) to a [GridSolution].
///
/// Implementations must be side-effect free and fast enough for a
/// resize burst; the dispatcher treats any exception — including a
/// malformed solution record — as a fallback trigger, never as a
/// screen-fatal error. [id] is the cheap display name (config keys,
/// `/layout`, the status strip); [describe] is the full descriptor the
/// wasm contract exchange carries.
abstract interface class LayoutStrategy {
  /// Display/selection name: `default`, `focus`, `two-column`, a
  /// workspace-registered name, or a plugin id like
  /// `tina/layout-solver`.
  String get id;

  /// The full descriptor (contract version, description).
  StrategyDescriptor describe();

  GridSolution solveSpec(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard});
}

/// The built-in solver as a strategy: the default, the fallback, and
/// the reference implementation for differential goldens.
///
/// Extensible on purpose: a native strategy can solve like the built-in
/// and override only template-level policy (tina_console's
/// `ScreenLayoutStrategy.policyFor`).
class BuiltinLayoutStrategy implements LayoutStrategy {
  const BuiltinLayoutStrategy();

  @override
  String get id => 'default';

  @override
  StrategyDescriptor describe() => const StrategyDescriptor(
        id: 'tina/layout-builtin',
        version: '1.0.0',
        description: 'The compiled-in tina_layout grid solver '
            '(largest-remainder weighted tracks, hard minimums, '
            'priority overflow drops).',
      );

  @override
  GridSolution solveSpec(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    return GridSolver.solve(spec,
        columns: columns, rows: rows, metrics: metrics);
  }
}

/// The `focus` preset: weighted tracks share the available space
/// EQUALLY (the chat/info split goes 65/35 -> 50/50 wherever the app
/// allows a split). The same semantics as the wasm round's
/// `tina/layout-focus` plugin, as trusted native code.
///
/// Minimums and maximums are respected — equal sharing reweights, it
/// never overrides the spec's hard floors.
class FocusLayoutStrategy implements LayoutStrategy {
  const FocusLayoutStrategy();

  @override
  String get id => 'focus';

  @override
  StrategyDescriptor describe() => const StrategyDescriptor(
        id: 'focus',
        version: '1.0.0',
        description: 'Equal shares: weighted tracks split the space '
            'equally (the native form of tina/layout-focus).',
      );

  @override
  GridSolution solveSpec(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    GridTrack equal(GridTrack track) => switch (track.kind) {
          TrackKind.weighted => GridTrack.weighted(1,
              minUnits: track.minUnits, maxUnits: track.maxUnits),
          _ => track,
        };
    return GridSolver.solve(
        GridSpec(
            columns: [for (final t in spec.columns) equal(t)],
            rows: [for (final t in spec.rows) equal(t)],
            items: spec.items),
        columns: columns,
        rows: rows,
        metrics: metrics);
  }
}

/// The process-wide strategy dispatcher: what [GridSolver] callers
/// route through so an installed strategy — native preset,
/// workspace-registered class, or the wasm bridge plugin — replaces
/// the solve at runtime.
///
/// One active strategy at a time by design: the last deliberate choice
/// (config boot selection, `/layout`, or the host's bridge probe) owns
/// the screen, and every solve falls back to the built-in on failure.
final class LayoutStrategies {
  LayoutStrategies._();

  static LayoutStrategy? _installed;
  static bool _noticed = false;
  static final _listeners = <void Function()>{};

  /// Set by the host application to surface fallback notices once per
  /// install. Never throws past a notice callback.
  static void Function(String message)? onFallbackNotice;

  /// The installed strategy, or `null` when the built-in solver is live.
  static LayoutStrategy? get installed => _installed;

  /// The strategy a solve routes through right now.
  static LayoutStrategy get active =>
      _installed ?? const BuiltinLayoutStrategy();

  /// True when a non-built-in strategy is installed.
  static bool get hasCustom => _installed != null;

  /// Install [strategy]; takes effect on the next [solve]. Resets the
  /// fallback-notice latch and notifies [addListener] listeners.
  static void install(LayoutStrategy strategy) {
    _installed = strategy;
    _noticed = false;
    _notify();
  }

  /// Remove the installed strategy; the next [solve] uses the built-in
  /// solver again. Idempotent.
  static void uninstall() {
    if (_installed == null) return;
    _installed = null;
    _noticed = false;
    _notify();
  }

  /// Listen for strategy changes (install/uninstall). The TUIs use
  /// this to re-layout the live screen for `/layout` and bridge mounts.
  static void addListener(void Function() listener) =>
      _listeners.add(listener);

  static void removeListener(void Function() listener) =>
      _listeners.remove(listener);

  static void _notify() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  /// Solve through the installed strategy with hard fallback to the
  /// built-in solver.
  static GridSolution solve(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    final strategy = _installed;
    if (strategy == null) {
      return GridSolver.solve(spec,
          columns: columns, rows: rows, metrics: metrics);
    }
    try {
      return strategy.solveSpec(spec,
          columns: columns, rows: rows, metrics: metrics);
    } catch (error) {
      _notice('layout strategy ${_describeSafe(strategy)} failed '
          '($error); using the built-in solver');
      return GridSolver.solve(spec,
          columns: columns, rows: rows, metrics: metrics);
    }
  }

  static String _describeSafe(LayoutStrategy strategy) {
    try {
      return strategy.describe().id;
    } catch (_) {
      return '<describe failed>';
    }
  }

  static void _notice(String message) {
    if (_noticed) return;
    _noticed = true;
    final callback = onFallbackNotice;
    if (callback == null) return;
    try {
      callback(message);
    } catch (_) {}
  }
}
