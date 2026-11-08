#!/bin/sh
# The stage-6 scenario suite: agent-TURN scenarios against BOTH engines
# (native `tina --pipes` and the wasm engine under the case runner),
# every run recorded, transcripts normalized and compared native-vs-wasm.
#
# Usage: scenario_suite.sh [artifacts-dir]
# Requires: the pinned Dart SDK (DART_SDK or ../../../../tools/...), the
# wasm.dart test_runner (RUNNER), the engine component built
# (bin/engine.wasm).
set -e
cd "$(dirname "$0")/.."
PKG="$PWD"
SCEN="$PKG/tool/scenarios"
PINNED="${DART_SDK:-$HOME/tools/dart-sdk-src/sdk/out/ReleaseX64/dart-sdk/bin/dart}"
# The native engine runs on the box's stable SDK (its build hooks do not
# build under the pinned edge SDK); the client runs under the pinned one.
STABLE="${STABLE_DART:-/opt/dart-sdk/bin/dart}"
RUNNER="${RUNNER:-/workspace/target/debug/test_runner}"
ART="${1:-/tmp/stage6-scenarios}"
FRONT="$PKG/tool/front_end.dart"
SERVER="$PKG/tool/fake_provider.py"
NATIVE="$PKG/../../../apps/tina_cli/bin/tina.dart"
mkdir -p "$ART"
rm -f "$ART"/*.transcript "$ART"/*.normalized "$ART"/*.diff "$ART"/*.out 2>/dev/null || true

BASE_PORT=8760
PORT=$BASE_PORT
RESULTS="$ART/results.txt"
: > "$RESULTS"

say() { echo "=== $*"; }

config() { # config <dir> <persistence?>
  mkdir -p "$1"
  cat > "$1/config" <<EOF
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
$(if [ "$2" = persist ]; then echo '  "tina/persistence",'; fi)
]
EOF
}

run_engine() { # run_engine <scenario> <engine> <ws> <cfg> <extra-args...>
  scenario=$1; engine=$2; ws=$3; cfg=$4; shift 4
  provider="${PROVIDER:-$SCEN/${scenario}_provider.json}"
  PORT=$((PORT + 1))
  python3 "$SERVER" --script "$provider" --port "$PORT" &
  server_pid=$!
  sleep 0.7
  if [ "$engine" = native ]; then
    TINA_LLM_ENDPOINT="http://127.0.0.1:$PORT" TINA_LLM_TOKEN=stage6 \
      "$PINNED" run --enable-asserts "$FRONT" \
      --workspace "$ws" --scenario "$SCEN/$scenario.json" \
      --record "$ART/$scenario.native.transcript" -- \
      "$PINNED" run --enable-asserts "$NATIVE" \
      --config "$cfg/config" --cwd . --no-sandbox --yolo --pipes "$@" \
      > "$ART/$scenario.native.out" 2>&1 || echo "exit $?" >> "$ART/$scenario.native.out"
  else
    "$PINNED" run --enable-asserts "$FRONT" \
      --workspace "$ws" --scenario "$SCEN/$scenario.json" \
      --record "$ART/$scenario.wasm.transcript" -- \
      "$RUNNER" "$PKG/bin/engine.wasm" \
      --preopen=.="$ws" --preopen=config="$cfg" \
      --env=TINA_LLM_ENDPOINT="http://127.0.0.1:$PORT" \
      --env=TINA_LLM_TOKEN=stage6 "$@" \
      > "$ART/$scenario.wasm.out" 2>&1 || echo "exit $?" >> "$ART/$scenario.wasm.out"
  fi
  kill $server_pid 2>/dev/null || true
  wait $server_pid 2>/dev/null || true
}

# ---- scenario: multi_turn ------------------------------------------------
say "scenario multi_turn"
for engine in native wasm; do
  ws="$ART/ws_multi_turn_$engine"; cfg="$ART/cfg_multi_turn"; rm -rf "$ws" "$cfg"
  mkdir -p "$ws"
  config "$cfg"
  if [ "$engine" = native ]; then run_engine multi_turn native "$ws" "$cfg";
  else run_engine multi_turn wasm "$ws" "$cfg"; fi
done

# ---- scenario: tool_error ------------------------------------------------
say "scenario tool_error"
for engine in native wasm; do
  ws="$ART/ws_tool_error_$engine"; cfg="$ART/cfg_tool_error"; rm -rf "$ws" "$cfg"
  mkdir -p "$ws"
  config "$cfg"
  run_engine tool_error "$engine" "$ws" "$cfg"
done

# ---- scenarios: approval grant and deny (ask mode) -----------------------
say "scenarios approval_grant + approval_deny"
for scenario in approval_grant approval_deny; do
  for engine in native wasm; do
    ws="$ART/ws_${scenario}_$engine"; cfg="$ART/cfg_$scenario"; rm -rf "$ws" "$cfg"
    mkdir -p "$ws"
    config "$cfg"
    if [ "$engine" = native ]; then
      PORT=$((PORT + 1))
      python3 "$SERVER" --script "$SCEN/approval_provider.json" --port "$PORT" &
      server_pid=$!
      sleep 0.7
      TINA_LLM_ENDPOINT="http://127.0.0.1:$PORT" TINA_LLM_TOKEN=stage6 \
        "$PINNED" run --enable-asserts "$FRONT" \
        --workspace "$ws" --scenario "$SCEN/$scenario.json" \
        --record "$ART/$scenario.native.transcript" -- \
        "$STABLE" run --enable-asserts "$NATIVE" \
        --config "$cfg/config" --cwd . --no-sandbox --pipes \
        > "$ART/$scenario.native.out" 2>&1 || echo "exit $?" >> "$ART/$scenario.native.out"
      kill $server_pid 2>/dev/null || true; wait $server_pid 2>/dev/null || true
    else
      PORT=$((PORT + 1))
      python3 "$SERVER" --script "$SCEN/approval_provider.json" --port "$PORT" &
      server_pid=$!
      sleep 0.7
      "$PINNED" run --enable-asserts "$FRONT" \
        --workspace "$ws" --scenario "$SCEN/$scenario.json" \
        --record "$ART/$scenario.wasm.transcript" -- \
        "$RUNNER" "$PKG/bin/engine.wasm" \
        --preopen=.="$ws" --preopen=config="$cfg" \
        --env=TINA_LLM_ENDPOINT="http://127.0.0.1:$PORT" \
        --env=TINA_LLM_TOKEN=stage6 \
        --env=TINA_ENGINE_YOLO=0 \
        > "$ART/$scenario.wasm.out" 2>&1 || echo "exit $?" >> "$ART/$scenario.wasm.out"
      kill $server_pid 2>/dev/null || true; wait $server_pid 2>/dev/null || true
    fi
  done
done

# ---- scenario: cancel_mid_turn -------------------------------------------
say "scenario cancel_mid_turn"
for engine in native wasm; do
  ws="$ART/ws_cancel_$engine"; cfg="$ART/cfg_cancel"; rm -rf "$ws" "$cfg"
  mkdir -p "$ws"
  config "$cfg"
  run_engine cancel "$engine" "$ws" "$cfg"
done

# ---- scenario: persist + resume ------------------------------------------
say "scenario persist + resume"
for engine in native wasm; do
  ws="$ART/ws_persist_$engine"; cfg="$ART/cfg_persist"; rm -rf "$ws" "$cfg"
  mkdir -p "$ws/.tina"
  config "$cfg" persist
  if [ "$engine" = native ]; then
    # The CLI's argument gate reserves resume for the terminal; the
    # assembly itself resumes headlessly - the native resume probe is
    # that exact assembly over pipes.
    PROVIDER="$SCEN/persist_provider.json" run_engine persist_a native \
      "$ws" "$cfg" --store .tina/sessions.db
    session=$(grep -o '"session":"[^"]*"' "$ART/persist_a.native.transcript" | head -1 | cut -d'"' -f4)
    PORT=$((PORT + 1))
    python3 "$SERVER" --script "$SCEN/persist_provider.json" --port "$PORT" &
    persist_server=$!
    sleep 0.7
    TINA_LLM_ENDPOINT="http://127.0.0.1:$PORT" TINA_LLM_TOKEN=stage6 \
      "$PINNED" run --enable-asserts "$FRONT" \
      --workspace "$ws" --scenario "$SCEN/persist_b.json" \
      --record "$ART/persist_b.native.transcript" -- \
      "$PINNED" run --enable-asserts "$PKG/bin/native_resume_probe.dart" \
      --config "$cfg/config" --cwd "$ws" --yolo \
      --store .tina/sessions.db --resume "$session" \
      > "$ART/persist_b.native.out" 2>&1 || echo "exit $?" >> "$ART/persist_b.native.out"
    kill $persist_server 2>/dev/null || true
    wait $persist_server 2>/dev/null || true
  else
    PROVIDER="$SCEN/persist_provider.json" run_engine persist_a wasm \
      "$ws" "$cfg" --env=TINA_ENGINE_STORE=.tina/sessions.jsonl
    session=$(grep -o '"session":"[^"]*"' "$ART/persist_a.wasm.transcript" | head -1 | cut -d'"' -f4)
    PROVIDER="$SCEN/persist_provider.json" run_engine persist_b wasm \
      "$ws" "$cfg" \
      --env=TINA_ENGINE_STORE=.tina/sessions.jsonl --env=TINA_ENGINE_RESUME="$session"
  fi
done

# ---- compare --------------------------------------------------------------
say "comparison"
for scenario in multi_turn tool_error approval_grant approval_deny cancel persist_a persist_b; do
  for engine in native wasm; do
    ws="$ART/ws_${scenario}_${engine}"
    python3 "$PKG/tool/normalize.py" "$ws" < "$ART/$scenario.$engine.transcript" \
      > "$ART/$scenario.$engine.normalized"
  done
  if diff -u "$ART/$scenario.native.normalized" "$ART/$scenario.wasm.normalized" \
      > "$ART/$scenario.diff"; then
    verdict=IDENTICAL
  else
    verdict=DIFFERS
  fi
  native_ok=$(grep -c "RESULT: PASS" "$ART/$scenario.native.out" || true)
  wasm_ok=$(grep -c "RESULT: PASS" "$ART/$scenario.wasm.out" || true)
  echo "$scenario: native=$([ "$native_ok" -ge 1 ] && echo PASS || echo FAIL) \
wasm=$([ "$wasm_ok" -ge 1 ] && echo PASS || echo FAIL) comparison=$verdict" | tee -a "$RESULTS"
done

say "artifacts in $ART"
cat "$RESULTS"
