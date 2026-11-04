#!/usr/bin/env python3
"""Minimal MCP server used by the LingXiAgent protocol tests.

Speaks JSON-RPC 2.0 over either newline-delimited stdio or Streamable HTTP.
Only test tools are exposed; nothing here touches the host.
"""
import argparse
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CRASH_AFTER_LIST = False

TOOLS = [
    {
        "name": "echo",
        "description": "Echoes the supplied text.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
            "additionalProperties": False,
        },
    },
    {
        "name": "add",
        "description": "Adds two numbers.",
        "inputSchema": {
            "type": "object",
            "properties": {"a": {"type": "number"}, "b": {"type": "number"}},
            "required": ["a", "b"],
            "additionalProperties": False,
        },
    },
]


def handle(message):
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params") or {}
    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "lingxi-mock-mcp", "version": "0.1.0"},
            },
        }
    if method == "notifications/initialized":
        return None
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": request_id, "result": {"tools": TOOLS}}
    if method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments") or {}
        if name == "echo":
            text = str(arguments.get("text", ""))
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"content": [{"type": "text", "text": text}], "structuredContent": {"echo": text}},
            }
        if name == "add":
            value = arguments.get("a", 0) + arguments.get("b", 0)
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {"content": [{"type": "text", "text": str(value)}], "structuredContent": {"sum": value}},
            }
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": -32602, "message": f"unknown tool {name}"},
        }
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": -32601, "message": f"unknown method {method}"},
    }


def serve_stdio():
    global CRASH_AFTER_LIST
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        response = handle(message)
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()
            if CRASH_AFTER_LIST and message.get("method") == "tools/list":
                sys.exit(0)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        if self.path.rstrip("/") not in ("/mcp", ""):
            self.send_json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            message = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self.send_json(400, {"error": "invalid json"})
            return
        response = handle(message)
        if response is None:
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_json(200, response)

    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--http", action="store_true")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--crash-after-list", action="store_true")
    args = parser.parse_args()
    global CRASH_AFTER_LIST
    CRASH_AFTER_LIST = args.crash_after_list
    if not args.http:
        serve_stdio()
        return
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"LISTENING {server.server_port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
