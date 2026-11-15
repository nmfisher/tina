import 'geometry.dart';
import 'solver.dart' show GridSolution, GridSolver, UnitRect;
import 'spec.dart';

/// The single serialization between tina_layout's core types and the
/// `tina:layout@1.0.0` boundary records (see `docs/layout-plugin.md`).
///
/// The record shapes mirror the WIT field names exactly (kebab-case keys,
/// JSON-shaped maps), so the same vocabulary serves
/// [GridSpec] ↔ WIT records in plugin guests, `Val` records in the Rust
/// host, and the committed JSON golden tables used by the differential
/// tests. One codec, no second serialization to drift.
///
/// Every decode validates: a record that would produce negative or
/// out-of-terminal rects throws, which the strategy dispatcher treats as
/// a fallback trigger. Plugins never change what a rectangle is.
final class LayoutWire {
  LayoutWire._();

  static const version = '1.0.0';

  // -- Metrics -----------------------------------------------------------

  static Map<String, Object?> metrics(CellMetrics metrics) =>
      {'rows-per-unit': metrics.rowsPerUnit};

  static CellMetrics metricsFromRecord(Map<Object?, Object?> record) {
    final rowsPerUnit = _num(record, 'rows-per-unit');
    if (rowsPerUnit <= 0) {
      throw const FormatException('rows-per-unit must be positive');
    }
    return CellMetrics.withRowsPerUnit(rowsPerUnit);
  }

  // -- Spec ---------------------------------------------------------------

  static Map<String, Object?> spec(GridSpec spec) => {
        'columns': [for (final t in spec.columns) LayoutWire.track(t)],
        'rows': [for (final t in spec.rows) LayoutWire.track(t)],
        'items': [for (final i in spec.items) LayoutWire.item(i)],
      };

  static GridSpec specFromRecord(Map<Object?, Object?> record) {
    final columns = _list(record, 'columns');
    final rows = _list(record, 'rows');
    final items = _list(record, 'items');
    if (columns.isEmpty || rows.isEmpty) {
      throw const FormatException('spec needs at least one track per axis');
    }
    return GridSpec(
      columns: [for (final t in columns) trackFromRecord(_map(t))],
      rows: [for (final t in rows) trackFromRecord(_map(t))],
      items: [
        for (final i in items) itemFromRecord(_map(i))
      ],
    );
  }

  static Map<String, Object?> track(GridTrack track) => {
        'kind': track.kind.name,
        'size-units': track.sizeUnits,
        'weight': track.weight,
        'min-units': track.minUnits,
        // `null` = unbounded (the GridTrack default): keeps the boundary
        // records JSON-safe for the golden tables; WIT carries it as
        // option<f64>.
        'max-units': track.maxUnits.isInfinite ? null : track.maxUnits,
      };

  static GridTrack trackFromRecord(Map<Object?, Object?> record) {
    final kindName = _string(record, 'kind');
    final TrackKind kind;
    switch (kindName) {
      case 'fixed':
        kind = TrackKind.fixed;
      case 'weighted':
        kind = TrackKind.weighted;
      case 'auto':
        kind = TrackKind.auto;
      default:
        throw FormatException('unknown track kind: $kindName');
    }
    final max = _optNum(record, 'max-units') ?? double.infinity;
    if (max.isNaN || max < 0) {
      throw const FormatException('max-units must be non-negative');
    }
    return switch (kind) {
      TrackKind.fixed => GridTrack.fixed(_num(record, 'size-units'),
          minUnits: _num(record, 'min-units'), maxUnits: max),
      TrackKind.weighted => GridTrack.weighted(_num(record, 'weight'),
          minUnits: _num(record, 'min-units'), maxUnits: max),
      TrackKind.auto => GridTrack.auto(
          minUnits: _num(record, 'min-units'), maxUnits: max),
    };
  }

  static Map<String, Object?> item(GridItem item) => {
        'id': item.id,
        'column': LayoutWire.span(item.column),
        'row': LayoutWire.span(item.row),
        'min-width-units': item.minWidthUnits,
        'min-height-units': item.minHeightUnits,
        'max-width-units': item.maxWidthUnits,
        'max-height-units': item.maxHeightUnits,
        'aspect-hint': item.aspectHint,
        'priority': item.priority,
      };

  static GridItem itemFromRecord(Map<Object?, Object?> record) {
    final id = _string(record, 'id');
    final column = spanFromRecord(_map(record['column']));
    final row = spanFromRecord(_map(record['row']));
    final priority = _int(record, 'priority');
    return GridItem(
      id: id,
      column: column,
      row: row,
      minWidthUnits: _num(record, 'min-width-units'),
      minHeightUnits: _num(record, 'min-height-units'),
      maxWidthUnits: _optNum(record, 'max-width-units'),
      maxHeightUnits: _optNum(record, 'max-height-units'),
      aspectHint: _optNum(record, 'aspect-hint'),
      priority: priority,
    );
  }

  static Map<String, Object?> span(TrackSpan span) => {
        'start': span.start,
        'span': span.span,
      };

  static TrackSpan spanFromRecord(Map<Object?, Object?> record) {
    final span = _int(record, 'span');
    if (span < 1) throw const FormatException('span must be >= 1');
    final start = record['start'];
    if (start == null) return span > 1 ? TrackSpan.span(span) : TrackSpan.auto();
    if (start is! int) {
      throw const FormatException('start must be an integer or null');
    }
    return TrackSpan.at(start, span: span);
  }

  // -- Solution -----------------------------------------------------------

  static Map<String, Object?> solution(GridSolution solution) => {
        'columns': solution.columns,
        'rows': solution.rows,
        'metrics': LayoutWire.metrics(solution.metrics),
        'rects': [
          for (final entry in solution.rects.entries)
            {'id': entry.key, 'rect': LayoutWire.rect(entry.value)},
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
      };

  static GridSolution solutionFromRecord(Map<Object?, Object?> record) {
    final columns = _int(record, 'columns');
    final rows = _int(record, 'rows');
    if (columns < 0 || rows < 0) {
      throw const FormatException('terminal size must be non-negative');
    }
    final metrics = metricsFromRecord(_map(record['metrics']));
    final rectEntries = _list(record, 'rects');
    final rects = <String, GridRect>{};
    final unitRects = <String, UnitRect>{};
    for (final entry in rectEntries) {
      final map = _map(entry);
      final id = _string(map, 'id');
      final rect = rectFromRecord(_map(map['rect']));
      if (rect.col < 0 ||
          rect.row < 0 ||
          rect.col + rect.width > columns ||
          rect.row + rect.height > rows) {
        throw FormatException('rect for "$id" escapes the terminal: $rect');
      }
      if (rects.containsKey(id)) {
        throw FormatException('duplicate rect id: $id');
      }
      rects[id] = rect;
      unitRects[id] = UnitRect(
        col: rect.col.toDouble(),
        row: metrics.rowsToUnits(rect.row.toDouble()),
        width: rect.width.toDouble(),
        height: metrics.rowsToUnits(rect.height.toDouble()),
      );
    }
    final dropped = <GridDrop>[
      for (final d in _list(record, 'dropped')) GridDrop(
        id: _string(_map(d), 'id'),
        reason: _string(_map(d), 'reason'),
      ),
    ];
    return GridSolution(
      columns: columns,
      rows: rows,
      metrics: metrics,
      rects: rects,
      unitRects: unitRects,
      columnTrackSizes: [
        for (final v in _list(record, 'column-track-sizes')) _dbl(v)
      ],
      rowTrackSizes: [
        for (final v in _list(record, 'row-track-sizes')) _dbl(v)
      ],
      dropped: dropped,
      overflowUnitsX: _num(record, 'overflow-units-x'),
      overflowUnitsY: _num(record, 'overflow-units-y'),
      trailingGapUnitsX: _num(record, 'trailing-gap-units-x'),
      trailingGapUnitsY: _num(record, 'trailing-gap-units-y'),
    );
  }

  static Map<String, Object?> rect(GridRect rect) => {
        'col': rect.col,
        'row': rect.row,
        'width': rect.width,
        'height': rect.height,
      };

  static GridRect rectFromRecord(Map<Object?, Object?> record) {
    final rect = GridRect(
      col: _int(record, 'col'),
      row: _int(record, 'row'),
      width: _int(record, 'width'),
      height: _int(record, 'height'),
    );
    if (rect.width < 0 || rect.height < 0) {
      throw FormatException('negative rect extent: $rect');
    }
    return rect;
  }

  // -- Full solve request (golden tables) ---------------------------------

  static Map<String, Object?> request(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    return {
      'spec': LayoutWire.spec(spec),
      'columns': columns,
      'rows': rows,
      'metrics': LayoutWire.metrics(metrics),
    };
  }

  /// The canonical golden form: a solve request plus the expected
  /// solution record.
  static Map<String, Object?> goldenCase(String name, GridSpec spec,
      {required int columns, required int rows,
      CellMetrics metrics = CellMetrics.standard}) => {
        'name': name,
        'request': LayoutWire.request(spec, columns: columns, rows: rows, metrics: metrics),
        'expected': LayoutWire.solution(GridSolver.solve(spec,
            columns: columns, rows: rows, metrics: metrics)),
      };

  // -- Field helpers --------------------------------------------------------

  static num _asNum(Object? value) {
    if (value is num) return value;
    throw const FormatException('expected a number');
  }

  static double _dbl(Object? value) => _asNum(value).toDouble();

  static double _num(Map<Object?, Object?> record, String key) =>
      _dbl(record[key]);

  static double? _optNum(Map<Object?, Object?> record, String key) {
    final value = record[key];
    return value == null ? null : _dbl(value);
  }

  static int _int(Map<Object?, Object?> record, String key) {
    final value = record[key];
    if (value is int) return value;
    if (value is num && value.toInt() == value) return value.toInt();
    throw FormatException('expected an integer for "$key": $value');
  }

  static String _string(Map<Object?, Object?> record, String key) {
    final value = record[key];
    if (value is String) return value;
    throw FormatException('expected a string for "$key": $value');
  }

  static List<Object?> _list(Map<Object?, Object?> record, String key) {
    final value = record[key];
    if (value is List) return value;
    throw FormatException('expected a list for "$key": $value');
  }

  static Map<Object?, Object?> _map(Object? value) {
    if (value is Map) return value;
    throw FormatException('expected a record: $value');
  }
}
