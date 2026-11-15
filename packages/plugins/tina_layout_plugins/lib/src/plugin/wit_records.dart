/// Wasm-only conversions between the GENERATED WIT record shapes and
/// [LayoutWire]'s boundary maps. The generated spec carries the
/// `TypesTrackKind` enum and `Option` fields; the solution records are
/// structural-identical to the codec's output (no enums, no options).
/// This file imports generated bindings and compiles only under
/// dart2wasm - never from tests.
library;

import 'package:wasm_components/wasm_components.dart' show Option;
import 'package:tina_layout_plugins/src/generated/tina_layout.dart' as wit;

typedef _WitTrack = ({
  wit.TypesTrackKind kind,
  double sizeUnits,
  double weight,
  double minUnits,
  Option<double> maxUnits,
});
typedef _WitSpan = ({Option<int> start, int span});
typedef _WitItem = ({
  String id,
  _WitSpan column,
  _WitSpan row,
  double minWidthUnits,
  double minHeightUnits,
  Option<double> maxWidthUnits,
  Option<double> maxHeightUnits,
  Option<double> aspectHint,
  int priority,
});

/// The generated spec record type (anonymous; spelled out once here).
typedef GeneratedSpec = ({
  List<_WitTrack> columns,
  List<_WitTrack> rows,
  List<_WitItem> items,
});

double? _opt(Option<double> option) =>
    option.hasValue ? option.requireValue() : null;

int? _optInt(Option<int> option) =>
    option.hasValue ? option.requireValue() : null;

String _kindName(wit.TypesTrackKind kind) => switch (kind) {
      wit.TypesTrackKind.fixed => 'fixed',
      wit.TypesTrackKind.weighted => 'weighted',
      wit.TypesTrackKind.auto => 'auto',
    };

Map<String, Object?> _track(_WitTrack t) => {
      'kind': _kindName(t.kind),
      'size-units': t.sizeUnits,
      'weight': t.weight,
      'min-units': t.minUnits,
      'max-units': _opt(t.maxUnits),
    };

/// Convert a received spec record to the boundary map.
Map<String, Object?> generatedSpecToMap(GeneratedSpec spec) => {
      'columns': [for (final t in spec.columns) _track(t)],
      'rows': [for (final t in spec.rows) _track(t)],
      'items': [
        for (final i in spec.items)
          {
            'id': i.id,
            'column': {
              'start': _optInt(i.column.start),
              'span': i.column.span,
            },
            'row': {
              'start': _optInt(i.row.start),
              'span': i.row.span,
            },
            'min-width-units': i.minWidthUnits,
            'min-height-units': i.minHeightUnits,
            'max-width-units': _opt(i.maxWidthUnits),
            'max-height-units': _opt(i.maxHeightUnits),
            'aspect-hint': _opt(i.aspectHint),
            'priority': i.priority,
          },
      ],
    };
