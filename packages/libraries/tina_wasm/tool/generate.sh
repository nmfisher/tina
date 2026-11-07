#!/bin/sh
# Regenerate the WIT interop bindings (lib/src/components) from wit/.
# Requires the Dart SDK on PATH; run from this package's directory.
set -e
cd "$(dirname "$0")/.."
dart run wasm_tools witgen -i wit -w "tina:probe/engine-probe"
