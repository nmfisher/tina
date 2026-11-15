/// `tina/layout-hang` — the wedge fixture (`tina:layout/strategy@1.0.0`):
/// `solve` never returns. Built to prove the host's per-call epoch
/// deadline kills a stuck layout strategy and the TUI falls back to the
/// built-in solver without wedging the screen. `describe` still answers,
/// so the bridge reports the plugin before the first solve hangs. Never
/// install for real use. Zero capabilities.
library;

import 'package:wasm_components/wasm_components.dart' as cm;
import 'package:tina_layout_plugins/src/plugin/layout_codec.dart'
    show WireSolution;
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
      (id: 'tina/layout-hang',
       version: '1.0.0',
       description: 'TEST FIXTURE: solve() never returns; the host must '
           'epoch-kill it and the TUI must fall back.');

  @override
  cm.Result<WireSolution, String> solve({
    required GeneratedSpec spec,
    required int columns,
    required int rows,
    required ({double rowsPerUnit}) metrics,
  }) {
    // Park until the host's epoch deadline interrupts the call.
    var sink = 0;
    while (true) {
      sink = (sink + 1) & 0x3fffffff;
    }
  }
}
