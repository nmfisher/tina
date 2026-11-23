#!/bin/sh
set -e
# Regenerate the host's component bindings from world.wit. Requires the
# wasm_tools package (materialize pubspec_overrides.yaml pointing it at a
# wasm.dart checkout first — see README).
(cd "$(dirname "$0")/.." && dart run wasm_tools witgen -i world.wit)
