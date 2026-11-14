/// The host-mediated layout strategy: `tina:layout/bridge@1.0.0`.
///
/// Every solve crosses into the Rust host, which routes it to the
/// mounted strategy plugin's own Store (components never call
/// components). Absent, erroring or epoch-killed plugins surface as
/// [LayoutBridgeFallback] — this strategy rethrows those so the
/// dispatcher in `tina_layout` falls back to the compiled-in solver and
/// notices once per install. A wedged layout plugin can cost one host
/// deadline interval, never the screen.
library;

import 'package:tina_layout/tina_layout.dart';
import 'package:wasm_components/wasm_components.dart' as cm;

import 'components/tina_layout.dart' as wit;

import 'layout_bridge_codec.dart';

final class BridgeLayoutStrategy implements LayoutStrategy {
  BridgeLayoutStrategy(this._bridge);

  final wit.Bridge _bridge;

  @override
  StrategyDescriptor describe() {
    final reported = mounted();
    if (reported == null) {
      throw StateError('no layout plugin is mounted');
    }
    return StrategyDescriptor(
      id: reported.id,
      version: reported.version,
      description: reported.description,
    );
  }

  /// The mounted plugin's id for cheap display (the host bridge is the
  /// only strategy whose identity lives across the boundary).
  @override
  String get id => mounted()?.id ?? 'tina/layout-bridge';

  /// The mounted strategy per the host, or `null` when none is.
  ({String id, String version, String description})? mounted() {
    final reported = _bridge.describe();
    if (!reported.hasValue) return null;
    return reported.requireValue();
  }

  @override
  GridSolution solveSpec(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    final result = _bridge.solve(
      spec: specToBridge(spec),
      columns: columns,
      rows: rows,
      metrics: (rowsPerUnit: metrics.rowsPerUnit),
    );
    switch (result) {
      case cm.OkResult():
        return solutionFromBridge(result.value);
      case cm.ErrorResult(value: final fallback):
        throw StateError(switch (fallback) {
          wit.BridgeFallbackNoPlugin() => 'no layout plugin is mounted',
          wit.BridgeFallbackPluginError(:final payload) =>
            'layout plugin error: $payload',
          wit.BridgeFallbackPluginTimeout(:final payload) =>
            'layout plugin timed out: $payload',
        });
    }
  }
}
