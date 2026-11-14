/// Conversions between [LayoutWire]'s JSON-shaped boundary records and
/// the generated WIT record shapes (anonymous Dart records, structural
/// types - no generated import needed here, so these run on the plain VM
/// in tests and inside the guest in builds).
library;

import 'package:tina_layout/tina_layout.dart';

/// The generated WIT shapes this codec targets, as structural record
/// types (identical to the witgen output in lib/src/generated).
typedef WireTrack = ({
  int kind, // 0 fixed, 1 weighted, 2 auto (TypesTrackKind order)
  double sizeUnits,
  double weight,
  double minUnits,
  double? maxUnits,
});
typedef WireSpan = ({int? start, int span});
typedef WireItem = ({
  String id,
  WireSpan column,
  WireSpan row,
  double minWidthUnits,
  double minHeightUnits,
  double? maxWidthUnits,
  double? maxHeightUnits,
  double? aspectHint,
  int priority,
});
typedef WireSpec = ({
  List<WireTrack> columns,
  List<WireTrack> rows,
  List<WireItem> items,
});
typedef WireMetrics = ({double rowsPerUnit});
typedef WireRect = ({int col, int row, int width, int height});
typedef WireRectEntry = ({String id, WireRect rect});
typedef WireDrop = ({String id, String reason});
typedef WireSolution = ({
  int columns,
  int rows,
  WireMetrics metrics,
  List<WireRectEntry> rects,
  List<double> columnTrackSizes,
  List<double> rowTrackSizes,
  List<WireDrop> dropped,
  double overflowUnitsX,
  double overflowUnitsY,
  double trailingGapUnitsX,
  double trailingGapUnitsY,
});

int _wireTrackKind(String name) => switch (name) {
      'fixed' => 0,
      'weighted' => 1,
      'auto' => 2,
      _ => throw FormatException('unknown track kind: $name'),
    };

String _trackKindName(int kind) => switch (kind) {
      0 => 'fixed',
      1 => 'weighted',
      2 => 'auto',
      _ => throw FormatException('unknown track kind: $kind'),
    };

/// Map a spec record to the boundary map (the generated record arrived as
/// a Dart record; convert to LayoutWire's map form).
Map<String, Object?> specRecordToMap(WireSpec spec) => LayoutWire.spec(_specFromWire(spec));

/// Map a boundary request map to the spec record the guest receives.
WireSpec specMapToRecord(Map<Object?, Object?> map) {
  final spec = LayoutWire.specFromRecord(map);
  return (
    columns: [
      for (final t in spec.columns)
        (
          kind: _wireTrackKind(t.kind.name),
          sizeUnits: t.sizeUnits,
          weight: t.weight,
          minUnits: t.minUnits,
          maxUnits: t.maxUnits.isInfinite ? null : t.maxUnits,
        ),
    ],
    rows: [
      for (final t in spec.rows)
        (
          kind: _wireTrackKind(t.kind.name),
          sizeUnits: t.sizeUnits,
          weight: t.weight,
          minUnits: t.minUnits,
          maxUnits: t.maxUnits.isInfinite ? null : t.maxUnits,
        ),
    ],
    items: [
      for (final i in spec.items)
        (
          id: i.id,
          column: (start: i.column.start, span: i.column.span),
          row: (start: i.row.start, span: i.row.span),
          minWidthUnits: i.minWidthUnits,
          minHeightUnits: i.minHeightUnits,
          maxWidthUnits: i.maxWidthUnits,
          maxHeightUnits: i.maxHeightUnits,
          aspectHint: i.aspectHint,
          priority: i.priority,
        ),
    ],
  );
}

GridSpec _specFromWire(WireSpec spec) => GridSpec(
      columns: [
        for (final t in spec.columns)
          switch (t.kind) {
            0 => GridTrack.fixed(t.sizeUnits,
                minUnits: t.minUnits,
                maxUnits: t.maxUnits ?? double.infinity),
            1 => GridTrack.weighted(t.weight,
                minUnits: t.minUnits,
                maxUnits: t.maxUnits ?? double.infinity),
            _ => GridTrack.auto(
                minUnits: t.minUnits,
                maxUnits: t.maxUnits ?? double.infinity),
          },
      ],
      rows: [
        for (final t in spec.rows)
          switch (t.kind) {
            0 => GridTrack.fixed(t.sizeUnits,
                minUnits: t.minUnits,
                maxUnits: t.maxUnits ?? double.infinity),
            1 => GridTrack.weighted(t.weight,
                minUnits: t.minUnits,
                maxUnits: t.maxUnits ?? double.infinity),
            _ => GridTrack.auto(
                minUnits: t.minUnits,
                maxUnits: t.maxUnits ?? double.infinity),
          },
      ],
      items: [
        for (final i in spec.items)
          GridItem(
            id: i.id,
            column: i.column.start == null
                ? (i.column.span > 1
                    ? TrackSpan.span(i.column.span)
                    : TrackSpan.auto())
                : TrackSpan.at(i.column.start!, span: i.column.span),
            row: i.row.start == null
                ? (i.row.span > 1
                    ? TrackSpan.span(i.row.span)
                    : TrackSpan.auto())
                : TrackSpan.at(i.row.start!, span: i.row.span),
            minWidthUnits: i.minWidthUnits,
            minHeightUnits: i.minHeightUnits,
            maxWidthUnits: i.maxWidthUnits,
            maxHeightUnits: i.maxHeightUnits,
            aspectHint: i.aspectHint,
            priority: i.priority,
          ),
      ],
    );

/// Map a solution (from the core types) to the record the guest returns.
WireSolution solutionToRecord(GridSolution solution) {
  final map = LayoutWire.solution(solution);
  final metrics = map['metrics']! as Map;
  return (
    columns: map['columns']! as int,
    rows: map['rows']! as int,
    metrics: (rowsPerUnit: metrics['rows-per-unit']! as double),
    rects: [
      for (final entry in map['rects']! as List)
        () {
          final e = entry as Map;
          final r = e['rect']! as Map;
          return (
            id: e['id']! as String,
            rect: (
              col: r['col']! as int,
              row: r['row']! as int,
              width: r['width']! as int,
              height: r['height']! as int,
            ),
          );
        }(),
    ],
    columnTrackSizes: [
      for (final v in map['column-track-sizes']! as List) v as double,
    ],
    rowTrackSizes: [
      for (final v in map['row-track-sizes']! as List) v as double,
    ],
    dropped: [
      for (final d in map['dropped']! as List)
        () {
          final m = d as Map;
          return (id: m['id']! as String, reason: m['reason']! as String);
        }(),
    ],
    overflowUnitsX: map['overflow-units-x']! as double,
    overflowUnitsY: map['overflow-units-y']! as double,
    trailingGapUnitsX: map['trailing-gap-units-x']! as double,
    trailingGapUnitsY: map['trailing-gap-units-y']! as double,
  );
}

/// Map the returned solution record back to the core [GridSolution]
/// (through the boundary map, so the same validation applies).
GridSolution solutionRecordToCore(WireSolution solution) {
  final metricsMap = <String, Object?>{
    'rows-per-unit': solution.metrics.rowsPerUnit,
  };
  return LayoutWire.solutionFromRecord({
    'columns': solution.columns,
    'rows': solution.rows,
    'metrics': metricsMap,
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

const trackKindName = _trackKindName;
