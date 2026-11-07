#!/usr/bin/env python3
"""A fake Anthropic-wire SSE endpoint for the stage-3 exit probe.

POST /v1/messages -> a text/event-stream body carrying one short message
answer, flushed frame by frame with a small delay so the consumer sees
chunks arrive as the network delivers them (an aggregated write would
prove nothing about streaming). Frames follow the Anthropic messages API
shape tina_llm's SseParser maps: message_start, content_block_start,
two text_delta frames, content_block_stop, message_delta (with usage and
stop_reason) and message_stop. Usage numbers are fixed so the probe's
recorded output is deterministic.
"""
import http.server
import time

FRAMES = [
    b"event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_probe\",\"usage\":{\"input_tokens\":12}}}\n\n",
    b"event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
    b"event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\n",
    b"event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\", streaming world\"}}\n\n",
    b"event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
    b"event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"input_tokens\":12,\"output_tokens\":7}}\n\n",
    b"event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        if self.path != "/v1/messages":
            self.send_error(404)
            return
        length = int(self.headers.get("content-length", 0))
        self.rfile.read(length)

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("content-length", str(sum(len(f) for f in FRAMES)))
        self.end_headers()
        for frame in FRAMES:
            self.wfile.write(frame)
            self.wfile.flush()
            time.sleep(0.15)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 8730), Handler)
    server.serve_forever()
