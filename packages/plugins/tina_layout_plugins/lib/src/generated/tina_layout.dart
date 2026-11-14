// ignore_for_file: type=warning
import r'package:wasm_components/wasm_components.dart' as i0;

/// The layout contract vocabulary: tina_layout's GridSpec and solution
/// types as structured records (see tina docs/layout-plugin.md). The
/// record shapes are the single serialization - the same field names
/// serve the Dart codec (LayoutWire), the guest bindings and the host's
/// Val records. Plugins never change what a rectangle is.
abstract interface class Types {}

enum TypesTrackKind { fixed, weighted, auto }

/// What a layout strategy plugin exports. Pure function, zero
/// capabilities: a strategy imports nothing beyond WASI and the contract's
/// own types (the host admits nothing else).
abstract interface class Strategy {
  ({String id, String version, String description}) describe();

  /// Solve one spec for one terminal size. Synchronous; the host runs it
  /// under an epoch deadline and falls back to the built-in solver on
  /// any failure.
  i0.Result<
    ({
      int columns,
      int rows,
      ({double rowsPerUnit}) metrics,
      List<({String id, ({int col, int row, int width, int height}) rect})>
      rects,
      List<double> columnTrackSizes,
      List<double> rowTrackSizes,
      List<({String id, String reason})> dropped,
      double overflowUnitsX,
      double overflowUnitsY,
      double trailingGapUnitsX,
      double trailingGapUnitsY,
    }),
    String
  >
  solve({
    required ({
      List<
        ({
          TypesTrackKind kind,
          double sizeUnits,
          double weight,
          double minUnits,
          i0.Option<double> maxUnits,
        })
      >
      columns,
      List<
        ({
          TypesTrackKind kind,
          double sizeUnits,
          double weight,
          double minUnits,
          i0.Option<double> maxUnits,
        })
      >
      rows,
      List<
        ({
          String id,
          ({i0.Option<int> start, int span}) column,
          ({i0.Option<int> start, int span}) row,
          double minWidthUnits,
          double minHeightUnits,
          i0.Option<double> maxWidthUnits,
          i0.Option<double> maxHeightUnits,
          i0.Option<double> aspectHint,
          int priority,
        })
      >
      items,
    })
    spec,
    required int columns,
    required int rows,
    required ({double rowsPerUnit}) metrics,
  });
}

sealed class BridgeFallback {
  const BridgeFallback._();
  const factory BridgeFallback.noPlugin() = BridgeFallbackNoPlugin;
  const factory BridgeFallback.pluginError(String payload) =
      BridgeFallbackPluginError;
  const factory BridgeFallback.pluginTimeout(String payload) =
      BridgeFallbackPluginTimeout;
}

final class BridgeFallbackNoPlugin extends BridgeFallback {
  const BridgeFallbackNoPlugin() : super._();
}

final class BridgeFallbackPluginError extends BridgeFallback {
  final String payload;
  const BridgeFallbackPluginError(this.payload) : super._();
}

final class BridgeFallbackPluginTimeout extends BridgeFallback {
  final String payload;
  const BridgeFallbackPluginTimeout(this.payload) : super._();
}

/// The host-mediated bridge the TUI imports. The host routes solve calls
/// to the mounted strategy plugin's own Store; components never call
/// components.
abstract interface class Bridge {
  /// The mounted strategy, or none. Cheap enough to poll.
  i0.Option<({String id, String version, String description})> describe();
  i0.Result<
    ({
      int columns,
      int rows,
      ({double rowsPerUnit}) metrics,
      List<({String id, ({int col, int row, int width, int height}) rect})>
      rects,
      List<double> columnTrackSizes,
      List<double> rowTrackSizes,
      List<({String id, String reason})> dropped,
      double overflowUnitsX,
      double overflowUnitsY,
      double trailingGapUnitsX,
      double trailingGapUnitsY,
    }),
    BridgeFallback
  >
  solve({
    required ({
      List<
        ({
          TypesTrackKind kind,
          double sizeUnits,
          double weight,
          double minUnits,
          i0.Option<double> maxUnits,
        })
      >
      columns,
      List<
        ({
          TypesTrackKind kind,
          double sizeUnits,
          double weight,
          double minUnits,
          i0.Option<double> maxUnits,
        })
      >
      rows,
      List<
        ({
          String id,
          ({i0.Option<int> start, int span}) column,
          ({i0.Option<int> start, int span}) row,
          double minWidthUnits,
          double minHeightUnits,
          i0.Option<double> maxWidthUnits,
          i0.Option<double> maxHeightUnits,
          i0.Option<double> aspectHint,
          int priority,
        })
      >
      items,
    })
    spec,
    required int columns,
    required int rows,
    required ({double rowsPerUnit}) metrics,
  });
}
