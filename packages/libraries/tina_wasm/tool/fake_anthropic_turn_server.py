#!/usr/bin/env python3
"""A scripted fake Anthropic-wire SSE endpoint for the stage-5 exit test.

POST /v1/messages, serving a TWO-STEP conversation so the engine
completes a full agent turn with a tool call:

  request 1 (no tool_result in the last message): a `tool_use` block
      asking the engine's `write` tool to create stage5.txt in the
      workspace, stop_reason "tool_use";
  request 2 (the retry carrying the tool_result): a short final text
      message, stop_reason "end_turn".

The mode is chosen per request by scanning the request body for a
tool_result block. Usage numbers are fixed so the recorded transcripts
stay comparable. Frames follow the Anthropic messages API shape
tina_llm's SseParser maps.
"""
import http.server
import json
import time

TOOL_INPUT = json.dumps({"filePath": "stage5.txt", "content": "stage5 edit landed\n"})


def frame(name, data):
    return ("event: %s\ndata: %s\n\n" % (name, json.dumps(data))).encode()


TOOL_USE_FRAMES = [
    frame("message_start", {"type": "message_start", "message": {"id": "msg_tool", "usage": {"input_tokens": 21}}}),
    frame("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
    frame("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Creating the file."}}),
    frame("content_block_stop", {"type": "content_block_stop", "index": 0}),
    frame("content_block_start", {"type": "content_block_start", "index": 1, "content_block": {"type": "tool_use", "id": "toolu_stage5", "name": "write", "input": {}}}),
    frame("content_block_delta", {"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": TOOL_INPUT}}),
    frame("content_block_stop", {"type": "content_block_stop", "index": 1}),
    frame("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"input_tokens": 21, "output_tokens": 18}}),
    frame("message_stop", {"type": "message_stop"}),
]

FINAL_FRAMES = [
    frame("message_start", {"type": "message_start", "message": {"id": "msg_final", "usage": {"input_tokens": 34}}}),
    frame("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
    frame("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Stage 5 complete: the file is written."}}),
    frame("content_block_stop", {"type": "content_block_stop", "index": 0}),
    frame("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"input_tokens": 34, "output_tokens": 9}}),
    frame("message_stop", {"type": "message_stop"}),
]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        if self.path != "/v1/messages":
            self.send_error(404)
            return
        length = int(self.headers.get("content-length", 0))
        body = self.rfile.read(length)
        frames = (
            FINAL_FRAMES
            if b'"type":"tool_result"' in body or b'"type": "tool_result"' in body
            else TOOL_USE_FRAMES
        )

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("content-length", str(sum(len(f) for f in frames)))
        self.end_headers()
        for f in frames:
            self.wfile.write(f)
            self.wfile.flush()
            time.sleep(0.15)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 8731), Handler)
    server.serve_forever()
