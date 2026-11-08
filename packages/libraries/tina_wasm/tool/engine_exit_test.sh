#!/bin/sh
# The stage-5 exit test: the REAL engine completes one full agent turn
# over the pipes protocol, natively AND as a wasm component under
# wasmtime, against the same scripted fake provider.
#
# Usage: engine_exit_test.sh
# Requires: the pinned Dart SDK on PATH, the wasm.dart test_runner built
# at <wasm.dart>/target/debug/test_runner, wasm_tools resolvable (path
# overrides), and the engine component built (bin/engine.wasm).
set -e
cd "$(dirname "$0")/.."
PKG="$PWD"
# The driver runs inside this package (wasm_tools hooks need the pinned
# SDK); the native engine it spawns runs on the box's stable SDK.
DART="${DART_SDK:-$HOME/tools/dart-sdk-src/sdk/out/ReleaseX64/dart-sdk/bin/dart}"
RUNNER="${RUNNER:-/workspace/target/debug/test_runner}"
DRIVER="$PKG/tool/pipes_drive.dart"
SERVER="$PKG/tool/fake_anthropic_turn_server.py"
NATIVE_OUT=/tmp/stage5_native.txt
WASM_OUT=/tmp/stage5_wasm.txt

if [ ! -f bin/engine.wasm ]; then
  echo "=== building the engine component"
  "$DART" run wasm_tools compile bin/engine.dart
fi

echo "=== starting the scripted provider"
python3 "$SERVER" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 1

WS_NATIVE=/tmp/stage5-ws-native
WS_WASM=/tmp/stage5-ws-wasm
CFG=/tmp/stage5-config
rm -rf "$WS_NATIVE" "$WS_WASM" "$CFG"
mkdir -p "$WS_NATIVE" "$WS_WASM" "$CFG"
cat > "$CFG/config" <<'EOF'
version = 1

[default]
model = "anthropic/claude-sonnet-4-6"

[plugins]
enabled = [
  "tina/system-instruction",
  "tina/providers",
  "tina/mode",
  "tina/tools",
  "tina/approvals-stream",
  "tina/session-controls",
]
EOF

echo "=== native engine (dart run bin/tina.dart --pipes)"
TINA_LLM_ENDPOINT=http://127.0.0.1:8731 TINA_LLM_TOKEN=stage5-token \
  "$DART" run --enable-asserts "$DRIVER" --workspace "$WS_NATIVE" -- \
  dart run --enable-asserts "$PKG/../../../apps/tina_cli/bin/tina.dart" \
  --config "$CFG/config" --cwd . --no-sandbox --yolo --pipes \
  | tee "$NATIVE_OUT"

echo "=== wasm engine under wasmtime"
TINA_LLM_ENDPOINT=http://127.0.0.1:8731 TINA_LLM_TOKEN=stage5-token \
  "$DART" run --enable-asserts "$DRIVER" --workspace "$WS_WASM" -- \
  "$RUNNER" "$PKG/bin/engine.wasm" \
  --preopen=.="$WS_WASM" --preopen=config="$CFG" \
  --env=TINA_LLM_ENDPOINT=http://127.0.0.1:8731 \
  --env=TINA_LLM_TOKEN=stage5-token \
  | tee "$WASM_OUT"

echo "=== native RESULT lines:"
grep "RESULT" "$NATIVE_OUT" || true
echo "=== wasm RESULT lines:"
grep "RESULT" "$WASM_OUT" || true

grep -q "RESULT: PASS" "$NATIVE_OUT"
grep -q "RESULT: PASS" "$WASM_OUT"
echo "STAGE-5 EXIT TEST: both engines completed the turn"
