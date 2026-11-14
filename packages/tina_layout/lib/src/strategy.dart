/// Runtime-swappable layout strategies.
///
/// A [LayoutStrategy] turns a [GridSpec] plus a terminal size into a
/// [GridSolution] — the same contract the wasm plugin round
/// (`docs/layout-plugin.md`) defines as `tina:layout@1.0.0`, in pure
/// Dart: `solve(spec, columns, rows)` where the wasm form adds cell
/// metrics for non-square terminals. A strategy written against this
/// interface ports to the wasm plugin form by wrapping the same solve
/// in a `tina:layout/strategy` guest.
///
/// The compiled-in [BuiltinLayoutStrategy] (the [GridSolver]) is always
/// the fallback: [LayoutStrategies.solve] catches every strategy
/// failure, solves with the built-in and reports once per install.
///
/// Native strategies are TRUSTED code compiled into the binary — unlike
/// wasm registry plugins there is no isolation, no capability
/// admission and no consent flow here. See
/// `docs/native-layout-strategies.md`.
library;

import 'geometry.dart';
import 'solver.dart';
import 'spec.dart';

/// Solves a [GridSpec] for a terminal of [columns] x [rows] cells.
///
/// Implementations must be pure and synchronous: no I/O, no clocks, no
/// terminal access. Throwing is allowed — the dispatcher falls back to
/// the built-in solver (the wasm form returns `err(string)` instead;
/// the semantics are identical).
abstract interface class LayoutStrategy {
  /// Stable identifier shown by `/layout` and written to config:
  /// `default`, `focus`, `two-column`, or a `publisher/name`-style id
  /// for workspace-declared strategies.
  String get id;

  /// Strategy version, for the descriptor line in reports.
  String get version;

  /// Solve [spec] for a [columns] x [rows] terminal.
  GridSolution solve(GridSpec spec, {required int columns, required int rows});
}

/// The compiled-in [GridSolver] — the default and the fallback.
///
/// Extensible on purpose: a custom strategy can solve like the built-in
/// and override only template-level policy (tina_console's
/// ScreenLayoutStrategy.policyFor).
class BuiltinLayoutStrategy implements LayoutStrategy {
  const BuiltinLayoutStrategy();

  @override
  String get id => 'default';

  @override
  String get version => '1.0.0';

  @override
  GridSolution solve(GridSpec spec, {required int columns, required int rows}) =>
      GridSolver.solve(spec, columns: columns, rows: rows);
}

/// The `focus` preset: weighted tracks share the available space
/// EQUALLY (the chat/info split goes 65/35 -> 50/50 wherever the app
/// allows a split). Ported from the wasm round's `tina/layout-focus`.
///
/// Minimums and maximums are respected — equal sharing reweights, it
/// never overrides the spec's hard floors.
final class FocusLayoutStrategy implements LayoutStrategy {
  const FocusLayoutStrategy();

  @override
  String get id => 'focus';

  @override
  String get version => '1.0.0';

  @override
  GridSolution solve(GridSpec spec, {required int columns, required int rows}) {
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
        rows: rows);
  }
}

/// The strategy dispatcher: one active strategy, the built-in always in
/// reserve. [ScreenLayout] and every other grid consumer solve through
/// [LayoutStrategies.instance]; with nothing installed the dispatcher
/// IS the built-in solver, so a no-strategy binary behaves identically
/// to before.
final class LayoutStrategies {
  LayoutStrategies._();

  /// The process-wide dispatcher. Native tina is one process, one
  /// screen arrangement at a time; the TUI re-layouts on [addListener]
  /// when this changes.
  static final LayoutStrategies instance = LayoutStrategies._();

  static const BuiltinLayoutStrategy builtin = BuiltinLayoutStrategy();

  LayoutStrategy _active = builtin;
  bool _fallbackNoticed = false;
  final _listeners = <void Function()>{};

  /// One fallback notice per install, delivered here. The application
  /// wires this to its output; without a sink notices are dropped
  /// (tests assert through it).
  void Function(String notice)? onFallbackNotice;

  /// The active strategy. Never null; the built-in when nothing is
  /// installed.
  LayoutStrategy get active => _active;

  /// Install [strategy] as the active strategy. Installing resets the
  /// one-notice fallback latch and notifies [addListener] listeners.
  void install(LayoutStrategy strategy) {
    _active = strategy;
    _fallbackNoticed = false;
    _notify();
  }

  /// Uninstall the active strategy: the built-in returns. Idempotent.
  void uninstall() {
    if (identical(_active, builtin)) return;
    _active = builtin;
    _fallbackNoticed = false;
    _notify();
  }

  /// True when a non-built-in strategy is active.
  bool get hasCustom => !identical(_active, builtin);

  /// Listen for strategy changes (install/uninstall). The TUI uses this
  /// to re-layout the live screen for `/layout`.
  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) =>
      _listeners.remove(listener);

  void _notify() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  /// Solve through the active strategy, falling back to the built-in on
  /// ANY failure (throw, bad rects upstream) with one notice per
  /// install.
  GridSolution solve(GridSpec spec, {required int columns, required int rows}) {
    final strategy = _active;
    if (!hasCustom) return builtin.solve(spec, columns: columns, rows: rows);
    try {
      return strategy.solve(spec, columns: columns, rows: rows);
    } catch (error) {
      if (!_fallbackNoticed) {
        _fallbackNoticed = true;
        onFallbackNotice?.call(
            'layout strategy "${strategy.id}" failed ($error); '
            'using the built-in solver');
      }
      return builtin.solve(spec, columns: columns, rows: rows);
    }
  }
}
