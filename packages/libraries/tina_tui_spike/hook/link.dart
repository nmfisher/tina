// The spike's link hook: supplies the generated component asset when the
// package compiles to wasm (same shape as tina_wasm's hook/link.dart).
import 'dart:convert';
import 'dart:io';

import 'package:hooks/hooks.dart';
import 'package:wasm_tools/hooks.dart';

void main(List<String> args) => link(args, (input, output) async {
      if (input.config.buildWasmComponent) {
        final abi = input.packageRoot.resolve(
          'lib/src/components/tina_tui_tui_spike.json',
        );

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
