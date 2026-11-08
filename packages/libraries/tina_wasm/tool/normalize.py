#!/usr/bin/env python3
"""Normalize a pipes transcript for native-vs-wasm comparison.

Reads raw JSON event lines on stdin, writes the normalized form on
stdout: session/epoch/turn ids, approval request ids, timestamps, work
and input counters, and the native engine's absolute workspace paths
become engine-neutral tokens. What remains is the protocol semantics:
entry shapes and order, tool calls and results, approvals and answers.
"""
import json
import re
import sys

WS = sys.argv[1] if len(sys.argv) > 1 else None

SESSION = re.compile(r'"s-\d+"')
TURN = re.compile(r'"t-\d+-input-\d+"')
EPOCH = re.compile(r'"epoch":\s*"[0-9a-f]{32}"')
APPROVAL_ID = re.compile(r'"[0-9a-f]{32}-\d+"')
TIMESTAMP = re.compile(r'"at":\s*"[^"]*"')
WORK = re.compile(r'"work-\d+"')
TMPFILE = re.compile(r'\.tina-write-[^"\\]*')

def normalize(line):
    if WS:
        line = line.replace(WS + "/", "").replace(WS, "")
    line = SESSION.sub('"S"', line)
    line = EPOCH.sub('"epoch":"E"', line)
    line = TURN.sub('"T"', line)
    line = APPROVAL_ID.sub('"A"', line)
    line = WORK.sub('"W"', line)
    line = TIMESTAMP.sub('"at":"TS"', line)
    line = TMPFILE.sub("TMP", line)
    return line

for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        event = json.loads(raw)
    except json.JSONDecodeError:
        print("NONJSON:" + normalize(raw))
        continue
    out = json.loads(normalize(json.dumps(event)))
    # The native entry canonicalizes the model reference with its provider
    # prefix; the composition root's factory uses the config's bare id.
    # The context estimate of an in-flight request is engine-internal.
    if isinstance(out.get("entry"), dict):
        out["entry"].pop("estimated_tokens", None)
    if isinstance(out.get("model"), str):
        out["model"] = out["model"].removeprefix("anthropic/")
    # Receipts and entries keep their meaning; drop pure-noise statuses
    # and the case runner's own start/end brackets.
    if out.get("type") in ("status", "start", "end"):
        continue
    print(json.dumps(out, sort_keys=True))
