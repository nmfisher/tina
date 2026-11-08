#!/bin/sh
# The stage-4 process exit test: run the process probe under wasmtime
# and on native Dart, and require identical recorded output.
#
# Usage: process_exit_test.sh [workspace_dir]
# Requires: the pinned Dart SDK on PATH, the wasm.dart test_runner built
# at <wasm.dart>/target/debug/test_runner, and wasm_tools resolvable
# (path overrides) for the compile. Creates a throwaway git repository
# as the workspace so `git status` is deterministic.
set -e
cd "$(dirname "$0")/.."
PKG="$PWD"
WS="${1:-/tmp/process-ws}"
RUNNER="${RUNNER:-/workspace/target/debug/test_runner}"
NATIVE_OUT=/tmp/process_exit_native.txt
WASM_OUT=/tmp/process_exit_wasm.txt

if [ ! -d "$WS/.git" ]; then
  echo "=== preparing workspace repo $WS"
  rm -rf "$WS"
  mkdir -p "$WS"
  (cd "$WS" &&
    git init -q -b main &&
    git -c user.name=probe -c user.email=probe@example.invalid \
      commit -q --allow-empty -m "probe base")
fi

echo "=== native probe"
(cd "$WS" && dart run --enable-asserts "$PKG/bin/native_process_probe.dart") \
  | tee "$NATIVE_OUT"

echo "=== wasm compile"
dart run wasm_tools compile bin/process_probe.dart

echo "=== wasm probe under wasmtime"
"$RUNNER" bin/process_probe.wasm --preopen=.="$WS" | tee "$WASM_OUT"

echo "=== compare"
if diff -u "$NATIVE_OUT" "$WASM_OUT"; then
  echo "IDENTICAL: $(wc -l < "$NATIVE_OUT") recorded lines match"
else
  echo "MISMATCH"
  exit 1
fi
