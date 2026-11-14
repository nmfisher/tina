#!/bin/sh
# Rebuild the layout strategy plugin components (see README.md for the
# toolchain prerequisites: the pinned Dart 3.14 SDK plus the wasm.dart
# checkout, both on PATH).
set -e
cd "$(dirname "$0")/.."
dart run wasm_tools witgen -i wit -w tina:layout-app/layout-plugin \
  -o .dart_tool/witgen
cp .dart_tool/witgen/tina_layout.dart \
   .dart_tool/witgen/tina_layout_app_layout_plugin.dart \
   .dart_tool/witgen/tina_layout_app_layout_plugin.json \
   lib/src/generated/
for guest in layout_solver layout_focus layout_hang; do
  dart run wasm_tools compile "bin/$guest.dart"
  dart run wasm_tools stamp-abi "bin/$guest.wasm" -o "bin/$guest.wasm"
done
ls -la bin/*.wasm
