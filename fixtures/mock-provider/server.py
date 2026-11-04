#!/usr/bin/env python3
"""Protocol-level mock of an OpenAI-compatible chat completions endpoint.

Used only by automated tests. Behaviour is selected by the model id, so the
same server covers normal answers, tool calls, streaming and HTTP failures.
"""
import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API_KEY = None


def chunk(payload):
    return ("data: " + json.dumps(payload, ensure_ascii=False) + "\n\n").encode()


def completion(model, text, tool_calls=None, usage=None):
    message = {"role": "assistant", "content": text}
    if tool_calls:
        message["tool_calls"] = tool_calls
    return {
        "id": "chatcmpl-mock",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": message,
                "finish_reason": "tool_calls" if tool_calls else "stop",
            }
        ],
        "usage": usage or {"prompt_tokens": 17, "completion_tokens": 7, "total_tokens": 24},
    }


def tool_call(name, arguments, call_id="call_1"):
    return {
        "id": call_id,
        "type": "function",
        "function": {"name": name, "arguments": json.dumps(arguments)},
    }


def has_tool_result(messages):
    return any(message.get("role") == "tool" for message in messages)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") in ("/v1/models", "/models"):
            if not self.check_auth():
                return
            self.send_json(200, {"object": "list", "data": [{"id": "mock-tool"}, {"id": "mock-final"}, {"id": "mock-stream"}]})
            return
        self.send_json(404, {"error": {"message": "not found"}})

    def check_auth(self):
        if API_KEY is None:
            return True
        if self.headers.get("Authorization") != "Bearer " + API_KEY:
            self.send_json(401, {"error": {"message": "invalid api key"}})
            return False
        return True

    def do_POST(self):
        if not self.path.rstrip("/").endswith(("/chat/completions", "/completions")):
            self.send_json(404, {"error": {"message": "not found"}})
            return
        if not self.check_auth():
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self.send_json(400, {"error": {"message": "invalid json"}})
            return
        model = body.get("model", "mock-final")
        messages = body.get("messages", [])
        stream = bool(body.get("stream"))

        if model == "mock-status-401":
            self.send_json(401, {"error": {"message": "unauthorized"}})
            return
        if model == "mock-status-429":
            self.send_json(429, {"error": {"message": "rate limited"}})
            return
        if model == "mock-status-500":
            self.send_json(500, {"error": {"message": "server exploded"}})
            return
        if model == "mock-slow":
            time.sleep(3)

        text = "Hello from the mock provider."
        calls = None
        if model == "mock-calculator":
            if has_tool_result(messages):
                result = next((m.get("content") for m in messages if m.get("role") == "tool"), "32768")
                text = "The answer is " + str(result) + "."
            else:
                calls = [tool_call("calculator", {"expression": "128 * 256"})]
                text = ""
        elif model == "mock-multi-tool":
            if has_tool_result(messages):
                text = "Both calculations are complete."
            else:
                calls = [
                    tool_call("calculator", {"expression": "2 + 2"}, "call_1"),
                    tool_call("text_transform", {"text": "hi", "operation": "upper"}, "call_2"),
                ]
                text = ""
        elif model == "mock-bad-args":
            if has_tool_result(messages):
                text = "Tool rejected the arguments."
            else:
                calls = [tool_call("calculator", {"expression": "1 +"})]
                text = ""
        elif model == "mock-unknown-tool":
            if has_tool_result(messages):
                text = "Tool was not available."
            else:
                calls = [tool_call("no_such_tool", {"x": 1})]
                text = ""
        elif model == "mock-mcp":
            if has_tool_result(messages):
                result = next((m.get("content") for m in messages if m.get("role") == "tool"), "")
                text = "MCP tool returned: " + str(result)
            else:
                calls = [tool_call("mcp__local__echo", {"text": "hello mcp"})]
                text = ""
        elif model == "mock-always-tool":
            calls = [tool_call("calculator", {"expression": "1 + 1"})]
            text = ""
        elif model == "mock-skill":
            skill_loaded = any(
                message.get("role") == "system" and "Text statistics" in str(message.get("content", ""))
                for message in messages
            )
            text = "Skill loaded: text-stats" if skill_loaded else "Skill missing."
        elif model == "mock-truncated":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            first = completion(model, "", usage=None)
            first["choices"][0]["delta"] = {"role": "assistant", "content": "partial answer"}
            del first["choices"][0]["message"]
            self.wfile.write(chunk(first))
            self.wfile.flush()
            self.close_connection = True
            return

        if stream:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            first = completion(model, "", usage=None)
            first["choices"][0]["delta"] = {"role": "assistant", "content": ""}
            del first["choices"][0]["message"]
            self.wfile.write(chunk(first))
            for piece in [text[i : i + 4] for i in range(0, len(text), 4)] or [""]:
                delta = completion(model, "", usage=None)
                delta["choices"][0]["delta"] = {"content": piece}
                del delta["choices"][0]["message"]
                self.wfile.write(chunk(delta))
                self.wfile.flush()
            if calls:
                delta = completion(model, "", usage=None)
                delta["choices"][0]["delta"] = {"tool_calls": []}
                del delta["choices"][0]["message"]
                for index, call in enumerate(calls):
                    delta["choices"][0]["delta"] = {
                        "tool_calls": [
                            {
                                "index": index,
                                "id": call["id"],
                                "type": "function",
                                "function": call["function"],
                            }
                        ]
                    }
                    self.wfile.write(chunk(delta))
            final = completion(model, "", usage={"prompt_tokens": 17, "completion_tokens": 7, "total_tokens": 24})
            final["choices"][0]["delta"] = {}
            del final["choices"][0]["message"]
            self.wfile.write(chunk(final))
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.close_connection = True
            return

        self.send_json(200, completion(model, text, calls))


def main():
    global API_KEY
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--api-key", default=None)
    args = parser.parse_args()
    API_KEY = args.api_key
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"LISTENING {server.server_port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
