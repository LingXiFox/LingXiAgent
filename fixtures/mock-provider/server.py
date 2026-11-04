#!/usr/bin/env python3
"""Protocol-level mock for OpenAI Chat, OpenAI Responses and Anthropic Messages.

Used only by automated tests. Behaviour is selected by the model id, so the
same server covers text, tool calls, streaming, multi-turn state, reasoning,
media encoding and HTTP failures. The fixture never talks to a real provider.
"""
import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API_KEY = None
REQUESTS = []
LOCK = threading.Lock()


def chunk(payload):
    return ("data: " + json.dumps(payload, ensure_ascii=False) + "\n\n").encode()


def event(name, payload):
    return (
        f"event: {name}\n"
        + "data: "
        + json.dumps(payload, ensure_ascii=False)
        + "\n\n"
    ).encode()


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


def responses_output_text(value):
    output = []
    if value:
        output.append(
            {
                "type": "message",
                "id": "msg_mock",
                "status": "completed",
                "role": "assistant",
                "content": [{"type": "output_text", "text": value, "annotations": []}],
            }
        )
    return output


def responses_tool_item(name, arguments, call_id="call_resp_1", item_id="fc_mock"):
    return {
        "type": "function_call",
        "id": item_id,
        "call_id": call_id,
        "name": name,
        "arguments": json.dumps(arguments),
        "status": "completed",
    }


def responses_body(model, text, calls=None, previous=None):
    output = responses_output_text(text)
    output.extend(calls or [])
    return {
        "id": "resp_mock",
        "object": "response",
        "created_at": int(time.time()),
        "status": "completed",
        "model": model,
        "previous_response_id": previous,
        "output": output,
        "usage": {"input_tokens": 17, "output_tokens": 7, "total_tokens": 24},
    }


def input_items(body):
    value = body.get("input")
    return value if isinstance(value, list) else []


def responses_texts(body):
    texts = []
    images = []
    for item in input_items(body):
        kind = item.get("type")
        if kind == "function_call_output":
            texts.append(str(item.get("output", "")))
        elif kind == "message":
            content = item.get("content")
            if isinstance(content, str):
                texts.append(content)
            elif isinstance(content, list):
                for part in content:
                    if part.get("type") in ("input_text", "output_text"):
                        texts.append(str(part.get("text", "")))
                    elif part.get("type") == "input_image":
                        images.append(str(part.get("image_url", "")))
    return texts, images


def responses_has_tool_output(body):
    return any(item.get("type") == "function_call_output" for item in input_items(body))


def anthropic_texts(messages):
    texts = []
    has_result = False
    has_image = False
    has_document = False
    for message in messages:
        content = message.get("content")
        if isinstance(content, str):
            texts.append(content)
            continue
        for block in content if isinstance(content, list) else []:
            kind = block.get("type")
            if kind == "text":
                texts.append(str(block.get("text", "")))
            elif kind == "tool_result":
                has_result = True
                result = block.get("content")
                if isinstance(result, list):
                    texts.extend(
                        str(part.get("text", ""))
                        for part in result
                        if part.get("type") == "text"
                    )
                else:
                    texts.append(str(result))
            elif kind == "image":
                has_image = True
            elif kind == "document":
                has_document = True
    return texts, has_result, has_image, has_document


def anthropic_message(model, text, tool=None, thinking=None):
    content = []
    if thinking:
        content.append({"type": "thinking", "thinking": thinking, "signature": "mock"})
    if text:
        content.append({"type": "text", "text": text})
    if tool:
        content.append(
            {
                "type": "tool_use",
                "id": tool["id"],
                "name": tool["name"],
                "input": tool["input"],
            }
        )
    return {
        "id": "msg_mock",
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": content,
        "stop_reason": "tool_use" if tool else "end_turn",
        "stop_sequence": None,
        "usage": {"input_tokens": 17, "output_tokens": 7},
    }


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

    def read_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) or b"{}"
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return None

    def record(self, body):
        with LOCK:
            REQUESTS.append(
                {
                    "path": self.path,
                    "headers": {key.lower(): value for key, value in self.headers.items()},
                    "body": body,
                }
            )

    def check_auth(self):
        if API_KEY is None:
            return True
        if self.headers.get("Authorization") != "Bearer " + API_KEY:
            self.send_json(401, {"error": {"message": "invalid api key"}})
            return False
        return True

    def do_GET(self):
        path = self.path.rstrip("/")
        if path == "/__requests":
            with LOCK:
                self.send_json(200, REQUESTS)
            return
        if path == "/__reset":
            with LOCK:
                REQUESTS.clear()
            self.send_json(200, {"ok": True})
            return
        if path in ("/v1/models", "/models"):
            if not self.check_auth():
                return
            self.send_json(
                200,
                {
                    "object": "list",
                    "data": [
                        {"id": "mock-final"},
                        {"id": "mock-tool"},
                        {"id": "mock-stream"},
                        {"id": "mock-responses-tool"},
                        {"id": "mock-anthropic-tool"},
                    ],
                },
            )
            return
        self.send_json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        body = self.read_body()
        if body is None:
            self.send_json(400, {"error": {"message": "invalid json"}})
            return
        path = self.path.rstrip("/")
        if path.endswith("/responses"):
            self.handle_responses(body)
        elif path.endswith("/messages"):
            self.handle_messages(body)
        elif path.endswith(("/chat/completions", "/completions")):
            self.handle_chat(body)
        else:
            self.send_json(404, {"error": {"message": "not found"}})

    def failure_or_slow(self, model):
        if model == "mock-status-401":
            self.send_json(401, {"error": {"message": "unauthorized"}})
            return True
        if model == "mock-status-429":
            self.send_json(429, {"error": {"message": "rate limited"}})
            return True
        if model == "mock-status-500":
            self.send_json(500, {"error": {"message": "server exploded"}})
            return True
        if model == "mock-slow":
            time.sleep(3)
        return False

    def handle_chat(self, body):
        self.record(body)
        if not self.check_auth():
            return
        model = body.get("model", "mock-final")
        messages = body.get("messages", [])
        stream = bool(body.get("stream"))
        if self.failure_or_slow(model):
            return

        text = "Hello from the mock provider."
        calls = None
        if model == "mock-calculator":
            if has_tool_result(messages):
                result = next(
                    (m.get("content") for m in messages if m.get("role") == "tool"),
                    "32768",
                )
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
                    tool_call(
                        "text_transform", {"text": "hi", "operation": "upper"}, "call_2"
                    ),
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
                result = next(
                    (m.get("content") for m in messages if m.get("role") == "tool"), ""
                )
                text = "MCP tool returned: " + str(result)
            else:
                calls = [tool_call("mcp__local__echo", {"text": "hello mcp"})]
                text = ""
        elif model == "mock-always-tool":
            calls = [tool_call("calculator", {"expression": "1 + 1"})]
            text = ""
        elif model == "mock-skill":
            skill_loaded = any(
                message.get("role") == "system"
                and "Text statistics" in str(message.get("content", ""))
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
            first["choices"][0]["delta"] = {
                "role": "assistant",
                "content": "partial answer",
            }
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
            final = completion(
                model,
                "",
                usage={"prompt_tokens": 17, "completion_tokens": 7, "total_tokens": 24},
            )
            final["choices"][0]["delta"] = {}
            del final["choices"][0]["message"]
            self.wfile.write(chunk(final))
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.close_connection = True
            return

        self.send_json(200, completion(model, text, calls))

    def handle_responses(self, body):
        self.record(body)
        if not self.check_auth():
            return
        model = body.get("model", "mock-final")
        stream = bool(body.get("stream"))
        if self.failure_or_slow(model):
            return
        texts, images = responses_texts(body)
        previous = body.get("previous_response_id")
        tool_output = responses_has_tool_output(body)
        calls = []
        if model == "mock-responses-tool" and not tool_output:
            text = ""
            calls = [responses_tool_item("calculator", {"expression": "6 * 7"})]
        elif model == "mock-responses-tool":
            text = "Responses tool result: " + (texts[-1] if texts else "")
        elif model == "mock-responses-media" and images:
            text = "Responses image " + images[-1].split(";")[0]
        else:
            text = "Responses answer: " + (texts[-1] if texts else "empty")
            if previous:
                text += f" [continued {previous}]"
        response = responses_body(model, text, calls, previous)
        if not stream:
            self.send_json(200, response)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(
            event(
                "response.created",
                {
                    "type": "response.created",
                    "response": {"id": response["id"], "status": "in_progress"},
                },
            )
        )
        for item in calls:
            added = dict(item)
            added["arguments"] = ""
            self.wfile.write(
                event(
                    "response.output_item.added",
                    {"type": "response.output_item.added", "item": added},
                )
            )
            partial = json.dumps(item["arguments"])[1:-1]
            self.wfile.write(
                event(
                    "response.function_call_arguments.delta",
                    {
                        "type": "response.function_call_arguments.delta",
                        "item_id": item["id"],
                        "delta": partial,
                    },
                )
            )
        if text:
            self.wfile.write(
                event(
                    "response.output_item.added",
                    {
                        "type": "response.output_item.added",
                        "item": {
                            "type": "message",
                            "id": "msg_mock",
                            "role": "assistant",
                            "content": [],
                        },
                    },
                )
            )
            for start in range(0, len(text), 5):
                self.wfile.write(
                    event(
                        "response.output_text.delta",
                        {
                            "type": "response.output_text.delta",
                            "item_id": "msg_mock",
                            "delta": text[start : start + 5],
                        },
                    )
                )
        if model == "mock-responses-reasoning":
            self.wfile.write(
                event(
                    "response.reasoning_summary_text.delta",
                    {
                        "type": "response.reasoning_summary_text.delta",
                        "delta": "checked the arithmetic",
                    },
                )
            )
        self.wfile.write(
            event(
                "response.completed",
                {"type": "response.completed", "response": response},
            )
        )
        self.wfile.flush()
        self.close_connection = True

    def handle_messages(self, body):
        self.record(body)
        if API_KEY is not None and self.headers.get("x-api-key") != API_KEY:
            self.send_json(401, {"error": {"message": "invalid x-api-key"}})
            return
        if not self.headers.get("anthropic-version"):
            self.send_json(400, {"error": {"message": "missing anthropic-version"}})
            return
        model = body.get("model", "claude-mock")
        stream = bool(body.get("stream"))
        if self.failure_or_slow(model):
            return
        texts, has_result, has_image, has_document = anthropic_texts(
            body.get("messages", [])
        )
        tool = None
        if model == "mock-anthropic-tool" and not has_result:
            tool = {
                "id": "toolu_mock",
                "name": "calculator",
                "input": {"expression": "6 * 7"},
            }
        if model == "mock-anthropic-tool" and has_result:
            text = "Anthropic tool result: " + (texts[-1] if texts else "")
        elif model == "mock-anthropic-media" and has_image:
            text = "Anthropic image input received"
        elif has_document:
            text = "Anthropic document input received"
        else:
            text = "Anthropic answer: " + (texts[-1] if texts else "empty")
        thinking = None
        if body.get("thinking"):
            thinking = "checked the arithmetic"
        message = anthropic_message(model, text, tool, thinking)
        if not stream:
            self.send_json(200, message)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(
            event(
                "message_start",
                {
                    "type": "message_start",
                    "message": {
                        "id": message["id"],
                        "type": "message",
                        "role": "assistant",
                        "content": [],
                        "model": model,
                        "usage": {"input_tokens": 17, "output_tokens": 0},
                    },
                },
            )
        )
        index = 0
        if thinking:
            self.wfile.write(
                event(
                    "content_block_start",
                    {
                        "type": "content_block_start",
                        "index": index,
                        "content_block": {"type": "thinking", "thinking": ""},
                    },
                )
            )
            self.wfile.write(
                event(
                    "content_block_delta",
                    {
                        "type": "content_block_delta",
                        "index": index,
                        "delta": {"type": "thinking_delta", "thinking": thinking},
                    },
                )
            )
            self.wfile.write(
                event(
                    "content_block_stop",
                    {"type": "content_block_stop", "index": index},
                )
            )
            index += 1
        if text:
            self.wfile.write(
                event(
                    "content_block_start",
                    {
                        "type": "content_block_start",
                        "index": index,
                        "content_block": {"type": "text", "text": ""},
                    },
                )
            )
            for start in range(0, len(text), 5):
                self.wfile.write(
                    event(
                        "content_block_delta",
                        {
                            "type": "content_block_delta",
                            "index": index,
                            "delta": {
                                "type": "text_delta",
                                "text": text[start : start + 5],
                            },
                        },
                    )
                )
            self.wfile.write(
                event(
                    "content_block_stop",
                    {"type": "content_block_stop", "index": index},
                )
            )
            index += 1
        if tool:
            self.wfile.write(
                event(
                    "content_block_start",
                    {
                        "type": "content_block_start",
                        "index": index,
                        "content_block": {
                            "type": "tool_use",
                            "id": tool["id"],
                            "name": tool["name"],
                            "input": {},
                        },
                    },
                )
            )
            partial = json.dumps(tool["input"])
            for start in range(0, len(partial), 4):
                self.wfile.write(
                    event(
                        "content_block_delta",
                        {
                            "type": "content_block_delta",
                            "index": index,
                            "delta": {
                                "type": "input_json_delta",
                                "partial_json": partial[start : start + 4],
                            },
                        },
                    )
                )
            self.wfile.write(
                event(
                    "content_block_stop",
                    {"type": "content_block_stop", "index": index},
                )
            )
        self.wfile.write(
            event(
                "message_delta",
                {
                    "type": "message_delta",
                    "delta": {
                        "stop_reason": "tool_use" if tool else "end_turn",
                        "stop_sequence": None,
                    },
                    "usage": {"output_tokens": 7},
                },
            )
        )
        self.wfile.write(event("message_stop", {"type": "message_stop"}))
        self.wfile.flush()
        self.close_connection = True


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
