#!/bin/sh
# The stage-3 exit test: run the tina-shaped probe under wasmtime and on
# native Dart, and require identical recorded output.
#
# Usage: exit_test.sh [workspace_dir]
# Requires: the fake provider (tool/fake_anthropic_server.py) on
# 127.0.0.1:8730, the pinned Dart SDK on PATH, the wasm.dart test_runner
# built at <wasm.dart>/target/debug/test_runner, and wasm_tools resolvable
# (path overrides) for the compile.
set -e
cd "$(dirname "$0")/.."
WS="${1:-/tmp/probe-ws}"
RUNNER="${RUNNER:-/workspace/target/debug/test_runner}"
NATIVE_OUT=/tmp/exit_native.txt
WASM_OUT=/tmp/exit_wasm.txt

rm -f "$WS/out/probe-write.txt"

echo "=== native probe"
(cd "$WS" && TINA_LLM_ENDPOINT=http://127.0.0.1:8730 TINA_LLM_TOKEN=probe-token \
  dart run --enable-asserts bin/native_probe.dart) | tee "$NATIVE_OUT"

rm -f "$WS/out/probe-write.txt"

echo "=== wasm compile"
dart run wasm_tools compile bin/probe.dart

echo "=== wasm probe under wasmtime"
"$RUNNER" bin/probe.wasm \
  --preopen=.="$WS" \
  --env=TINA_LLM_ENDPOINT=http://127.0.0.1:8730 \
  --env=TINA_LLM_TOKEN=probe-token | tee "$WASM_OUT"

echo "=== compare"
if diff -u "$NATIVE_OUT" "$WASM_OUT"; then
  echo "IDENTICAL: $(wc -l < "$NATIVE_OUT") recorded lines match"
else
  echo "MISMATCH"
  exit 1
fi
