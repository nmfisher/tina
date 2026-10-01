"""Independent MCP protocol fixture. Uses actual OS stdio, not a Dart mock."""
import json
import os
import sys
import threading
import time

events = sys.argv[1] if len(sys.argv) > 1 else None
lock = threading.Lock()
changed = False
cancelled = threading.Event()

def log(message):
    if events:
        with open(events, "a", encoding="utf-8") as file:
            file.write(json.dumps({**message, "fixture_pid": os.getpid()}) + "\n")

def send(message):
    # Force split UTF-8 and JSON boundaries to exercise transport framing.
    data = (json.dumps({"jsonrpc": "2.0", **message}, ensure_ascii=False) + "\n").encode()
    with lock:
        split = len(data) // 2
        sys.stdout.buffer.write(data[:split])
        sys.stdout.buffer.flush()
        sys.stdout.buffer.write(data[split:])
        sys.stdout.buffer.flush()

def result(request, value):
    send({"id": request["id"], "result": value})

def tool(name):
    return {"name": name, "title": name.title(), "description": "Fixture " + name,
            "inputSchema": {"type": "object", "properties": {"value": {"type": "string"}}}}

def slow(request):
    cancelled.wait(2)
    result(request, {"content": [{"type": "text", "text": "late result"}]})

print("MCP fixture log on stderr", file=sys.stderr, flush=True)
for line in sys.stdin:
    request = json.loads(line)
    log(request)
    method = request.get("method")
    params = request.get("params", {})
    if method == "initialize":
        result(request, {"protocolVersion": params["protocolVersion"],
                         "serverInfo": {"name": "fixture", "version": "1"},
                         "capabilities": {"tools": {"listChanged": True}, "resources": {}, "prompts": {}},
                         "instructions": "Use the fixture tools."})
        send({"id": 101, "method": "ping"})
        send({"id": 102, "method": "roots/list"})
        send({"id": 103, "method": "sampling/createMessage", "params": {}})
    elif method == "tools/list":
        if "cursor" not in params:
            result(request, {"tools": [tool("screenshot")], "nextCursor": "page2"})
        else:
            result(request, {"tools": [tool(n) for n in ["mutate", "slow", "error", "explode"] + (["new_tool"] if changed else [])]})
    elif method == "tools/call":
        name = params["name"]
        if name == "screenshot":
            result(request, {"content": [
                {"type": "text", "text": "Blender 📷"},
                {"type": "image", "mimeType": "image/png", "data": "aGVsbG8="}],
                "structuredContent": {"objects": 3}})
        elif name == "mutate":
            changed = True
            send({"method": "notifications/tools/list_changed"})
            result(request, {"content": [{"type": "text", "text": params["arguments"].get("value", "changed")}]})
        elif name == "slow":
            threading.Thread(target=slow, args=(request,), daemon=True).start()
        elif name == "error":
            result(request, {"isError": True, "content": [{"type": "text", "text": "Fixture failure"}]})
        elif name == "explode":
            os._exit(7)
        else:
            result(request, {"content": [{"type": "text", "text": "new tool works"}]})
    elif method == "notifications/cancelled":
        cancelled.set()
    elif method == "resources/list":
        result(request, {"resources": [{"uri": "fixture://scene", "name": "Scene"}]})
    elif method == "resources/templates/list":
        result(request, {"resourceTemplates": []})
    elif method == "resources/read":
        result(request, {"contents": [{"uri": params["uri"], "text": "Scene data"}]})
    elif method == "prompts/list":
        result(request, {"prompts": [{"name": "scene", "description": "Describe scene"}]})
    elif method == "prompts/get":
        result(request, {"messages": [{"role": "user", "content": {"type": "text", "text": "Describe scene"}}]})
    elif method == "ping":
        result(request, {})
