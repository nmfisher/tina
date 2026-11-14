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
/// This is the Dart form of the `tina:layout/strategy@1.0.0` plugin
/// contract (see `docs/layout-plugin.md`). Implementations must be
/// side-effect free and fast enough for a resize burst; the dispatcher
/// treats any exception — including a malformed solution record — as a
/// fallback trigger, never as a screen-fatal error.
abstract interface class LayoutStrategy {
  StrategyDescriptor describe();

  GridSolution solveSpec(GridSpec spec,
      {required int columns, required int rows,
      CellMetrics metrics = CellMetrics.standard});
}

/// The built-in solver as a strategy: the default, the fallback, and the
/// reference implementation for differential goldens.
final class BuiltinLayoutStrategy implements LayoutStrategy {
  const BuiltinLayoutStrategy();

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

/// The process-wide strategy dispatcher: what [GridSolver] callers route
/// through so an installed plugin replaces the strategy at runtime.
///
/// Dispatch rule: with nothing installed this is the built-in solver by
/// identity. With a strategy installed, [solve] tries it and falls back to
/// the built-in solver on ANY failure, firing a once-per-install notice
/// through [onFallbackNotice] (the TUI surfaces it in the notice strip).
/// A wedged or garbage layout strategy must never wedge the screen.
final class LayoutStrategies {
  LayoutStrategies._();

  static LayoutStrategy? _installed;
  static bool _noticed = false;

  /// Set by the host application to surface fallback notices once per
  /// install. Never throws past a notice callback.
  static void Function(String message)? onFallbackNotice;

  /// The installed strategy, or `null` when the built-in solver is live.
  static LayoutStrategy? get installed => _installed;

  /// The strategy a solve routes through right now.
  static LayoutStrategy get active => _installed ?? const BuiltinLayoutStrategy();

  /// Install [strategy]; takes effect on the next [solve]. Resets the
  /// fallback-notice latch.
  static void install(LayoutStrategy strategy) {
    _installed = strategy;
    _noticed = false;
  }

  /// Remove the installed strategy; the next [solve] uses the built-in
  /// solver again.
  static void uninstall() {
    _installed = null;
    _noticed = false;
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
