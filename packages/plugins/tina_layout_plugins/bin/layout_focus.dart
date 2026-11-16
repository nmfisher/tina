/// `tina/layout-focus` — the deliberately different demo strategy
/// (`tina:layout/strategy@1.0.0`): weighted tracks share the remaining
/// space equally, so the chat screen's 65/35 split becomes 50/50.
/// Installing this must visibly change the arrangement; uninstalling
/// returns the default. Zero capabilities.
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
      (id: 'tina/layout-focus',
       version: '1.0.0',
       description: 'Focus mode: weighted tracks split the remaining '
           'space equally (65/35 becomes 50/50).');

  @override
  cm.Result<WireSolution, String> solve({
    required GeneratedSpec spec,
    required int columns,
    required int rows,
    required ({double rowsPerUnit}) metrics,
  }) {
    try {
      final solved = focusSolveMap(
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
