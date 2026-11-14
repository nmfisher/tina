/// Record marshalling between tina_layout's boundary maps and the
/// generated `tina:layout` bridge bindings. The bridge record types are
/// anonymous Dart records (structural): these local aliases spell the
/// generated shapes — enum track kinds and `Option` bounds — without
/// importing generated code, so unit tests can run on the plain VM.
library;

import 'package:tina_layout/tina_layout.dart';
import 'package:wasm_components/wasm_components.dart' as cm;

import 'components/tina_layout.dart' as wit;

typedef _BridgeTrack = ({
  wit.TypesTrackKind kind,
  double sizeUnits,
  double weight,
  double minUnits,
  cm.Option<double> maxUnits,
});
typedef _BridgeSpan = ({cm.Option<int> start, int span});
typedef _BridgeItem = ({
  String id,
  _BridgeSpan column,
  _BridgeSpan row,
  double minWidthUnits,
  double minHeightUnits,
  cm.Option<double> maxWidthUnits,
  cm.Option<double> maxHeightUnits,
  cm.Option<double> aspectHint,
  int priority,
});
typedef BridgeSpec = ({
  List<_BridgeTrack> columns,
  List<_BridgeTrack> rows,
  List<_BridgeItem> items,
});
typedef BridgeSolution = ({
  int columns,
  int rows,
  ({double rowsPerUnit}) metrics,
  List<({String id, ({int col, int row, int width, int height}) rect})> rects,
  List<double> columnTrackSizes,
  List<double> rowTrackSizes,
  List<({String id, String reason})> dropped,
  double overflowUnitsX,
  double overflowUnitsY,
  double trailingGapUnitsX,
  double trailingGapUnitsY,
});

cm.Option<double> _opt(double? value) => value == null
    ? cm.Option.none
    : cm.Option<double>.some(value);

/// Encode a spec for the bridge call.
BridgeSpec specToBridge(GridSpec spec) => _specFromMap(LayoutWire.spec(spec));

BridgeSpec _specFromMap(Map<String, Object?> map) {
  final columns = map['columns']! as List;
  final rows = map['rows']! as List;
  final items = map['items']! as List;
  return (
    columns: [for (final t in columns) _trackFromMap(t as Map)],
    rows: [for (final t in rows) _trackFromMap(t as Map)],
    items: [for (final i in items) _itemFromMap(i as Map)],
  );
}

_BridgeTrack _trackFromMap(Map map) => (
      kind: switch (map['kind'] as String) {
        'fixed' => wit.TypesTrackKind.fixed,
        'weighted' => wit.TypesTrackKind.weighted,
        _ => wit.TypesTrackKind.auto,
      },
      sizeUnits: (map['size-units']! as num).toDouble(),
      weight: (map['weight']! as num).toDouble(),
      minUnits: (map['min-units']! as num).toDouble(),
      maxUnits: _opt((map['max-units'] as num?)?.toDouble()),
    );

_BridgeSpan _spanFromMap(Map map) => (
      start: map['start'] == null
          ? cm.Option.none
          : cm.Option<int>.some(map['start']! as int),
      span: map['span']! as int,
    );

_BridgeItem _itemFromMap(Map map) => (
      id: map['id']! as String,
      column: _spanFromMap(map['column']! as Map),
      row: _spanFromMap(map['row']! as Map),
      minWidthUnits: (map['min-width-units']! as num).toDouble(),
      minHeightUnits: (map['min-height-units']! as num).toDouble(),
      maxWidthUnits: _opt((map['max-width-units'] as num?)?.toDouble()),
      maxHeightUnits: _opt((map['max-height-units'] as num?)?.toDouble()),
      aspectHint: _opt((map['aspect-hint'] as num?)?.toDouble()),
      priority: map['priority']! as int,
    );

/// Decode the bridge's solution through the boundary map so the same
/// validation (`LayoutWire.solutionFromRecord`) applies on the way in.
GridSolution solutionFromBridge(BridgeSolution solution) {
  return LayoutWire.solutionFromRecord({
    'columns': solution.columns,
    'rows': solution.rows,
    'metrics': {
      'rows-per-unit': solution.metrics.rowsPerUnit,
    },
    'rects': [
      for (final entry in solution.rects)
        {
          'id': entry.id,
          'rect': {
            'col': entry.rect.col,
            'row': entry.rect.row,
            'width': entry.rect.width,
            'height': entry.rect.height,
          },
        },
    ],
    'column-track-sizes': solution.columnTrackSizes,
    'row-track-sizes': solution.rowTrackSizes,
    'dropped': [
      for (final d in solution.dropped) {'id': d.id, 'reason': d.reason},
    ],
    'overflow-units-x': solution.overflowUnitsX,
    'overflow-units-y': solution.overflowUnitsY,
    'trailing-gap-units-x': solution.trailingGapUnitsX,
    'trailing-gap-units-y': solution.trailingGapUnitsY,
  });
}
