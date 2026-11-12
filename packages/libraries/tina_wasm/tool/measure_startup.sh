#!/bin/sh
# Startup + RSS measurement for the wasm engine under the runner.
# Usage: measure_startup.sh <runner-binary> <label>
# The runner takes the engine component as its single positional: use
# tina-case-runner (the packaged tina-wasm-host is embedded-only and
# takes no engine path).
set -e
RUNNER="$1"
LABEL="$2"
ENGINE=/home/agent/tina/packages/libraries/tina_wasm/bin/engine.wasm
CFG=/tmp/probe/cfg
WS=/tmp/probe/ws_meas
mkdir -p "$WS"
printf '{"op":"shutdown"}\n' > /tmp/meas.in
rm -f /tmp/meas.out
start=$(date +%s%N)
"$RUNNER" "$ENGINE" \
   --preopen=.="$WS" --preopen=config="$CFG" \
   --env=TINA_LLM_ENDPOINT=http://127.0.0.1:8741 --env=TINA_LLM_TOKEN=x \
   < /tmp/meas.in > /tmp/meas.out 2>&1 &
runner_pid=$!
hwm=0
while kill -0 $runner_pid 2>/dev/null; do
  v=$(awk '/VmHWM/{print $2}' /proc/$runner_pid/status 2>/dev/null || echo 0)
  [ "$v" -gt "$hwm" ] 2>/dev/null && hwm=$v || true
  sleep 0.05
done
wait $runner_pid || true
end=$(date +%s%N)
ready_line=$(grep -m1 '"type":"ready"' /tmp/meas.out | cut -c1-40)
echo "$LABEL: full exit $(( (end - start) / 1000000 ))ms, peak RSS ${hwm} kB, ready: ${ready_line:-none}"
