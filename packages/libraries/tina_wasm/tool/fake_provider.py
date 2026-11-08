#!/usr/bin/env python3
"""A scripted fake Anthropic-wire SSE endpoint for the stage-6 scenario
suite.

One process serves one scenario run. The script file (FAKE_SCRIPT env or
--script) is a JSON list of steps; each step has a `match` object and a
`response`. A request selects the FIRST step whose matchers all hold:

  last_user_contains: S   substring of the last user text message
  history_contains: S     substring of the serialized conversation (proves
                          a resumed session's log reached the provider)
  tool_result: bool       the body carries any tool_result block
  tool_result_contains: S substring of the last tool_result content
  min_request_index: N    this server has served at least N requests

The response fields: text (a text block), tool_use blocks (list of
{id, name, input}), stop ("tool_use" or "end_turn"), usage
{input, output}, delay_seconds (hold the stream open before the frames —
cancellation scenarios). Frames follow the Anthropic messages API shape
tina_llm's SseParser maps. Usage numbers come from the script so the
recorded transcripts stay comparable.
"""
import http.server
import json
import os
import sys
import time


def frame(name, data):
    return ("event: %s\ndata: %s\n\n" % (name, json.dumps(data))).encode()


def frames_for(step, index):
    blocks = []
    if step.get("text"):
        blocks.append(("text", step["text"]))
    for tool in step.get("tool_use", []):
        blocks.append(("tool_use", tool))

    out = [
        frame(
            "message_start",
            {
                "type": "message_start",
                "message": {
                    "id": "msg_%d" % index,
                    "usage": {"input_tokens": step.get("usage", {}).get("input", 21)},
                },
            },
        )
    ]
    for index, (kind, payload) in enumerate(blocks):
        if kind == "text":
            out.append(frame("content_block_start", {"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}}))
            out.append(frame("content_block_delta", {"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": payload}}))
        else:
            out.append(frame("content_block_start", {"type": "content_block_start", "index": index, "content_block": {"type": "tool_use", "id": payload["id"], "name": payload["name"], "input": {}}}))
            out.append(frame("content_block_delta", {"type": "content_block_delta", "index": index, "delta": {"type": "input_json_delta", "partial_json": json.dumps(payload["input"])}}))
        out.append(frame("content_block_stop", {"type": "content_block_stop", "index": index}))
    out.append(
        frame(
            "message_delta",
            {
                "type": "message_delta",
                "delta": {"stop_reason": step.get("stop", "end_turn")},
                "usage": {
                    "input_tokens": step.get("usage", {}).get("input", 21),
                    "output_tokens": step.get("usage", {}).get("output", 18),
                },
            },
        )
    )
    out.append(frame("message_stop", {"type": "message_stop"}))
    return out


def last_user_text(body):
    texts = []
    for message in body.get("messages", []):
        if message.get("role") != "user":
            continue
        content = message.get("content", [])
        if isinstance(content, str):
            texts.append(content)
            continue
        for block in content:
            if block.get("type") == "text":
                texts.append(block.get("text", ""))
    return texts[-1] if texts else ""


def last_tool_result(body):
    results = []
    for message in body.get("messages", []):
        for block in message.get("content", []) if isinstance(message.get("content"), list) else []:
            if block.get("type") == "tool_result":
                content = block.get("content", "")
                results.append(content if isinstance(content, str) else json.dumps(content))
    return results[-1] if results else None


def step_matches(step, body, request_index):
    match = step.get("match", {})
    if "last_user_contains" in match and match["last_user_contains"] not in last_user_text(body):
        return False
    if "history_contains" in match and match["history_contains"] not in json.dumps(body.get("messages", [])):
        return False
    has_tool_result = last_tool_result(body) is not None
    if "tool_result" in match and match["tool_result"] != has_tool_result:
        return False
    if "tool_result_contains" in match:
        result = last_tool_result(body)
        if result is None or match["tool_result_contains"] not in result:
            return False
    if "min_request_index" in match and request_index < match["min_request_index"]:
        return False
    return True


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    steps = []
    request_count = 0

    def do_POST(self):
        if self.path != "/v1/messages":
            self.send_error(404)
            return
        length = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        index = Handler.request_count
        Handler.request_count += 1
        step = next((s for s in Handler.steps if step_matches(s, body, index)), None)
        if step is None:
            step = {"text": "no scripted step matched", "stop": "end_turn", "usage": {"input": 1, "output": 1}}
        frames = frames_for(step, index)
        delay = float(step.get("delay_seconds", 0))
        if delay:
            time.sleep(delay)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("content-length", str(sum(len(f) for f in frames)))
        self.end_headers()
        for f in frames:
            self.wfile.write(f)
            self.wfile.flush()
            time.sleep(0.05)

    def log_message(self, *args):
        pass


def main():
    path = sys.argv[sys.argv.index("--script") + 1] if "--script" in sys.argv else os.environ.get("FAKE_SCRIPT")
    port = int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else int(os.environ.get("FAKE_PORT", "8741"))
    with open(path) as handle:
        Handler.steps = json.load(handle)["steps"]
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
