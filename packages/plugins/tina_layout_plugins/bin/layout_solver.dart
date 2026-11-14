/// `tina/layout-solver` — the built-in tina_layout solver as a wasm
/// layout-strategy plugin (`tina:layout/strategy@1.0.0`). Zero
/// capabilities: this component imports nothing beyond WASI.
library;

import 'package:wasm_components/wasm_components.dart' as cm;
import 'package:tina_layout/tina_layout.dart' show CellMetrics;
import 'package:tina_layout_plugins/src/plugin/layout_codec.dart'
    show WireSolution, solutionToRecord;
import 'package:tina_layout_plugins/src/plugin/strategies.dart';
import 'package:tina_layout_plugins/src/plugin/wit_records.dart';
import 'package:tina_layout_plugins/src/generated/tina_layout.dart' as wit;
import 'package:tina_layout_plugins/src/generated/tina_layout_app_layout_plugin.dart'
    show LayoutPluginImports, layoutPluginComponent;

void main() {
  layoutPluginComponent((LayoutPluginImports imports) => _Guest());
}

final class _Guest implements wit.Strategy {
  @override
  ({String id, String version, String description}) describe() =>
      (id: 'tina/layout-solver',
       version: '1.0.0',
       description: 'The tina_layout grid solver as an installable '
           'strategy: identical rects to the built-in, by construction.');

  @override
  cm.Result<WireSolution, String> solve({
    required GeneratedSpec spec,
    required int columns,
    required int rows,
    required ({double rowsPerUnit}) metrics,
  }) {
    try {
      final solved = solveThroughWireMap(
        generatedSpecToMap(spec),
        columns: columns,
        rows: rows,
        metrics: CellMetrics.withRowsPerUnit(metrics.rowsPerUnit),
      );
      return cm.Result.ok(solutionToRecord(solved));
    } catch (error) {
      return cm.Result.error('$error');
    }
  }
}
