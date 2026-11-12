// The wasm composition roots' link hook: supplies the generated component
// asset when the package compiles to wasm. The ABI json follows the entry
// point the compiler records in the hook input (bin/engine.dart ->
// engine-probe, bin/tui.dart -> tui-app); entry points are part of the
// hooks runner's cache key, so each composition root gets its own cached
// ABI choice. The typed input does not surface the entry points, so the
// raw input json (sibling of the output file the typed input exposes) is
// read here.
import 'dart:convert';
import 'dart:io';

import 'package:hooks/hooks.dart';
import 'package:wasm_tools/hooks.dart';

void main(List<String> args) => link(args, (input, output) async {
      if (input.config.buildWasmComponent) {
        final abi = input.packageRoot.resolve(_abiFor(input));

        output.dependencies.add(abi);
        output.assets.webAssemblyComponents.add(
          WasmComponentAsset(
            encoded: json.decode(
              File(abi.toFilePath()).readAsStringSync(),
            ) as Map<String, Object?>,
          ),
        );
      }
    });

/// The ABI json for the entry point this link-hook invocation serves: the
/// compiler's recorded uses name the component function the guest used
/// (`tuiAppComponent` from `tina_probe_tui_app.dart`, else the engine
/// world). Unknown recordings fall back to the engine world.
String _abiFor(LinkInput input) {
  const tuiAbi = 'lib/src/components/tina_probe_tui_app.json';
  const engineAbi = 'lib/src/components/tina_probe_engine_probe.json';
  try {
    // ignore: deprecated_member_use
    final file = input.recordedUsagesFile;
    if (file == null) return engineAbi;
    final text = File.fromUri(file).readAsStringSync();
    return text.contains('tina_probe_tui_app.dart') ? tuiAbi : engineAbi;
  } catch (_) {
    return engineAbi;
  }
}
