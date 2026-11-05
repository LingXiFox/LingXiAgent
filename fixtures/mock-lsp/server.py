#!/usr/bin/env python3
"""Minimal LSP fixture for the LingXiAgent Rust tests.

Speaks Content-Length framed JSON-RPC over stdio. It advertises one diagnostic
for any opened document that contains TODO, and one document symbol.
"""
import json
import sys


def read_message():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        text = line.decode("ascii").strip()
        if text.lower().startswith("content-length:"):
            length = int(text.split(":", 1)[1].strip())
    if length is None:
        return None
    body = sys.stdin.buffer.read(length)
    return json.loads(body.decode("utf-8"))


def send(payload):
    body = json.dumps(payload).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def main():
    documents = {}
    while True:
        message = read_message()
        if message is None:
            return
        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params") or {}
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": request_id, "result": {
                "capabilities": {
                    "textDocumentSync": 1,
                    "documentSymbolProvider": True,
                }
            }})
        elif method == "initialized":
            continue
        elif method == "textDocument/didOpen":
            document = params.get("textDocument") or {}
            uri = document.get("uri", "")
            text = document.get("text", "")
            documents[uri] = text
            diagnostics = []
            if "TODO" in text:
                diagnostics.append({
                    "range": {"start": {"line": 0, "character": 2},
                              "end": {"line": 0, "character": 6}},
                    "severity": 2,
                    "source": "mock-lsp",
                    "message": "TODO is not allowed in accepted code",
                })
            send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                  "params": {"uri": uri, "diagnostics": diagnostics}})
        elif method == "textDocument/documentSymbol":
            uri = (params.get("textDocument") or {}).get("uri", "")
            text = documents.get(uri, "")
            symbols = []
            if "def mock_fn" in text:
                symbols.append({
                    "name": "mock_fn",
                    "kind": 12,
                    "range": {"start": {"line": 1, "character": 0},
                              "end": {"line": 3, "character": 0}},
                    "selectionRange": {"start": {"line": 1, "character": 4},
                                       "end": {"line": 1, "character": 11}},
                })
            send({"jsonrpc": "2.0", "id": request_id, "result": symbols})
        elif method == "shutdown":
            send({"jsonrpc": "2.0", "id": request_id, "result": None})
        elif method == "exit":
            return
        elif request_id is not None:
            send({"jsonrpc": "2.0", "id": request_id,
                  "error": {"code": -32601, "message": "unsupported method"}})


if __name__ == "__main__":
    main()
