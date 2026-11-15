// The layout-plugin link hook: supplies the generated component asset
// for this package's single world (tina:layout-app/layout-plugin).
import 'dart:convert';
import 'dart:io';

import 'package:hooks/hooks.dart';
import 'package:wasm_tools/hooks.dart';

void main(List<String> args) => link(args, (input, output) async {
      if (input.config.buildWasmComponent) {
        const abi = 'lib/src/generated/tina_layout_app_layout_plugin.json';
        final file = File.fromUri(input.packageRoot.resolve(abi));
        output.dependencies.add(input.packageRoot.resolve(abi));
        output.assets.webAssemblyComponents.add(
          WasmComponentAsset(
            encoded: json.decode(file.readAsStringSync()) as Map<String, Object?>,
          ),
        );
      }
    });
