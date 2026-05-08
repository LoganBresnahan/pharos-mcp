#!/usr/bin/env python3
"""Tiny stub LSP for deterministic edge-case testing.

Speaks LSP framing (Content-Length headers + JSON body) on stdio.
Behavior is controlled via env vars:

  STUB_LSP_INIT_DELAY_MS=0   delay before initialize response
  STUB_LSP_HOVER_DELAY_MS=0  delay before each textDocument/hover response
  STUB_LSP_HOVER_RESPONSES=value
                              what to return for hover; either
                              "null" (LSP-null), "panic" (raise), or
                              "content_modified" (return -32801 first
                              call, then real content on retry)
  STUB_LSP_FAIL_HANDSHAKE=0   if 1, never reply to initialize

Used by `bin/test-edges.py` to simulate cold-start races, transport
errors, content-modified races deterministically — without depending
on any real language server's behavior.
"""

from __future__ import annotations

import json
import os
import sys
import time


HOVER_RETRY_STATE: dict[str, int] = {}


def read_message(stream):
    headers = {}
    while True:
        line = stream.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        if b":" in line:
            key, _, value = line.partition(b":")
            headers[key.strip().decode().lower()] = value.strip().decode()
    length = int(headers.get("content-length", "0"))
    if length == 0:
        return None
    body = stream.read(length)
    return json.loads(body.decode("utf-8"))


def write_message(stream, msg):
    body = json.dumps(msg).encode("utf-8")
    stream.write(f"Content-Length: {len(body)}\r\n\r\n".encode())
    stream.write(body)
    stream.flush()


def handle_initialize(req):
    delay = int(os.environ.get("STUB_LSP_INIT_DELAY_MS", "0")) / 1000.0
    if delay:
        time.sleep(delay)
    if os.environ.get("STUB_LSP_FAIL_HANDSHAKE") == "1":
        return None
    return {
        "jsonrpc": "2.0",
        "id": req["id"],
        "result": {
            "capabilities": {
                "hoverProvider": True,
                "documentSymbolProvider": True,
                "textDocumentSync": 1,
            },
            "serverInfo": {"name": "stub_lsp", "version": "0.0.1"},
        },
    }


def handle_hover(req):
    mode = os.environ.get("STUB_LSP_HOVER_RESPONSES", "")
    delay = int(os.environ.get("STUB_LSP_HOVER_DELAY_MS", "0")) / 1000.0
    if delay:
        time.sleep(delay)
    if mode == "panic":
        # Crash the process — pharos should detect via port DOWN.
        sys.exit(1)
    if mode == "content_modified":
        attempts = HOVER_RETRY_STATE.get("hover", 0) + 1
        HOVER_RETRY_STATE["hover"] = attempts
        if attempts == 1:
            return {
                "jsonrpc": "2.0",
                "id": req["id"],
                "error": {"code": -32801, "message": "content modified"},
            }
        return {
            "jsonrpc": "2.0",
            "id": req["id"],
            "result": {
                "contents": {"kind": "markdown", "value": "stub hover (after retry)"},
            },
        }
    return {
        "jsonrpc": "2.0",
        "id": req["id"],
        "result": None,
    }


def main():
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    while True:
        try:
            msg = read_message(stdin)
        except Exception:  # noqa: BLE001
            return
        if msg is None:
            return
        method = msg.get("method")
        if method == "initialize":
            resp = handle_initialize(msg)
            if resp is not None:
                write_message(stdout, resp)
        elif method == "initialized":
            # notification, no reply
            continue
        elif method == "shutdown":
            write_message(stdout, {"jsonrpc": "2.0", "id": msg["id"], "result": None})
        elif method == "exit":
            return
        elif method == "textDocument/didOpen":
            continue  # no reply for notification
        elif method == "textDocument/didChange":
            continue
        elif method == "textDocument/didClose":
            continue
        elif method == "textDocument/hover":
            resp = handle_hover(msg)
            write_message(stdout, resp)
        elif method == "$/cancelRequest":
            continue
        else:
            # Unknown method — return method-not-found if it has an id.
            if "id" in msg:
                write_message(stdout, {
                    "jsonrpc": "2.0",
                    "id": msg["id"],
                    "error": {"code": -32601, "message": f"stub_lsp: unknown method {method}"},
                })


if __name__ == "__main__":
    main()
